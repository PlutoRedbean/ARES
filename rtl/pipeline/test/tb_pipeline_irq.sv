module tb_pipeline_irq;
    tb_pipeline_rtos #(.IRQ_TEST(1), .IROM_INIT_FILE("build/rtos_irq/irom.hex"),
                      .DRAM_INIT_FILE("build/rtos_irq/dram.hex")) test();
endmodule
