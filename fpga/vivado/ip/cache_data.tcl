# Cache data arrays only. Tags/valid/dirty/replacement state remain in RTL.
# Native SDP, common clock, READ_FIRST and no optional output registers:
# requests accepted at edge N produce data after edge N (one-cycle contract).
# Reset is already synchronous to the stable CPU clock. Disable BMG's safety
# circuit: its extra post-reset EN cycles would violate output-hold semantics.
create_ip -name blk_mem_gen -vendor xilinx.com -library ip -version 8.4 \
    -module_name ares_icache_data_bram -dir $ares_ip_dir
set_property -dict [list CONFIG.Memory_Type Simple_Dual_Port_RAM \
    CONFIG.Write_Width_A $ares_icache_line_bits CONFIG.Write_Depth_A $ares_icache_sets \
    CONFIG.Read_Width_B $ares_icache_line_bits CONFIG.Enable_A Use_ENA_Pin \
    CONFIG.Enable_B Use_ENB_Pin CONFIG.Assume_Synchronous_Clk true \
    CONFIG.Operating_Mode_A READ_FIRST CONFIG.Use_RSTB_Pin true \
    CONFIG.Reset_Type SYNC CONFIG.EN_SAFETY_CKT false \
    CONFIG.Register_PortB_Output_of_Memory_Primitives false \
    CONFIG.Register_PortB_Output_of_Memory_Core false CONFIG.Load_Init_File false] \
    [get_ips ares_icache_data_bram]

# 8KiB / 2 ways / 8-byte rows = 512 rows per way for all 16/32/64B lines.
create_ip -name blk_mem_gen -vendor xilinx.com -library ip -version 8.4 \
    -module_name ares_dcache_data_bram -dir $ares_ip_dir
set_property -dict [list CONFIG.Memory_Type Simple_Dual_Port_RAM \
    CONFIG.Write_Width_A 64 CONFIG.Write_Depth_A 512 CONFIG.Read_Width_B 64 \
    CONFIG.Use_Byte_Write_Enable true CONFIG.Byte_Size 8 \
    CONFIG.Enable_A Use_ENA_Pin CONFIG.Enable_B Use_ENB_Pin \
    CONFIG.Assume_Synchronous_Clk true CONFIG.Operating_Mode_A READ_FIRST \
    CONFIG.Use_RSTB_Pin false CONFIG.EN_SAFETY_CKT false \
    CONFIG.Register_PortB_Output_of_Memory_Primitives false \
    CONFIG.Register_PortB_Output_of_Memory_Core false CONFIG.Load_Init_File false] \
    [get_ips ares_dcache_data_bram]
