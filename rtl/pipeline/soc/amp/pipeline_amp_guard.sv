`timescale 1ns/1ps

// Hart0 register bank. Each accepted write enqueues one byte or one ordered
// end-of-frame token. The result FIFO carries bytes followed by a tagged end.
module pipeline_amp_guard #(parameter bit USE_NER = 1) (
    input wire clk, rst, guard_clk, uart_overflow,
    input wire valid, write,
    input wire [3:0] addr, wstrb,
    input wire [31:0] wdata,
    output wire ready,
    output reg [31:0] rdata
);
    wire guard_rst;
    pipeline_cdc_reset_sync u_reset (.clk(guard_clk), .rst_in(rst), .rst_out(guard_rst));

    wire in_full, in_empty, consume, out_full, out_empty, produce;
    wire [8:0] in_token;
    wire [9:0] out_token, result;
    reg busy, closing, last_error;
    wire data_write = write && wstrb[0] && (addr == 4 || addr == 8);
    wire writable = !in_full && !closing;
    wire push = valid && data_write && writable;
    wire pop = valid && !write && addr == 12 && !out_empty;
    assign ready = !rst && (!data_write || writable);

    cam_fifo #(.WIDTH(9), .AW(5), .DEPTH(32)) u_input (
        .wr_clk(clk), .wr_rst(rst), .wr_en(push), .wr_data({addr == 8, wdata[7:0]}), .full(in_full),
        .rd_clk(guard_clk), .rd_rst(guard_rst), .rd_en(consume), .rd_data(in_token), .empty(in_empty)
    );
    cam_fifo #(.WIDTH(10), .AW(5), .DEPTH(32)) u_output (
        .wr_clk(guard_clk), .wr_rst(guard_rst), .wr_en(produce), .wr_data(result), .full(out_full),
        .rd_clk(clk), .rd_rst(rst), .rd_en(pop), .rd_data(out_token), .empty(out_empty)
    );

    // The board RX FIFO keeps its loss flag high until board reset. Report it
    // conservatively: after dropping bytes the wire frame boundary is unknown.
    (* ASYNC_REG = "TRUE" *) reg [1:0] uart_fault_sync;
    always @(posedge guard_clk) begin
        if (guard_rst) uart_fault_sync <= 0;
        else uart_fault_sync <= {uart_fault_sync[0], uart_overflow};
    end

    guard_stream #(.USE_NER(USE_NER)) u_stream (
        .clk(guard_clk), .rst(guard_rst), .uart_fault(uart_fault_sync[1]),
        .in_valid(!in_empty), .in_token(in_token), .consume(consume),
        .out_full(out_full), .produce(produce), .result(result)
    );

    // Match the bridge's R2 read response; capture the head before advancing.
    reg [31:0] read_q;
    always @(posedge clk) begin
        if (rst) begin
            busy <= 0;
            closing <= 0;
            last_error <= 0;
        end else if (push) begin
            busy <= 1;
            closing <= addr == 8;
        end else if (pop && out_token[8]) begin
            busy <= 0;
            closing <= 0;
            last_error <= out_token[9];
        end
        if (valid && !write) begin
            case (addr)
                0: read_q <= {27'b0, USE_NER, last_error, busy, !out_empty, writable};
                12: read_q <= out_empty ? 32'h80000000 : {22'b0, out_token};
                default: read_q <= 0;
            endcase
        end
        rdata <= read_q;
    end
endmodule
