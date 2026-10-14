# JYD platform memories required by migrated student_top/bram_driver.
# Source RTL contracts: IROM one-cycle read, BRAM registered two-cycle read.
create_ip -name blk_mem_gen -vendor xilinx.com -library ip -version 8.4 -module_name IROM_BMEM -dir $ares_ip_dir
set rom_props [list CONFIG.Memory_Type Single_Port_ROM CONFIG.Write_Width_A 64 \
    CONFIG.Write_Depth_A 4096 CONFIG.Read_Width_A 64 CONFIG.Enable_A Always_Enabled \
    CONFIG.Register_PortA_Output_of_Memory_Primitives false \
    CONFIG.Register_PortA_Output_of_Memory_Core false CONFIG.Fill_Remaining_Memory_Locations true \
    CONFIG.Remaining_Memory_Locations 0]
if {$ares_irom_coe ne ""} {
    lappend rom_props CONFIG.Load_Init_File true CONFIG.Coe_File $ares_irom_coe
} else { lappend rom_props CONFIG.Load_Init_File false }
set_property -dict $rom_props [get_ips IROM_BMEM]

create_ip -name blk_mem_gen -vendor xilinx.com -library ip -version 8.4 -module_name BRAM -dir $ares_ip_dir
set ram_props [list CONFIG.Memory_Type Simple_Dual_Port_RAM CONFIG.Write_Width_A 32 \
    CONFIG.Write_Depth_A 65536 CONFIG.Read_Width_B 32 CONFIG.Use_Byte_Write_Enable true \
    CONFIG.Byte_Size 8 CONFIG.Enable_A Always_Enabled CONFIG.Enable_B Always_Enabled \
    CONFIG.Register_PortB_Output_of_Memory_Primitives false \
    CONFIG.Register_PortB_Output_of_Memory_Core true CONFIG.Fill_Remaining_Memory_Locations true \
    CONFIG.Remaining_Memory_Locations 0]
if {$ares_dram_coe ne ""} {
    lappend ram_props CONFIG.Load_Init_File true CONFIG.Coe_File $ares_dram_coe
} else { lappend ram_props CONFIG.Load_Init_File false }
set_property -dict $ram_props [get_ips BRAM]
