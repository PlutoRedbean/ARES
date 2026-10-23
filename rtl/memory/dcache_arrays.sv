//=============================================================================
// ARES LSU - 2-way DCache Data / Tag / LRU arrays (L07)
//-----------------------------------------------------------------------------
// Responsibilities (memory.md 6.1 / 6.3; LSU_INTERFACES.md section 9): keep the
// DCache storage.  Every Way owns an independent 1R1W 64-bit Row Data RAM
// (synchronous read R, byte-enable write W) and an independent Tag / Valid /
// Dirty metadata array (synchronous read).  Every Set owns one 1-bit LRU bit
// that records the *most recently used* Way, so the Victim candidate is the
// other Way.  Port arbitration, Way locking and read/write hazard checking are
// NOT here - they belong to L06 dcache_top (LSU_INTERFACES.md section 13).
//
// Behaviour (memory.md 6.1 / 6.3):
//   * rd_valid[w] accepts a read in cycle N; rd_rsp_valid[w] is high for
//     exactly one cycle in cycle N+1 and carries the registered request fields
//     (set / row) together with the selected 64-bit Row and the metadata word
//     {tag, line_valid, dirty} of that Set/Way.  There is no read backpressure:
//     rd_rsp_valid[w] is the one-cycle-delayed rd_valid[w].
//   * wr_valid[w] writes one 64-bit Row with byte enables wr_be[7:0].  At most
//     one Row per Way per cycle (guaranteed by the caller, L06).
//   * meta_valid[w] writes Tag / line_valid / dirty of that Way's Set.  Each
//     field carries its own enable and any combination may be written in the
//     same cycle.
//   * lru_valid writes "most recently used Way" (lru_way) of lru_set;
//     lru_rd_last_way is the combinational read of lru_rd_set.
//   * Reset clears line_valid / dirty / LRU and the read response valid only.
//     The Tag and Data arrays are deliberately NOT reset (SPEC-D9). Row data
//     lives in dcache_data_way / Block Memory Generator IP in FPGA builds.
//   * A read and a write of the same Way / Set / Row in the same cycle are
//     forbidden by memory.md 6.3 (the L06 hazard check must prevent them), so
//     this module makes no promise about read-during-write ordering.
//
// Structure (performance oriented, FREE-04): the two Ways are fully
// independent RAM instances (generate loop, no shared address decoder), the
// metadata of all Ways is read in parallel and the write byte lanes are
// independent.  No priority chain and no combinational loop exists in this
// module.
//
// Spec sources: docs/microarch/memory.md 6.1 (geometry, 1R1W per Way, separate
//   metadata), 6.3 (RAM ports and same-cycle arbitration rules handed to L06);
//   rtl/memory/LSU_INTERFACES.md section 9 (frozen interface) and section 8
//   (verification requirements).
// FREE items: FREE-02 (file organisation), FREE-04 (combinational structure),
//   FREE-11 (pipeline position: request registered in C2, response valid in C3
//   as specified by memory.md 6.2/6.3).
// Self-check bench: rtl/memory/test/unit/tb_dcache_arrays.sv
//
// Build / run (repository root; explicit file list, LINE_BYTES = 16 / 32 / 64,
// default 32; the [-DCONFIG_LINE_BYTES=..] switch selects the geometry):
//   $ verilator --lint-only -Wall --assert -Wno-DECLFILENAME -Wno-TIMESCALEMOD \
//     -DCONFIG_SIMULATION -DCONFIG_LINE_BYTES=32 --top-module dcache_arrays \
//     +incdir+configs/build/vsrc/include \
//     rtl/common/fe_pkg.sv rtl/common/ares_pkg.sv \
//     rtl/memory/dcache_data_way.sv rtl/memory/dcache_arrays.sv
//   $ verilator --binary --timing -sv --assert -Wall -Wno-DECLFILENAME \
//     -Wno-TIMESCALEMOD -DCONFIG_SIMULATION -DCONFIG_LINE_BYTES=32 \
//     +incdir+configs/build/vsrc/include \
//     --top-module tb_dcache_arrays --Mdir sim/build/unit/tb_dcache_arrays \
//     -o tb_dcache_arrays rtl/common/fe_pkg.sv rtl/common/ares_pkg.sv \
//     rtl/memory/dcache_data_way.sv rtl/memory/dcache_arrays.sv \
//     rtl/memory/test/unit/tb_dcache_arrays.sv
//   sim/build/unit/tb_dcache_arrays/tb_dcache_arrays
//   (-o is resolved against --Mdir by Verilator 5.x, so the binary lands in the
//    Mdir as sim/build/unit/<TB>/<TB>; passing the full path there fails.)
//   The bench is compiled once per line size; the default run uses 32.
//=============================================================================
module dcache_arrays (
    input  logic                                      clk,
    input  logic                                      rst,
    input  logic [ares_pkg::DCACHE_NUM_WAYS-1:0]      rd_valid,
    input  logic [ares_pkg::DCACHE_NUM_WAYS-1:0][ares_pkg::DCACHE_INDEX_BITS-1:0] rd_set,
    input  logic [ares_pkg::DCACHE_NUM_WAYS-1:0][$clog2(ares_pkg::ROWS_PER_LINE)-1:0] rd_row,
    output logic [ares_pkg::DCACHE_NUM_WAYS-1:0]      rd_rsp_valid,
    output logic [ares_pkg::DCACHE_NUM_WAYS-1:0][ares_pkg::DCACHE_INDEX_BITS-1:0] rd_rsp_set,
    output logic [ares_pkg::DCACHE_NUM_WAYS-1:0][$clog2(ares_pkg::ROWS_PER_LINE)-1:0] rd_rsp_row,
    output logic [ares_pkg::DCACHE_NUM_WAYS-1:0][63:0] rd_rsp_data,
    output logic [ares_pkg::DCACHE_NUM_WAYS-1:0][ares_pkg::DCACHE_TAG_BITS-1:0] rd_rsp_tag,
    output logic [ares_pkg::DCACHE_NUM_WAYS-1:0]      rd_rsp_line_valid,
    output logic [ares_pkg::DCACHE_NUM_WAYS-1:0]      rd_rsp_dirty,
    input  logic [ares_pkg::DCACHE_NUM_WAYS-1:0]      wr_valid,
    input  logic [ares_pkg::DCACHE_NUM_WAYS-1:0][ares_pkg::DCACHE_INDEX_BITS-1:0] wr_set,
    input  logic [ares_pkg::DCACHE_NUM_WAYS-1:0][$clog2(ares_pkg::ROWS_PER_LINE)-1:0] wr_row,
    input  logic [ares_pkg::DCACHE_NUM_WAYS-1:0][63:0] wr_data,
    input  logic [ares_pkg::DCACHE_NUM_WAYS-1:0][7:0] wr_be,
    input  logic [ares_pkg::DCACHE_NUM_WAYS-1:0]      meta_valid,
    input  logic [ares_pkg::DCACHE_NUM_WAYS-1:0][ares_pkg::DCACHE_INDEX_BITS-1:0] meta_set,
    input  logic [ares_pkg::DCACHE_NUM_WAYS-1:0][ares_pkg::DCACHE_TAG_BITS-1:0]   meta_tag,
    input  logic [ares_pkg::DCACHE_NUM_WAYS-1:0]      meta_tag_en,
    input  logic [ares_pkg::DCACHE_NUM_WAYS-1:0]      meta_line_valid_en,
    input  logic [ares_pkg::DCACHE_NUM_WAYS-1:0]      meta_line_valid,
    input  logic [ares_pkg::DCACHE_NUM_WAYS-1:0]      meta_dirty_en,
    input  logic [ares_pkg::DCACHE_NUM_WAYS-1:0]      meta_dirty,
    input  logic                                      lru_valid,
    input  logic [ares_pkg::DCACHE_INDEX_BITS-1:0]    lru_set,
    input  logic                                      lru_way,
    input  logic [ares_pkg::DCACHE_INDEX_BITS-1:0]    lru_rd_set,
    output logic                                      lru_rd_last_way
);
    import ares_pkg::*;

    //-------------------------------------------------------------------------
    // Geometry (all parameters come from ares_pkg; nothing is redeclared)
    //-------------------------------------------------------------------------
    localparam int unsigned NUM_WAYS   = DCACHE_NUM_WAYS;
    localparam int unsigned NUM_SETS   = DCACHE_NUM_SETS;
    localparam int unsigned INDEX_BITS = DCACHE_INDEX_BITS;
    localparam int unsigned TAG_BITS   = DCACHE_TAG_BITS;
    localparam int unsigned ROWS       = ROWS_PER_LINE;
    localparam int unsigned ROW_BITS   = $clog2(ROWS);
    localparam int unsigned RAM_DEPTH  = NUM_SETS * ROWS;
    localparam int unsigned RAM_BITS   = $clog2(RAM_DEPTH);

    // Row address inside one Way: set * ROWS + row (memory.md 6.3).
    function automatic logic [RAM_BITS-1:0] ram_addr(input logic [INDEX_BITS-1:0] set_i,
                                                     input logic [ROW_BITS-1:0]   row_i);
        ram_addr = RAM_BITS'(set_i) * RAM_BITS'(ROWS) + RAM_BITS'(row_i);
    endfunction

    //-------------------------------------------------------------------------
    // Registered read response (C2 request -> C3 response, memory.md 6.3)
    //-------------------------------------------------------------------------
    logic [NUM_WAYS-1:0]                          rsp_valid_q;
    logic [NUM_WAYS-1:0][INDEX_BITS-1:0]          rsp_set_q;
    logic [NUM_WAYS-1:0][ROW_BITS-1:0]            rsp_row_q;
    logic [NUM_WAYS-1:0][63:0]                    rsp_data_q;
    logic [NUM_WAYS-1:0][TAG_BITS-1:0]            rsp_tag_q;
    logic [NUM_WAYS-1:0]                          rsp_line_valid_q;
    logic [NUM_WAYS-1:0]                          rsp_dirty_q;

    assign rd_rsp_valid      = rsp_valid_q;
    assign rd_rsp_set        = rsp_set_q;
    assign rd_rsp_row        = rsp_row_q;
    assign rd_rsp_data       = rsp_data_q;
    assign rd_rsp_tag        = rsp_tag_q;
    assign rd_rsp_line_valid = rsp_line_valid_q;
    assign rd_rsp_dirty      = rsp_dirty_q;

    //-------------------------------------------------------------------------
    // Per Set replacement state: 1 bit = "Way lru[set] was used most recently",
    // the Victim candidate is ~lru[set] (memory.md 6.1).
    //-------------------------------------------------------------------------
    logic [NUM_SETS-1:0] lru_mem;

    assign lru_rd_last_way = lru_mem[lru_rd_set];

    //-------------------------------------------------------------------------
    // Two fully independent Way storage arrays
    //-------------------------------------------------------------------------
    generate
    for (genvar w = 0; w < NUM_WAYS; w++) begin : g_way
        logic [TAG_BITS-1:0] tag_mem [NUM_SETS];
        logic [NUM_SETS-1:0] line_valid_mem;   // the only directory reset state
        logic [NUM_SETS-1:0] dirty_mem;

        logic [RAM_BITS-1:0] rd_ram_addr;
        logic [RAM_BITS-1:0] wr_ram_addr;

        assign rd_ram_addr = ram_addr(rd_set[w], rd_row[w]);
        assign wr_ram_addr = ram_addr(wr_set[w], wr_row[w]);

        dcache_data_way #(.ADDR_BITS(RAM_BITS)) u_data (
            .clk(clk), .rd_en(rd_valid[w] && !rst), .rd_addr(rd_ram_addr),
            .rd_data(rsp_data_q[w]), .wr_en(wr_valid[w] && !rst),
            .wr_addr(wr_ram_addr), .wr_data(wr_data[w]), .wr_be(wr_be[w])
        );

        always_ff @(posedge clk) begin
            if (rst) begin
                // SPEC-D9: reset the directory valid/dirty bits, never the
                // Tag / Data arrays.
                line_valid_mem <= '0;
                dirty_mem      <= '0;
                rsp_valid_q[w] <= 1'b0;
            end else begin
                rsp_valid_q[w] <= rd_valid[w];

                if (rd_valid[w]) begin
                    rsp_set_q[w]        <= rd_set[w];
                    rsp_row_q[w]        <= rd_row[w];
                    rsp_tag_q[w]        <= tag_mem[rd_set[w]];
                    rsp_line_valid_q[w] <= line_valid_mem[rd_set[w]];
                    rsp_dirty_q[w]      <= dirty_mem[rd_set[w]];
                end

                if (meta_valid[w]) begin
                    if (meta_tag_en[w])        tag_mem[meta_set[w]]        <= meta_tag[w];
                    if (meta_line_valid_en[w]) line_valid_mem[meta_set[w]] <= meta_line_valid[w];
                    if (meta_dirty_en[w])      dirty_mem[meta_set[w]]      <= meta_dirty[w];
                end
            end
        end

`ifdef CONFIG_SIMULATION
        // Reset clears this Way's directory: no valid / dirty line survives.
        a_rst_no_valid_line: assert property (@(posedge clk) disable iff (rst)
            rst_q |-> ((line_valid_mem == '0) && (dirty_mem == '0)));
`endif
    end
    endgenerate

    //-------------------------------------------------------------------------
    // LRU write port
    //-------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) lru_mem <= '0;
        else if (lru_valid) lru_mem[lru_set] <= lru_way;
    end

`ifdef CONFIG_SIMULATION
    //-------------------------------------------------------------------------
    // Simulation assertions (LSU_INTERFACES.md section 9 point 6)
    //-------------------------------------------------------------------------
    logic rst_q;
    always_ff @(posedge clk) rst_q <= rst;

    // rd_rsp_valid[w] is exactly the previous cycle's rd_valid[w]; the guard
    // rst_q suppresses the two cycles around a reset (the reset itself clears
    // the response valid).
    for (genvar w = 0; w < NUM_WAYS; w++) begin : g_asrt
        a_rd_rsp_delay: assert property (@(posedge clk) disable iff (rst || rst_q)
            (rd_rsp_valid[w] == $past(rd_valid[w])));

        a_rd_rsp_fields: assert property (@(posedge clk) disable iff (rst || rst_q)
            rd_rsp_valid[w] |-> ((rd_rsp_set[w] == $past(rd_set[w]))
                              && (rd_rsp_row[w] == $past(rd_row[w]))));

        // Write enable legality: a Row write must enable at least one byte, a
        // metadata write must enable at least one field (a request without any
        // enable is a programming error and is ignored by the RTL).
        a_wr_be_nonzero: assert property (@(posedge clk) disable iff (rst)
            wr_valid[w] |-> (|wr_be[w]));

        a_meta_en_nonzero: assert property (@(posedge clk) disable iff (rst)
            meta_valid[w] |-> (meta_tag_en[w] | meta_line_valid_en[w] | meta_dirty_en[w]));
    end

    a_rst_no_lru: assert property (@(posedge clk) disable iff (rst)
        rst_q |-> (lru_mem == '0));
`endif

endmodule
