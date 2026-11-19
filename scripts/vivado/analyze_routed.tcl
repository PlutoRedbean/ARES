# Usage: vivado -mode batch -source scripts/vivado/analyze_routed.tcl \
#            -tclargs build/vivado/<completed-board-project>
# Read-only analysis of the completed implementation; no constraint changes.
set_param general.maxThreads 2
if {$argc != 1} { error "Expected one completed board build directory" }
set build [file normalize [lindex $argv 0]]
set reports [file join $build reports]
file mkdir $reports
open_project [file join $build ares.xpr]
open_run impl_1
set cpu_clock [get_clocks -of_objects [get_pins u_pll/clk_out2]]
if {[llength $cpu_clock] != 1} { error "Expected one CPU PLL output clock" }

report_timing -from $cpu_clock -to $cpu_clock -delay_type max -nworst 1 \
    -max_paths 100 -path_type full_clock_expanded -input_pins -nets \
    -file [file join $reports cpu_setup_100_routed.rpt]
report_timing -from $cpu_clock -to $cpu_clock -delay_type min -nworst 1 \
    -max_paths 30 -path_type full_clock_expanded -input_pins -nets \
    -file [file join $reports cpu_hold_30_routed.rpt]
report_utilization -hierarchical -hierarchical_depth 8 \
    -file [file join $reports hierarchy_routed.rpt]
report_clock_interaction -file [file join $reports clock_interaction_routed.rpt]
report_high_fanout_nets -timing -load_types -max_nets 30 \
    -file [file join $reports fanout_routed.rpt]
report_drc -file [file join $reports drc_routed.rpt]

set paths [get_timing_paths -from $cpu_clock -to $cpu_clock -delay_type max \
    -nworst 1 -max_paths 100]
if {![llength $paths]} { error "No CPU register-to-register setup paths" }
set props {SLACK REQUIREMENT DATAPATH_DELAY LOGIC_LEVELS STARTPOINT_PIN ENDPOINT_PIN}
set f [open [file join $reports cpu_setup_paths.tsv] w]
puts $f [join $props \t]
foreach path $paths {
    set row {}
    foreach prop $props { lappend row [get_property $prop $path] }
    puts $f [join $row \t]
}
close $f
set worst [lindex $paths 0]
set period [get_property PERIOD $cpu_clock]
set slack [get_property SLACK $worst]
set estimated_period [expr {$period-$slack}]
set f [open [file join $reports cpu_frequency_estimate.txt] w]
puts $f "CPU_CLOCK=[get_property NAME $cpu_clock]"
puts $f "CONSTRAINED_PERIOD_NS=$period"
puts $f "CPU_SETUP_WNS_NS=$slack"
puts $f "FIXED_IMPLEMENTATION_ESTIMATED_MIN_PERIOD_NS=$estimated_period"
puts $f "FIXED_IMPLEMENTATION_ESTIMATED_FMAX_MHZ=[expr {1000.0/$estimated_period}]"
puts $f "APPROX_SETUP_SLACK_AT_200MHZ_NS=[expr {$slack+5.0-$period}]"
puts $f "STARTPOINT=[get_property STARTPOINT_PIN $worst]"
puts $f "ENDPOINT=[get_property ENDPOINT_PIN $worst]"
puts $f "Estimates hold the routed paths and clock overhead fixed; they are not a new implementation or hardware frequency measurement."
close $f
puts "ARES_ROUTED_ANALYSIS=$reports"
close_project
