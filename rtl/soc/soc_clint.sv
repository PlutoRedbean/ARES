//=============================================================================
// ARES SoC - minimal per-hart CLINT
//-----------------------------------------------------------------------------
// Standard CLINT register layout for NUM_HARTS machine-mode harts:
//   0x0000 + 4*hart : MSIP     (bit0 only; write 1 sets, write 0 clears)
//   0x4000 + 8*hart : MTIMECMP (64-bit, low word at +0, high at +4)
//   0xBFF8          : MTIME    (64-bit, low word at +0, high at +4)
//
// mtime increments by one whenever mtime_inc is high.  mtimecmp resets to all
// ones so a cold reset does not create a spurious timer interrupt.  mtime is
// writable for test/initialisation (real CLINT implementations differ here).
//
// The bus is a single-outstanding 32-bit request/response channel with byte
// strobes.  It is intentionally independent of the JYD perip_bridge so the
// generic 2-core top can place it behind its own MMIO xbar.
//=============================================================================
module soc_clint #(
    parameter int unsigned NUM_HARTS = 2
) (
    input  logic                    clk,
    input  logic                    rst,

    // 32-bit MMIO request/response (single outstanding)
    input  logic                    req_valid,
    output logic                    req_ready,
    input  logic                    req_write,
    input  logic [31:0]             req_addr,
    input  logic [31:0]             req_wdata,
    input  logic [3:0]              req_wstrb,
    output logic                    rsp_valid,
    input  logic                    rsp_ready,
    output logic [31:0]             rsp_data,

    // Time base and per-hart interrupt outputs
    input  logic                    mtime_inc,
    output logic [NUM_HARTS-1:0]    msip,
    output logic [NUM_HARTS-1:0]    timer_irq
);
    localparam logic [31:0] MTIMECMP_BASE = 32'h0000_4000;
    localparam logic [31:0] MTIME_LO      = 32'h0000_BFF8;
    localparam logic [31:0] MTIME_HI      = 32'h0000_BFFC;
    localparam int unsigned HART_IDX_W    = (NUM_HARTS > 1) ? $clog2(NUM_HARTS) : 1;

    logic [63:0] mtime_q;
    logic [63:0] mtimecmp_q [NUM_HARTS];
    logic [NUM_HARTS-1:0] msip_q;

    logic        rsp_valid_q;
    logic [31:0] rsp_data_q;

    //-------------------------------------------------------------------------
    // Address decode
    //-------------------------------------------------------------------------
    logic        hit_msip, hit_mtimecmp, hit_mtime;
    logic [HART_IDX_W-1:0] msip_hart, cmp_hart;
    logic        cmp_high;
    logic [31:0] rd_data;

    always_comb begin
        hit_msip     = 1'b0;
        hit_mtimecmp = 1'b0;
        hit_mtime    = 1'b0;
        msip_hart    = '0;
        cmp_hart     = '0;
        cmp_high     = 1'b0;

        // The address ranges below encode the hart index, so a hit always
        // implies a legal index for the configured NUM_HARTS.
        if (req_addr < (4*NUM_HARTS)) begin
            msip_hart = HART_IDX_W'(req_addr[3:2]);
            hit_msip  = (req_addr[1:0] == 2'b00);
        end

        if ((req_addr >= MTIMECMP_BASE)
            && (req_addr < (MTIMECMP_BASE + 32'(8*NUM_HARTS)))) begin
            cmp_hart     = HART_IDX_W'(req_addr[4:3]);
            cmp_high     = req_addr[2];
            hit_mtimecmp = (req_addr[1:0] == 2'b00);
        end

        hit_mtime = (req_addr == MTIME_LO) || (req_addr == MTIME_HI);
    end

    //-------------------------------------------------------------------------
    // Read mux
    //-------------------------------------------------------------------------
    always_comb begin
        rd_data = 32'h0;
        if (hit_msip) begin
            rd_data = {31'h0, msip_q[msip_hart]};
        end else if (hit_mtimecmp) begin
            rd_data = cmp_high ? mtimecmp_q[cmp_hart][63:32]
                               : mtimecmp_q[cmp_hart][31:0];
        end else if (hit_mtime) begin
            rd_data = (req_addr == MTIME_HI) ? mtime_q[63:32] : mtime_q[31:0];
        end
    end

    //-------------------------------------------------------------------------
    // Byte-strobed write helper
    //-------------------------------------------------------------------------
    function automatic logic [31:0] merge_wstrb(input logic [31:0] old,
                                                input logic [31:0] new_data,
                                                input logic [3:0]  strb);
        logic [31:0] v;
        begin
            v = old;
            for (int i = 0; i < 4; i++)
                if (strb[i]) v[8*i +: 8] = new_data[8*i +: 8];
            merge_wstrb = v;
        end
    endfunction

    //-------------------------------------------------------------------------
    // Bus response
    //-------------------------------------------------------------------------
    assign req_ready = !rsp_valid_q;
    assign rsp_valid = rsp_valid_q;
    assign rsp_data  = rsp_data_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            rsp_valid_q <= 1'b0;
            rsp_data_q  <= 32'h0;
        end else if (!rsp_valid_q) begin
            if (req_valid) begin
                rsp_valid_q <= 1'b1;
                rsp_data_q  <= req_write ? 32'h0 : rd_data;
            end
        end else if (rsp_ready) begin
            rsp_valid_q <= 1'b0;
        end
    end

    //-------------------------------------------------------------------------
    // MSIP / MTIMECMP / MTIME state
    //-------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            mtime_q  <= 64'h0;
            msip_q   <= '0;
            for (int h = 0; h < NUM_HARTS; h++) mtimecmp_q[h] <= 64'hFFFF_FFFF_FFFF_FFFF;
        end else begin
            if (req_valid && req_ready && req_write) begin
                if (hit_msip) begin
                    if (req_wstrb[0]) msip_q[msip_hart] <= req_wdata[0];
                end else if (hit_mtimecmp) begin
                    if (cmp_high)
                        mtimecmp_q[cmp_hart][63:32] <= merge_wstrb(mtimecmp_q[cmp_hart][63:32], req_wdata, req_wstrb);
                    else
                        mtimecmp_q[cmp_hart][31:0]  <= merge_wstrb(mtimecmp_q[cmp_hart][31:0], req_wdata, req_wstrb);
                end else if (hit_mtime) begin
                    if (req_addr == MTIME_HI)
                        mtime_q[63:32] <= merge_wstrb(mtime_q[63:32], req_wdata, req_wstrb);
                    else
                        mtime_q[31:0]  <= merge_wstrb(mtime_q[31:0], req_wdata, req_wstrb);
                end
            end

            if (mtime_inc && !(req_valid && req_ready && req_write && hit_mtime))
                mtime_q <= mtime_q + 64'd1;
        end
    end

    assign msip = msip_q;

    always_comb begin
        for (int h = 0; h < NUM_HARTS; h++)
            timer_irq[h] = (mtime_q >= mtimecmp_q[h]);
    end

endmodule
