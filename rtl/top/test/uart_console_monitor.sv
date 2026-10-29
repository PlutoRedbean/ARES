// Decode the RTL TX pin independently of the UART's internal byte interface.
`timescale 1ns/1ps
module uart_console_monitor #(
    parameter int HART_ID = 0,
    parameter int unsigned CLK_HZ = 100_000_000,
    parameter int unsigned BAUD = 115_200
) (
    input logic rst, tx
);
    localparam int DIV = (CLK_HZ + BAUD/2) / BAUD;
    localparam time BIT_TIME = time'(DIV * (1s / CLK_HZ));
    string line;
    byte character;
    int unsigned byte_count = 0;

    initial begin
        line = "";
        forever begin
            @(negedge tx);
            if (!rst) begin
                #(BIT_TIME/2);
                if (tx !== 1'b0) $fatal(1, "UART%0d invalid start bit", HART_ID);
                for (int bit_index = 0; bit_index < 8; bit_index++) begin
                    #(BIT_TIME);
                    character[bit_index] = tx;
                end
                #(BIT_TIME);
                if (tx !== 1'b1) $fatal(1, "UART%0d invalid stop bit", HART_ID);
                byte_count++;
                if (character == 8'h0A) begin
                    $display("[hart%0d] %s", HART_ID, line);
                    line = "";
                end else line = {line, $sformatf("%c", character)};
            end
        end
    end
endmodule
