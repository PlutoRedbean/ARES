//=============================================================================
// ARES pipeline private-memory AMP full-accelerated CoreMark TB
//=============================================================================
`timescale 1ns/1ps
module tb_pipeline_coremark_amp #(
    parameter integer CORES        = 2,
    parameter integer USE_ICACHE   = 1,
    parameter integer ICACHE_LINES = 256
) (
    input  logic        clk, rst,
    input  logic [CORES-1:0] core_en,
    // Four completion ports so the same testbench wrapper (and sim main)
    // works for CORES=2 and CORES=4; unused ports read as done/a0=0.
    output logic        done_0, done_1, done_2, done_3,
    output logic [31:0] a0_0, a0_1, a0_2, a0_3
);
    logic [CORES-1:0]        retire_valid, retire_rd_wen, retire_is_ebreak;
    logic [CORES-1:0][ 4:0]  retire_rd;
    logic [CORES-1:0][31:0]  retire_wdata;
    logic [CORES-1:0][31:0]  retire_pc, retire_pc_next;

    pipeline_amp_top #(
        .CORES(CORES),
        .DATA_STRIDE(32'h0000_8000),
        .USE_ICACHE(USE_ICACHE),
        .ICACHE_LINES(ICACHE_LINES)
    ) dut (
        .clk(clk), .rst(rst), .core_en(core_en),
        .retire_valid(retire_valid),
        .retire_pc(retire_pc), .retire_pc_next(retire_pc_next),
        .retire_rd_wen(retire_rd_wen), .retire_rd(retire_rd),
        .retire_wdata(retire_wdata),
        .retire_is_ebreak(retire_is_ebreak),
        .uart_tx(), .led(), .periph_clk(1'b0), .periph_rst(1'b0),
        .uart_rx(1'b1), .rx_full(), .rx_overflow(),
        .pixel_clk(1'b0), .pixel_rst(1'b1), .pixel_vsync(1'b0),
        .pixel_de(1'b0), .pixel_rgb565(16'b0)
    );

    logic [CORES-1:0]        done_q;
    logic [CORES-1:0][31:0]  a0_q, a0_final_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            done_q     <= {CORES{1'b0}};
            a0_q       <= '0;
            a0_final_q <= '0;
        end else begin
            for (int i = 0; i < CORES; i++) begin
                if (retire_valid[i]) begin
                    if (retire_rd_wen[i] && (retire_rd[i] == 5'd10))
                        a0_q[i] <= retire_wdata[i];
                    if (retire_is_ebreak[i]) begin
                        done_q[i]     <= 1'b1;
                        a0_final_q[i] <= a0_q[i];
                    end
                end
            end
        end
    end

    logic [3:0]        done_out;
    logic [3:0][31:0]  a0_out;

    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : g_status
            if (gi < CORES) begin : g_used
                assign done_out[gi] = done_q[gi];
                assign a0_out[gi]   = a0_final_q[gi];
            end else begin : g_unused
                assign done_out[gi] = 1'b1;
                assign a0_out[gi]   = 32'd0;
            end
        end
    endgenerate

    assign done_0 = done_out[0];
    assign done_1 = done_out[1];
    assign done_2 = done_out[2];
    assign done_3 = done_out[3];
    assign a0_0   = a0_out[0];
    assign a0_1   = a0_out[1];
    assign a0_2   = a0_out[2];
    assign a0_3   = a0_out[3];

endmodule
