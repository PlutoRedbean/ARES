// 50MHz-domain UART, 8N1. TX start is accepted only while !tx_busy;
// RX publishes one pulse per valid stop bit. No CPU-domain signals enter here.
module ares_uart #(
    parameter int CLK_HZ = 50_000_000,
    parameter int BAUD = 115_200
) (
    input  logic clk, rst,
    input  logic rx,
    output logic tx,
    input  logic [7:0] tx_data,
    input  logic tx_start,
    output logic tx_busy,
    output logic [7:0] rx_data,
    output logic rx_ready
);
    localparam int DIV = (CLK_HZ + BAUD/2) / BAUD;
    localparam int CW = $clog2(DIV);
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) logic [2:0] rx_sync;
    logic [CW-1:0] tx_count, rx_count;
    logic [8:0] tx_shift;
    logic [3:0] tx_bit;
    logic [2:0] rx_bit;
    logic [7:0] rx_shift;
    typedef enum logic [1:0] {IDLE, START, DATA, STOP} rx_state_t;
    rx_state_t rx_state;

    initial begin
        if (DIV < 4) $fatal(1, "UART needs at least 4 clocks per bit");
    end

    always_ff @(posedge clk) begin
        if (rst) rx_sync <= '1;
        else     rx_sync <= {rx_sync[1:0], rx};
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            tx <= 1'b1; tx_busy <= 1'b0; tx_count <= '0;
            tx_bit <= '0; tx_shift <= '1;
        end else if (!tx_busy) begin
            if (tx_start) begin
                tx_shift <= {1'b1, tx_data};
                tx <= 1'b0; tx_busy <= 1'b1;
                tx_count <= CW'(DIV-1); tx_bit <= '0;
            end
        end else if (tx_count != 0) tx_count <= tx_count - 1'b1;
        else begin
            tx_count <= CW'(DIV-1);
            tx_shift <= {1'b1, tx_shift[8:1]};
            if (tx_bit == 9) begin tx_busy <= 1'b0; tx <= 1'b1; end
            else begin tx_bit <= tx_bit + 1'b1; tx <= tx_shift[0]; end
        end
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            rx_state <= IDLE; rx_count <= '0; rx_bit <= '0;
            rx_shift <= '0; rx_data <= '0; rx_ready <= 1'b0;
        end else begin
            rx_ready <= 1'b0;
            case (rx_state)
                IDLE: if (!rx_sync[2]) begin
                    rx_count <= CW'(DIV/2-1); rx_state <= START;
                end
                START: if (rx_count != 0) rx_count <= rx_count - 1'b1;
                    else if (rx_sync[2]) rx_state <= IDLE;
                    else begin rx_count <= CW'(DIV-1); rx_bit <= '0; rx_state <= DATA; end
                DATA: if (rx_count != 0) rx_count <= rx_count - 1'b1;
                    else begin
                        rx_shift[rx_bit] <= rx_sync[2];
                        rx_count <= CW'(DIV-1);
                        if (rx_bit == 7) rx_state <= STOP;
                        else rx_bit <= rx_bit + 1'b1;
                    end
                STOP: if (rx_count != 0) rx_count <= rx_count - 1'b1;
                    else begin
                        if (rx_sync[2]) begin rx_data <= rx_shift; rx_ready <= 1'b1; end
                        rx_state <= IDLE;
                    end
                default: rx_state <= IDLE;
            endcase
        end
    end
endmodule
