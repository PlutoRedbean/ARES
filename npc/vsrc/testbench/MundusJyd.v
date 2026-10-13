module MundusJyd(
  input clock,
  input reset,

  output [39:0] virtual_seg,
  output [31:0] virtual_led   
);

  student_top student_top_inst(
    .w_cpu_clk   	(clock        ),
    .w_clk_50Mhz 	(clock        ),
    .w_clk_rst   	(reset        ),
    .virtual_key 	(8'd0         ),
    .virtual_sw  	(64'd0        ),
    .uart_rx_data (8'd0         ),
    .uart_rx_ready(1'b0         ),
    .uart_tx_busy (1'b0         ),
    .uart_tx_data (             ),
    .uart_tx_start(             ),
    .virtual_led 	(virtual_led  ),
    .virtual_seg 	(virtual_seg  )
  );
  

endmodule
