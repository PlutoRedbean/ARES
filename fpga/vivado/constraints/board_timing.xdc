# The clock wizard supplies the 5ns primary clock and generated clocks in its
# scoped pll.xdc. Do not create a second primary clock on the same input.

# The UART is asynchronous. Input delay is bookkeeping against the reference
# clock, with only the first synchronizer D pin excepted. Later stages are timed.
set_input_delay -clock [get_clocks -of_objects [get_ports i_sys_clk_p]] -max 0.0 [get_ports i_uart_rx]
set_input_delay -clock [get_clocks -of_objects [get_ports i_sys_clk_p]] -min 0.0 [get_ports i_uart_rx]
set_false_path -from [get_ports i_uart_rx] -to [get_pins -hier -regexp {^u_uart/rx_sync_reg\[0\]/D$}]

# These outputs are local display levels / an asynchronous UART. Use a
# conservative 2ns external output budget against the 50MHz launch clock.
set peripheral_clock [get_clocks -of_objects [get_pins u_pll/clk_out1]]
set_output_delay -clock $peripheral_clock -max 2.0 [get_ports {o_uart_tx virtual_led[*] virtual_seg[*]}]
set_output_delay -clock $peripheral_clock -min 0.0 [get_ports {o_uart_tx virtual_led[*] virtual_seg[*]}]

# PLL lock is asynchronous to each reset chain. Only the asynchronous preset
# pins of the reset conditioners are excepted; their synchronous outputs and
# all downstream reset fanout remain timed.
set_false_path -to [get_pins -hier -filter {NAME =~ */release_pipe_reg*/PRE}]

# Toggle synchronizers in perip_bridge. Source data is held until the
# round-trip acknowledgement. Only first-stage D pins are asynchronous.
set_false_path -to [get_pins -hier -regexp {^.*/console_tx_ack_sync_cpu_reg\[0\]/D$}]
set_false_path -to [get_pins -hier -regexp {^.*/console_tx_req_sync_cnt_reg\[0\]/D$}]
set_false_path -to [get_pins -hier -regexp {^.*/console_rx_req_sync_cpu_reg\[0\]/D$}]
set_false_path -to [get_pins -hier -regexp {^.*/console_rx_ack_sync_cnt_reg\[0\]/D$}]
# Bound the stable data crossing before the synchronized request is consumed.
# CPU->50MHz gets one peripheral cycle; 50MHz->CPU gets one CPU cycle.
set_max_delay -datapath_only 20.0 \
    -from [get_cells -hier -filter {NAME =~ */console_tx_data_cpu_reg*}] \
    -to [get_cells -hier -filter {NAME =~ */uart_tx_data_reg*}]
set cpu_clock [get_clocks -of_objects [get_pins u_pll/clk_out2]]
set_max_delay -datapath_only [get_property PERIOD $cpu_clock] \
    -from [get_cells -hier -filter {NAME =~ */console_rx_data_cnt_reg*}] \
    -to [get_cells -hier -filter {NAME =~ */console_rx_data_reg*}]
