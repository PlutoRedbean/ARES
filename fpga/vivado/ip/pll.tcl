# Board differential 200MHz oscillator -> 50MHz peripherals + explicit CPU clock.
# No old XCI/DCP is imported. OOC student_top receives clocks as input ports.
create_ip -name clk_wiz -vendor xilinx.com -library ip -version 6.0 -module_name pll -dir $ares_ip_dir
set_property -dict [list CONFIG.PRIM_SOURCE Differential_clock_capable_pin \
    CONFIG.PRIM_IN_FREQ 200.000 CONFIG.NUM_OUT_CLKS 2 \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ 50.000 CONFIG.CLKOUT2_USED true \
    CONFIG.CLKOUT2_REQUESTED_OUT_FREQ $ares_cpu_mhz CONFIG.USE_RESET false \
    CONFIG.USE_LOCKED true] [get_ips pll]
