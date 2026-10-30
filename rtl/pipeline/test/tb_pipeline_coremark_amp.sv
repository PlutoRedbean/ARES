//=============================================================================
// ARES pipeline private-memory AMP full-accelerated CoreMark TB
//=============================================================================
`timescale 1ns/1ps
module tb_pipeline_coremark_amp #(
    parameter integer CORES = 2
) (
    input  logic        clk, rst,
    input  logic [CORES-1:0] core_en,
    output logic        done_0, done_1,
    output logic [31:0] a0_0, a0_1
);
    logic [CORES-1:0]        retire_valid, retire_rd_wen, retire_is_ebreak;
    logic [CORES-1:0][ 4:0]  retire_rd;
    logic [CORES-1:0][31:0]  retire_wdata;
    logic [CORES-1:0][31:0]  retire_pc, retire_pc_next;

    pipeline_coremark_amp_top #(
        .CORES(CORES),
        .DATA_STRIDE(32'h0000_8000)
    ) dut (
        .clk(clk), .rst(rst), .core_en(core_en),
        .retire_valid(retire_valid),
        .retire_pc(retire_pc), .retire_pc_next(retire_pc_next),
        .retire_rd_wen(retire_rd_wen), .retire_rd(retire_rd),
        .retire_wdata(retire_wdata),
        .retire_is_ebreak(retire_is_ebreak)
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

    assign done_0 = done_q[0];
    assign a0_0   = a0_final_q[0];
    assign done_1 = (CORES > 1) ? done_q[1] : 1'b1;
    assign a0_1   = (CORES > 1) ? a0_final_q[1] : 32'd0;

endmodule
