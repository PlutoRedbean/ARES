// Per-hart benchmark devices. The counter advances in RTL clock cycles;
// console writes complete only when the physical UART accepts the byte.
module ares_benchmark_io #(
    parameter int unsigned CLK_HZ = 100_000_000,
    parameter int unsigned UART_BAUD = 115_200
) (
    input  logic clk, rst,
    input  logic host_req_valid,
    output logic host_req_ready,
    input  logic host_write,
    input  logic [31:0] host_addr,
    // The UART is byte-wide; only lane zero is connected.
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] host_wdata,
    input  logic [3:0] host_wstrb,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic host_rsp_valid,
    input  logic host_rsp_ready,
    output logic [31:0] host_rsp_data,
    output logic uart_tx, uart_busy
);
    localparam logic [31:0] CYCLE_LO = 32'hA000_0050;
    localparam logic [31:0] CYCLE_HI = 32'hA000_0054;
    localparam logic [31:0] UART_DATA = 32'hA000_03F8;
    localparam logic [31:0] UART_STATUS = 32'hA000_03FC;

    logic [63:0] cycles;
    wire uart_write = host_write && (host_addr == UART_DATA) && host_wstrb[0];
    wire req_fire = host_req_valid && host_req_ready;
    assign host_req_ready = !host_rsp_valid && (!uart_write || !uart_busy);

    ares_uart #(.CLK_HZ(CLK_HZ), .BAUD(UART_BAUD)) u_uart (
        .clk(clk), .rst(rst), .rx(1'b1), .tx(uart_tx),
        .tx_data(host_wdata[7:0]), .tx_start(req_fire && uart_write),
        .tx_busy(uart_busy), .rx_data(), .rx_ready()
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            cycles <= 0;
            host_rsp_valid <= 1'b0;
            host_rsp_data <= 0;
        end else begin
            cycles <= cycles + 1'b1;
            if (host_rsp_valid && host_rsp_ready) host_rsp_valid <= 1'b0;
            if (req_fire) begin
                host_rsp_valid <= 1'b1;
                host_rsp_data <= 0;
                if (!host_write) begin
                    case (host_addr)
                        CYCLE_LO: host_rsp_data <= cycles[31:0];
                        CYCLE_HI: host_rsp_data <= cycles[63:32];
                        UART_STATUS: host_rsp_data <= {31'b0, uart_busy};
                        default: host_rsp_data <= 0;
                    endcase
                end
            end
        end
    end
endmodule
