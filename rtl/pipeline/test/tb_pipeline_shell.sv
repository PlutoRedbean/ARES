`timescale 1ns/1ps
module tb_pipeline_shell (
    input wire rx,
    output wire tx,
    output wire rx_available,
    output reg [31:0] tx_count = 0,
    output reg [7:0] tx_char = 0,
    output wire [7:0] led
);
    reg clk_27m = 0, rst_n = 0;
    always begin #18 clk_27m=1; #19 clk_27m=0; end
    initial begin #200000; rst_n=1; end
    pipeline_rtos_shell_board_top dut (.clk_27m(clk_27m), .rst_n(rst_n),
                                      .uart_rx(rx), .uart_tx(tx), .led(led));
    assign rx_available = rst_n && !dut.rx_full;
    reg [7:0] ch;
    initial forever begin
        @(negedge tx);
        #4340;
        if(tx !== 0) $fatal(1,"UART start bit");
        #8680;
        for(integer i=0; i<8; i=i+1) begin ch[i]=tx; #8680; end
        if(tx !== 1) $fatal(1,"UART stop bit");
        tx_char=ch;
        tx_count=tx_count+1;
    end
    always @(posedge dut.periph_clk)
        if(dut.rx_overflow) $fatal(1,"UART RX FIFO overflow");
    always @(posedge dut.cpu_clk)
        if(!dut.cpu_rst && dut.u_soc.retire_valid && dut.u_soc.retire_is_ebreak)
            $fatal(1,"Shell firmware halted");
endmodule
