// Front-end wrapper.
//
// Packages the whole instruction-supply path into one module so that a back-end
// can be attached through a single, well-defined interface:
//
//     BPU -> FTQ -> IFU (-> icache) -> IQ --(read port)--> back-end
//
// The wrapper owns the internal fixing of the BPU/FTQ/IFU flush priority (a
// back-end redirect always wins over the front-end PredecodeCheck redirect) and
// exposes only:
//   * the IQ read port          (`iq_*`), consumed by the back-end decoder,
//   * the back-end redirect      (flush + corrected PC),
//   * the BPU training port      (update_en + update_meta),
//   * the icache AXI master bus.
//
// The IQ write port (IFU -> IQ) and the FTQ read port (FTQ -> IFU) are
// internal.  The back-end only needs to respect the counting handshake
// (iq_raccept_cnt is the only consume condition) and to send its resolutions
// back in program order (see docs).
module frontend #(
    parameter int unsigned ADDR_WIDTH = 32,
    parameter int unsigned DATA_WIDTH = 32,
    parameter int unsigned RESET_VEC  = 32'h8000_0000
) (
    input logic clk,
    input logic rst,

    // ---------- IQ read port (front-end -> back-end) ----------
    output logic [fe_pkg::DECODE_WIDTH - 1:0] iq_rvalid,  // valid slots of HEAD (low-contiguous)
    output fe_pkg::iq_entry_t iq_rbits[fe_pkg::DECODE_WIDTH],
    // counting handshake: iq_raccept_cnt is the only consume condition (0/1/2)
    input logic [$clog2(fe_pkg::DECODE_WIDTH + 1) - 1:0] iq_raccept_cnt,  // instructions accepted

    // ---------- back-end -> front-end ----------
    // branch/jump resolution redirect.  Valid for one cycle; flushes the whole
    // front-end (BPU/FTQ/IFU and the IQ) and restarts fetch at `backend_redirect_pc`.
    input logic                                              backend_redirect_valid,
    input logic                      [     ADDR_WIDTH - 1:0] backend_redirect_pc,
    // Redirect kind (contract section 3).  The per-CFI ghr_before and
    // actual_taken are not separate ports: the BPU reconstructs them from the
    // redirecting CFI's echoed metadata (`bpu_update_meta`).
    // REDIRECT_BRANCH restores ghr_spec from ghr_before + actual_taken;
    // REDIRECT_ARCH (ECALL/MRET/IRQ) resyncs to the committed history.
    input fe_pkg::fe_redirect_kind_t                         backend_redirect_kind,

    // BPU training.  Must be driven in program order, at most one CFI per cycle.
    input logic                bpu_update_en,
    input fe_pkg::bpu_update_t bpu_update_meta,

    // ---------- instruction cache backing memory bus ----------
`ifdef CONFIG_IO_USE_AXI
    axi_if.master ifu_axi_bus,
`else
    miniTensor_if.master ifu_mt_bus,
`endif

    // ---------- debug / side-channel ----------
    output logic [ADDR_WIDTH - 1:0] fetch_pc_out,

    // ---------- simulation performance counters ----------
    output logic [$clog2(fe_pkg::IQ_DEPTH+1) - 1:0] iq_occupancy,
    output logic [$clog2(fe_pkg::FETCH_WIDTH+1) - 1:0] iq_enq_count,
    output logic [$clog2(fe_pkg::DECODE_WIDTH+1) - 1:0] iq_deq_count,
    output logic [$clog2(fe_pkg::FTQ_NUM_ENTRIES+1) - 1:0] ftq_occupancy,
    output logic ftq_alloc,
    output logic ftq_pop,
    output logic icache_refill,
    output logic icache_req_fire
);
    import fe_pkg::*;

    // ------------------------------------------------
    // IFU <-> IQ write channel (internal)
    // ------------------------------------------------
    logic iq_wvalid;
    iq_entry_t iq_wdata[FETCH_WIDTH];
    logic [FETCH_WIDTH - 1:0] iq_wmask;
    logic iq_wready;

    // ------------------------------------------------
    // BPU -> FTQ -> IFU links (internal)
    // ------------------------------------------------
    ftq_entry_t ftq_wdata;
    ftq_entry_t ftq_rdata;
    logic ftq_wvalid;
    logic ftq_wready;
    logic ftq_rvalid;
    logic ifu_rready;

    // front-end (PredecodeCheck) redirect
    logic fe_redirect_valid;
    logic [ADDR_WIDTH - 1:0] fe_redirect_pc;

    // back-end redirect wins over the front-end one
    wire fe_flush = backend_redirect_valid | fe_redirect_valid;
    wire [ADDR_WIDTH - 1:0] fe_redirect_pc_sel =
        backend_redirect_valid ? backend_redirect_pc : fe_redirect_pc;

    // Redirect kind for the BPU GHR recovery.  A front-end local
    // (PredecodeCheck) redirect has no architectural/branch kind of its own;
    // it keeps the historical behaviour of resyncing to the committed history,
    // i.e. the REDIRECT_ARCH path.
    wire fe_redirect_kind = backend_redirect_valid ? backend_redirect_kind : REDIRECT_ARCH;

    /* verilator lint_off UNUSEDSIGNAL */
    logic [ADDR_WIDTH - 1:0] bpu_resp_pc;
    /* verilator lint_on UNUSEDSIGNAL */

    // ------------------------------------------------
    // IFU <-> ICache channel (internal)
    // ------------------------------------------------
    logic icache_req_valid;
    logic [ADDR_WIDTH - 1:0] icache_req_addr;
    logic icache_req_ready;
    logic icache_resp_valid;
    logic [ADDR_WIDTH - 1:0] icache_resp_data[FETCH_WIDTH];
    logic [FETCH_WIDTH - 1:0] icache_resp_rmask;
    logic icache_resp_ready;

    // ------------------------------------------------
    // branch prediction unit
    // ------------------------------------------------
    bpu bpu_u (
        .clk                  (clk),
        .rst                  (rst),
        .flush                (fe_flush),
        .redirect_pc          (fe_redirect_pc_sel),
        .redirect_kind        (fe_redirect_kind),
        .ftq_wready           (ftq_wready),
        .ftq_wvalid           (ftq_wvalid),
        .bpu_resp_pc          (bpu_resp_pc),
        .ftq_wdata            (ftq_wdata),
        .update_en            (bpu_update_en),
        .update_meta          (bpu_update_meta)
    );

    // ------------------------------------------------
    // fetch target queue
    // ------------------------------------------------
    ftq ftq_u (
        .clk(clk),
        .rst(rst),
        .flush(fe_flush),
        .wvalid(ftq_wvalid),
        .wready(ftq_wready),
        .wdata(ftq_wdata),
        .rvalid(ftq_rvalid),
        .rready(ifu_rready),
        .rdata(ftq_rdata),
        .occupancy(ftq_occupancy),
        .alloc(ftq_alloc),
        .pop(ftq_pop)
    );

    // ------------------------------------------------
    // instruction fetch unit
    // ------------------------------------------------
    ifu #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .RESET_VEC (RESET_VEC)
    ) ifu_u (
        .clk              (clk),
        .rst              (rst),
        .flush            (backend_redirect_valid),
        .redirect_pc      (backend_redirect_pc),
        .ftq_rvalid       (ftq_rvalid),
        .ifu_rready       (ifu_rready),
        .ftq_rdata        (ftq_rdata),
        .iq_wvalid        (iq_wvalid),
        .iq_wdata         (iq_wdata),
        .iq_wmask         (iq_wmask),
        .iq_wready        (iq_wready),
        .fetch_pc_out     (fetch_pc_out),
        .fe_redirect_valid(fe_redirect_valid),
        .fe_redirect_pc   (fe_redirect_pc),
        .icache_req_valid (icache_req_valid),
        .icache_req_addr  (icache_req_addr),
        .icache_req_ready (icache_req_ready),
        .icache_resp_valid(icache_resp_valid),
        .icache_resp_data (icache_resp_data),
        .icache_resp_rmask(icache_resp_rmask),
        .icache_resp_ready(icache_resp_ready)
    );

    // ------------------------------------------------
    // instruction cache
    // ------------------------------------------------
    icache #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .DATA_WIDTH(DATA_WIDTH),
        .LINE_BYTES(ICACHE_LINE_BYTES),
        .NR_SETS(ICACHE_NR_SETS),
        .NR_WAYS(ICACHE_NR_WAYS)
    ) icache_u (
        .clk           (clk),
        .rst           (rst),
        .req_ready     (icache_req_ready),
        .req_valid     (icache_req_valid),
        .req_addr      (icache_req_addr),
        .resp_valid    (icache_resp_valid),
        .resp_ready    (icache_resp_ready),
        .resp_data     (icache_resp_data),
        .resp_rmask    (icache_resp_rmask),
        .refill        (icache_refill),
`ifdef CONFIG_IO_USE_AXI
        .icache_axi_bus(ifu_axi_bus)
`else
        .icache_mt_bus (ifu_mt_bus)
`endif
    );

    assign icache_req_fire = icache_req_valid && icache_req_ready;

    // ------------------------------------------------
    // instruction queue
    // ------------------------------------------------
    iq iq_u (
        .clk        (clk),
        .rst        (rst),
        .wvalid     (iq_wvalid),
        .wdata      (iq_wdata),
        .wmask      (iq_wmask),
        .wready     (iq_wready),
        .rvalid     (iq_rvalid),
        .raccept_cnt(iq_raccept_cnt),
        .rbits      (iq_rbits),
        .occupancy  (iq_occupancy),
        .enq_count  (iq_enq_count),
        .deq_count  (iq_deq_count),
        .flush      (backend_redirect_valid)
    );

endmodule
