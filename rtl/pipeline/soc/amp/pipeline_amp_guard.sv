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
    // A hart reset can be shorter than a Guard cycle. Hold the request until
    // Guard has sampled it, and keep the CPU FIFO ports idle until release
    // has crossed back. Both domains reset their logic on local clock edges.
    reg reset_req = 1'b1, reset_busy = 1'b1;
    (* ASYNC_REG = "TRUE" *) reg [1:0] guard_reset_sync = 2'b11;
    (* ASYNC_REG = "TRUE" *) reg [1:0] cpu_ack_sync = 2'b11;
    wire guard_rst = guard_reset_sync[1];
    wire cpu_rst = rst || reset_busy;

    always @(posedge guard_clk)
        guard_reset_sync <= {guard_reset_sync[0], reset_req};

    always @(posedge clk) begin
        cpu_ack_sync <= {cpu_ack_sync[0], guard_rst};
        if (rst) begin
            reset_req <= 1;
            reset_busy <= 1;
        end else if (cpu_ack_sync[1]) begin
            reset_req <= 0;
        end else if (!reset_req) begin
            reset_busy <= 0;
        end
    end

    wire in_full, in_empty, consume, out_full, out_empty, produce;
    wire [8:0] in_token;
    wire [9:0] out_token, result;
    reg busy, closing, last_error;
    wire data_write = write && wstrb[0] && (addr == 4 || addr == 8);
    wire writable = !in_full && !closing;
    wire push = valid && ready && data_write;
    wire pop = valid && ready && !write && addr == 12 && !out_empty;
    assign ready = !cpu_rst && (!data_write || writable);

    guard_token_fifo #(.WIDTH(9)) u_input (
        .wr_clk(clk), .wr_rst(cpu_rst), .wr_en(push), .wr_data({addr == 8, wdata[7:0]}), .full(in_full),
        .rd_clk(guard_clk), .rd_rst(guard_rst), .rd_en(consume), .rd_data(in_token), .empty(in_empty)
    );
    guard_token_fifo #(.WIDTH(10)) u_output (
        .wr_clk(guard_clk), .wr_rst(guard_rst), .wr_en(produce), .wr_data(result), .full(out_full),
        .rd_clk(clk), .rd_rst(cpu_rst), .rd_en(pop), .rd_data(out_token), .empty(out_empty)
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
        if (cpu_rst) begin
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

// The Gray pointers protect ownership of the RAM slot. Copy a published
// token into the receiving clock domain before its payload fans out.
module guard_token_fifo #(parameter integer WIDTH = 9) (
    input wire wr_clk, wr_rst, wr_en,
    input wire [WIDTH-1:0] wr_data,
    output wire full,
    input wire rd_clk, rd_rst, rd_en,
    output reg [WIDTH-1:0] rd_data,
    output wire empty
);
    wire [WIDTH-1:0] head;
    wire ram_empty;
    reg rd_valid;
    wire load = !rd_rst && !ram_empty && (!rd_valid || rd_en);
    cam_fifo #(.WIDTH(WIDTH), .AW(5), .DEPTH(32)) u_fifo (
        .wr_clk, .wr_rst, .wr_en, .wr_data, .full,
        .rd_clk, .rd_rst, .rd_en(load), .rd_data(head), .empty(ram_empty)
    );

    always @(posedge rd_clk) begin
        if (load)
            rd_data <= head;
        if (rd_rst)
            rd_valid <= 0;
        else if (!rd_valid || rd_en)
            rd_valid <= !ram_empty;
    end
    assign empty = !rd_valid;
endmodule
