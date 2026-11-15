`timescale 1ns/1ps

// Hart 0's uncached scratchpad. CPU accesses keep the JYD bridge's two-cycle
// read latency. DMA arbitrates for the same byte-enabled 128-bit RAM port.
module pipeline_amp_minitensor (
    input  logic        clk, rst,
    input  logic        cpu_valid, cpu_write,
    output logic        cpu_ready,
    input  logic [31:0] cpu_addr, cpu_wdata,
    input  logic [3:0]  cpu_wstrb,
    output logic [31:0] cpu_rdata
);
    logic dma_valid, dma_ready, dma_write, dma_rsp_valid, dma_rsp_ready;
    logic [31:0] dma_addr;
    logic [127:0] dma_wdata, dma_rdata;
    logic [15:0] dma_wstrb;
    logic [31:0] status, result_data, perf_dma, perf_mma;

    wire regs_sel = cpu_addr[31:28] == 4'he;
    wire [2:0] reg_idx = cpu_addr[4:2];
    wire dma_fire = dma_valid && dma_ready;
    wire cpu_fire = cpu_valid && cpu_ready;
    wire cpu_mem = cpu_fire && !regs_sel;
    wire [11:0] ram_addr = dma_fire ? dma_addr[15:4] : cpu_addr[15:4];
    wire [127:0] ram_wdata = dma_fire ? dma_wdata : {4{cpu_wdata}};
    wire [15:0] cpu_be = {12'b0, cpu_wstrb} << (4 * cpu_addr[3:2]);
    wire [15:0] ram_be = dma_fire ? (dma_write ? dma_wstrb : 16'b0) :
                        (cpu_mem && cpu_write ? cpu_be : 16'b0);
    logic dma_pending, cpu_pending, cpu_regs_q;
    logic [1:0] cpu_lane_q;
    logic [31:0] reg_rdata_q;
    logic [127:0] ram_rdata_q;
    integer lane;

    (* syn_ramstyle = "block_ram", ram_style = "block" *)
    logic [127:0] scratch [0:4095];

    assign dma_ready = !rst && !dma_pending && !dma_rsp_valid;
    assign cpu_ready = !rst && (regs_sel || !dma_fire);

    always_ff @(posedge clk) begin
        if (dma_fire || cpu_mem) begin
            ram_rdata_q <= scratch[ram_addr];
            for (lane = 0; lane < 16; lane = lane + 1)
                if (ram_be[lane])
                    scratch[ram_addr][8*lane +: 8] <= ram_wdata[8*lane +: 8];
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            dma_pending <= 1'b0;
            dma_rsp_valid <= 1'b0;
            cpu_pending <= 1'b0;
        end else begin
            dma_pending <= dma_fire;
            if (dma_pending) begin
                dma_rdata <= ram_rdata_q;
                dma_rsp_valid <= 1'b1;
            end else if (dma_rsp_ready) begin
                dma_rsp_valid <= 1'b0;
            end

            cpu_pending <= cpu_fire && !cpu_write;
            if (cpu_fire && !cpu_write) begin
                cpu_regs_q <= regs_sel;
                cpu_lane_q <= cpu_addr[3:2];
                case (reg_idx)
                    3'd4: reg_rdata_q <= status;
                    3'd5: reg_rdata_q <= result_data;
                    3'd6: reg_rdata_q <= perf_dma;
                    3'd7: reg_rdata_q <= perf_mma;
                    default: reg_rdata_q <= 32'b0;
                endcase
            end
            if (cpu_pending)
                cpu_rdata <= cpu_regs_q ? reg_rdata_q : ram_rdata_q[32*cpu_lane_q +: 32];
        end
    end

    mt_cluster u_mt (
        .clk(clk), .rst(rst),
        .reg_wr_en(cpu_fire && regs_sel && cpu_write),
        .reg_wr_idx(reg_idx), .reg_wr_data(cpu_wdata),
        .status_rd(cpu_fire && regs_sel && !cpu_write && reg_idx == 3'd4),
        .status(status), .result_data(result_data),
        .l2_req_valid(dma_valid), .l2_req_ready(dma_ready),
        .l2_req_write(dma_write), .l2_req_addr(dma_addr),
        .l2_req_wdata(dma_wdata), .l2_req_wstrb(dma_wstrb),
        .l2_rsp_valid(dma_rsp_valid), .l2_rsp_ready(dma_rsp_ready),
        .l2_rsp_rdata(dma_rdata), .mt_irq(), .perf_dma(perf_dma), .perf_mma(perf_mma)
    );
endmodule
