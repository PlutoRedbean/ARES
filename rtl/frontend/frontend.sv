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
// internal.  The back-end only needs to respect the IQ handshake and to send
// its resolutions back in program order (see docs).
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
    input  logic iq_rready,
    input  logic [$clog2(fe_pkg::DECODE_WIDTH + 1) - 1:0] iq_raccept_cnt,  // instructions accepted

    // ---------- back-end -> front-end ----------
    // branch/jump resolution redirect.  Valid for one cycle; flushes the whole
    // front-end (BPU/FTQ/IFU and the IQ) and restarts fetch at `backend_redirect_pc`.
    input logic                    backend_redirect_valid,
    input logic [ADDR_WIDTH - 1:0] backend_redirect_pc,

    // BPU training.  Must be driven in program order, at most one CFI per cycle.
    input logic              bpu_update_en,
    input fe_pkg::update_meta_t bpu_update_meta,

    // ---------- instruction cache AXI4-Lite master ----------
    axi_if.master ifu_axi_bus,

    // ---------- debug / side-channel ----------
    output logic [ADDR_WIDTH - 1:0] fetch_pc_out
);
    import fe_pkg::*;

    // ------------------------------------------------
    // IFU <-> IQ write channel (internal)
    // ------------------------------------------------
    logic                                            iq_wvalid;
    iq_entry_t                                       iq_wdata[FETCH_WIDTH];
    logic [FETCH_WIDTH - 1:0]                        iq_wmask;
    logic                                            iq_wready;

    // ------------------------------------------------
    // BPU -> FTQ -> IFU links (internal)
    // ------------------------------------------------
    ftq_entry_t                     ftq_wdata;
    ftq_entry_t                     ftq_rdata;
    logic                           ftq_wvalid;
    logic                           ftq_wready;
    logic                           ftq_rvalid;
    logic                           ifu_rready;

    // front-end (PredecodeCheck) redirect
    logic                    fe_redirect_valid;
    logic [ADDR_WIDTH - 1:0] fe_redirect_pc;

    // back-end redirect wins over the front-end one
    wire fe_flush = backend_redirect_valid | fe_redirect_valid;
    wire [ADDR_WIDTH - 1:0] fe_redirect_pc_sel =
        backend_redirect_valid ? backend_redirect_pc : fe_redirect_pc;

    /* verilator lint_off UNUSEDSIGNAL */
    logic [ADDR_WIDTH - 1:0] bpu_resp_pc;
    /* verilator lint_on UNUSEDSIGNAL */

    // ------------------------------------------------
    // IFU <-> ICache channel (internal)
    // ------------------------------------------------
    logic                     icache_req_valid;
    logic [ADDR_WIDTH - 1:0]  icache_req_addr;
    logic                     icache_req_ready;
    logic                     icache_resp_valid;
    logic [ADDR_WIDTH - 1:0]  icache_resp_data[FETCH_WIDTH];
    logic [FETCH_WIDTH - 1:0] icache_resp_rmask;
    logic                     icache_resp_ready;

    // ------------------------------------------------
    // branch prediction unit
    // ------------------------------------------------
    bpu #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .RESET_VEC (RESET_VEC)
    ) bpu_u (
        .clk        (clk),
        .rst        (rst),
        .flush      (fe_flush),
        .redirect_pc(fe_redirect_pc_sel),
        .ftq_wready (ftq_wready),
        .ftq_wvalid (ftq_wvalid),
        .bpu_resp_pc(bpu_resp_pc),
        .ftq_wdata  (ftq_wdata),
        .update_en  (bpu_update_en),
        .update_meta(bpu_update_meta)
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
        .rdata(ftq_rdata)
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
        .LINE_BYTES(32),
        .NR_SETS(64),
        .NR_WAYS(4)
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
        .icache_axi_bus(ifu_axi_bus)
    );

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
        .rready     (iq_rready),
        .raccept_cnt(iq_raccept_cnt),
        .rbits      (iq_rbits),
        .flush      (backend_redirect_valid)
    );

endmodule
