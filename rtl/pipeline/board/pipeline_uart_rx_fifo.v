`timescale 1ns/1ps
// Shell-only UART-domain FIFO ahead of the existing one-byte CDC mailbox.
// A mailbox byte remains stable until the CPU's read-consumed toggle returns.
module pipeline_uart_rx_fifo (
    input wire cpu_clk, input wire cpu_rst, input wire consumed,
    input wire clk, input wire rst,
    input wire [7:0] raw_data, input wire raw_ready,
    output reg [7:0] data, output reg ready,
    output wire full, output reg overflow
);
    reg consumed_toggle;
    always @(posedge cpu_clk) begin
        if(cpu_rst) consumed_toggle <= 0;
        else if(consumed) consumed_toggle <= ~consumed_toggle;
    end
    (* ASYNC_REG = "TRUE" *) reg [1:0] ack_sync;
    reg ack_seen, busy, raw_ready_d;
    reg [7:0] mem [0:127];
    reg [6:0] rd_ptr, wr_ptr;
    reg [7:0] count;
    wire pop = !busy && count != 0;
    wire arrival = raw_ready && !raw_ready_d;
    wire push = arrival && (!full || pop);
    assign full = count == 128;
    always @(posedge clk) begin
        if(rst) begin
            ack_sync<=0; ack_seen<=0; busy<=0; raw_ready_d<=0;
            rd_ptr<=0; wr_ptr<=0; count<=0; ready<=0; overflow<=0;
        end else begin
            ack_sync <= {ack_sync[0], consumed_toggle};
            raw_ready_d <= raw_ready;
            ready <= 0;
            if(ack_sync[1] != ack_seen) begin
                ack_seen <= ack_sync[1]; busy <= 0;
            end
            if(pop) begin
                data <= mem[rd_ptr]; rd_ptr <= rd_ptr+1'b1;
                ready <= 1; busy <= 1;
            end
            if(push) begin mem[wr_ptr] <= raw_data; wr_ptr <= wr_ptr+1'b1; end
            if(arrival && !push) overflow <= 1;
            case ({push,pop})
                2'b10: count <= count+1'b1;
                2'b01: count <= count-1'b1;
                default: ;
            endcase
        end
    end
endmodule
