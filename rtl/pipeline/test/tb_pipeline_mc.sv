//=============================================================================
// ARES pipeline multi-hart coherence SoC test
//-----------------------------------------------------------------------------
// parameter CORES selects the DUT build option (2 or 4).  The C++ main loads
// the flat image into the private IROM DPI array and drives clk/rst.  The TB
// owns the 128-bit shared-memory model behind the L2 and reports retire/EBREAK
// and a0 for each hart.
//=============================================================================
`timescale 1ns/1ps
module tb_pipeline_mc #(
    parameter integer CORES = 2,
    parameter integer DATA_STRIDE = 0
) (
    input  logic        clk, rst,
    input  logic [CORES-1:0] core_en,
    output logic        done_0, done_1, done_2, done_3,
    output logic [31:0] a0_0, a0_1, a0_2, a0_3
);
    logic [CORES-1:0]        retire_valid, retire_rd_wen, retire_is_ebreak;
    logic [CORES-1:0][ 4:0]  retire_rd;
    logic [CORES-1:0][31:0]  retire_wdata;
    logic [CORES-1:0][31:0]  retire_pc, retire_pc_next;

    logic         mem_rd_valid, mem_rd_ready, mem_rsp_valid, mem_rsp_ready;
    logic [ 31:0] mem_rd_addr, mem_wr_addr;
    logic [127:0] mem_rsp_data, mem_wr_data;
    logic [ 15:0] mem_wr_be;
    logic         mem_wr_valid, mem_wr_ready;
    logic         l2_idle, mmio_idle;
    logic [ 31:0] l2_hits, l2_misses;
    logic         uart_tx;
    logic [ 31:0] led;

    pipeline_mc_soc_top #(
        .CORES(CORES), .L2_SETS(128), .DATA_STRIDE(DATA_STRIDE)
    ) dut (
        .clk(clk), .rst(rst), .core_en(core_en),

        .mem_rd_valid(mem_rd_valid), .mem_rd_ready(mem_rd_ready),
        .mem_rd_addr(mem_rd_addr),
        .mem_rsp_valid(mem_rsp_valid), .mem_rsp_ready(mem_rsp_ready),
        .mem_rsp_data(mem_rsp_data),
        .mem_wr_valid(mem_wr_valid), .mem_wr_ready(mem_wr_ready),
        .mem_wr_addr(mem_wr_addr), .mem_wr_data(mem_wr_data),
        .mem_wr_be(mem_wr_be),

        .uart_tx(uart_tx), .led(led),

        .retire_valid(retire_valid),
        .retire_pc(retire_pc), .retire_pc_next(retire_pc_next),
        .retire_rd_wen(retire_rd_wen), .retire_rd(retire_rd),
        .retire_wdata(retire_wdata),
        .retire_is_ebreak(retire_is_ebreak),

        .l2_idle(l2_idle), .l2_hit_count(l2_hits), .l2_miss_count(l2_misses),
        .mmio_idle(mmio_idle)
    );

    //---- shared backing memory (128-bit beats) ----------------------------
    logic [127:0] mem [0:65535];
    logic         b_rsp_valid_q;
    logic [127:0] b_rsp_data_q;

    assign mem_rd_ready = 1'b1;
    assign mem_wr_ready = 1'b1;
    assign mem_rsp_valid = b_rsp_valid_q;
    assign mem_rsp_data  = b_rsp_data_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            b_rsp_valid_q <= 1'b0;
            b_rsp_data_q  <= 128'd0;
        end else if (mem_rd_valid && mem_rd_ready && !b_rsp_valid_q) begin
            b_rsp_valid_q <= 1'b1;
            b_rsp_data_q  <= mem[mem_rd_addr[19:4]];
        end else if (b_rsp_valid_q && mem_rsp_ready) begin
            b_rsp_valid_q <= 1'b0;
        end
    end

    always_ff @(posedge clk) begin
        if (mem_wr_valid && mem_wr_ready) begin
            for (int i = 0; i < 16; i++) begin
                if (mem_wr_be[i])
                    mem[mem_wr_addr[19:4]][8*i +: 8] <= mem_wr_data[8*i +: 8];
            end
        end
    end

    initial begin
        for (int i = 0; i < 65536; i++) mem[i] = 128'd0;
    end

    //---- retire / EBREAK accounting --------------------------------------
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
    assign done_2 = (CORES > 2) ? done_q[2] : 1'b1;
    assign a0_2   = (CORES > 2) ? a0_final_q[2] : 32'd0;
    assign done_3 = (CORES > 3) ? done_q[3] : 1'b1;
    assign a0_3   = (CORES > 3) ? a0_final_q[3] : 32'd0;

endmodule
