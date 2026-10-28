//=============================================================================
// Buffered UART transmitter (8N1).  The console is a fire-and-forget MMIO
// byte store, so the FIFO must hold a whole output burst (CoreMark prints
// its result block at the end of the run).
//=============================================================================
module ares_board_uart_tx #(
    parameter int unsigned DIV     = 234,
    parameter int unsigned FIFO_AW = 10
) (
    input  logic       clk,
    input  logic       rst,
    input  logic       push,
    input  logic [7:0] data,
    output logic       tx,
    output logic       busy,
    output logic       overflow
);
    localparam int unsigned DEPTH = 1 << FIFO_AW;

    logic [7:0]         fifo [0:DEPTH-1];
    logic [FIFO_AW-1:0] wr_ptr, rd_ptr;
    logic [FIFO_AW:0]   count;
    wire                full  = (count == DEPTH[FIFO_AW:0]);
    wire                empty = (count == '0);
    wire                pop   = !busy && !empty;
    wire                inc   = push && !full;

    always_ff @(posedge clk) begin
        if (rst) begin
            wr_ptr   <= '0;
            rd_ptr   <= '0;
            count    <= '0;
            overflow <= 1'b0;
        end else begin
            if (inc) begin
                fifo[wr_ptr] <= data;
                wr_ptr       <= wr_ptr + 1'b1;
            end
            if (push && full) overflow <= 1'b1;
            if (pop) rd_ptr <= rd_ptr + 1'b1;
            count <= count + {{FIFO_AW{1'b0}}, inc} - {{FIFO_AW{1'b0}}, pop};
        end
    end

    logic [15:0] baud_cnt;
    logic [3:0]  bit_idx;
    logic [9:0]  shreg;

    always_ff @(posedge clk) begin
        if (rst) begin
            busy     <= 1'b0;
            baud_cnt <= 16'd0;
            bit_idx  <= 4'd0;
            shreg    <= 10'h3ff;
            tx       <= 1'b1;
        end else if (!busy) begin
            tx       <= 1'b1;
            baud_cnt <= 16'd0;
            bit_idx  <= 4'd0;
            if (!empty) begin
                shreg <= {1'b1, fifo[rd_ptr], 1'b0};   // stop, data, start
                busy  <= 1'b1;
                tx    <= 1'b0;                          // start bit now
            end
        end else if (baud_cnt == DIV[15:0] - 16'd1) begin
            baud_cnt <= 16'd0;
            tx       <= shreg[1];                       // next data/stop bit
            shreg    <= {1'b1, shreg[9:1]};
            // bit_idx 0..7 = data, 8 = stop, 9 = end of frame.  Holding the
            // stop bit for one full bit period before the next start bit is
            // what keeps a 115200 receiver in sync.
            if (bit_idx == 4'd9) busy <= 1'b0;
            else                 bit_idx <= bit_idx + 4'd1;
        end else begin
            baud_cnt <= baud_cnt + 16'd1;
        end
    end
endmodule
