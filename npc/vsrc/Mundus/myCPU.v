module myCPU(
  input         cpu_rst     ,
  input         cpu_clk     ,
  input         timer_irq   ,
  output [31:0] irom_addr   ,
  input  [63:0] irom_data   ,
  output        perip_valid ,
  input         perip_ready ,
  input         perip_rvalid,
  output [31:0] perip_addr  ,
  output        perip_wen   ,
  output [ 1:0] perip_mask  ,
  output [31:0] perip_wdata ,
  input  [31:0] perip_rdata
);

  Mundus Mundus (
    .clock                 (cpu_clk     ),
    .reset                 (cpu_rst     ),
    .io_interrupt          (timer_irq   ),
    .io_irom_addr          (irom_addr   ),            
    .io_irom_data          (irom_data   ),   
    .io_perip_valid        (perip_valid ),
    .io_perip_ready        (perip_ready ),
    .io_perip_rvalid       (perip_rvalid),
    .io_perip_addr         (perip_addr  ),     
    .io_perip_wen          (perip_wen   ),      
    .io_perip_mask         (perip_mask  ),     
    .io_perip_wdata        (perip_wdata ),    
    .io_perip_rdata        (perip_rdata )     
  );
endmodule
