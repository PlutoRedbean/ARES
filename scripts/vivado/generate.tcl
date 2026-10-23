# Called with ares_* variables from create_project.py; no legacy sources/IPs.
set_param general.maxThreads 2
if {[version -short] ne "2025.2" && !$ares_allow_version_mismatch} {
    error "Expected Vivado 2025.2, found [version -short]; explicitly opt in to other versions"
}
open_project $ares_project
set_property source_mgmt_mode All [current_project]
set_property target_language Verilog [current_project]
set_property XPM_LIBRARIES {XPM_CDC XPM_MEMORY XPM_FIFO} [current_project]
add_files -norecurse -fileset sources_1 $ares_sources
set_property file_type SystemVerilog [get_files -of_objects [get_filesets sources_1]]
set_property include_dirs $ares_include_dirs [get_filesets sources_1]
set_property verilog_define $ares_defines [get_filesets sources_1]
set_property top $ares_top [get_filesets sources_1]
set_property top_auto_set 0 [get_filesets sources_1]
set_property top $ares_top [get_filesets sim_1]

if {$ares_profile ne "board"} {
    # External FE contract ports are intentionally retained for subsystem work.
    # Board pin constraints do not apply to these OOC ports.
    set_property -dict [list {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} {-mode out_of_context}] [get_runs synth_1]
    set clock_port [expr {$ares_profile eq "core" ? "clk" : "w_cpu_clk"}]
    set xdc [file join [file dirname $ares_project] ooc_clocks.xdc]
    set f [open $xdc w]
    puts $f "create_clock -name cpu_clk -period [expr {1000.0 / $ares_cpu_mhz}] \[get_ports $clock_port\]"
    if {$ares_profile eq "soc"} {
        puts $f {create_clock -name peripheral_clk -period 20.0 [get_ports w_clk_50Mhz]}
        puts $f {set_clock_groups -asynchronous -group [get_clocks cpu_clk] -group [get_clocks peripheral_clk]}
    }
    close $f
    lappend ares_constraints $xdc
}
if {[llength $ares_constraints]} {
    add_files -norecurse -fileset constrs_1 $ares_constraints
}
set ares_ip_dir [file join [file dirname $ares_project] ip]
file mkdir $ares_ip_dir
foreach recipe $ares_recipes { source $recipe }
if {[llength [get_ips -quiet]]} {
    generate_target all [get_ips]
    export_ip_user_files -of_objects [get_ips] -no_script -sync -force
}
update_compile_order -fileset sources_1
report_compile_order -used_in synthesis -file [file join [file dirname $ares_project] compile_order.rpt]
report_ip_status -file [file join [file dirname $ares_project] ip_status.rpt]

# Capture effective settings, so the template can be audited after tool upgrades.
set f [open [file join [file dirname $ares_project] settings.txt] w]
puts $f "Vivado=[version -short]"
puts $f "PART=[get_property PART [current_project]]"
puts $f "TOP=[get_property TOP [get_filesets sources_1]]"
puts $f "PROFILE=$ares_profile CPU_MHZ_REQUESTED=$ares_cpu_mhz"
foreach run [get_runs] {
    puts $f "RUN=[get_property NAME $run]"
    foreach prop [lsort [list_property $run]] {
        if {[string match STEPS.* $prop] || $prop in {FLOW STRATEGY AUTO_INCREMENTAL_CHECKPOINT INCREMENTAL_CHECKPOINT}} {
            puts $f "$prop=[get_property $prop $run]"
        }
    }
}
close $f

if {$ares_stage ne "generate"} {
    if {[llength [get_ips -quiet]]} {
        foreach ip [get_ips] { create_ip_run $ip }
        set ip_runs [get_runs -quiet *_synth_1]
        if {[llength $ip_runs]} {
            launch_runs $ip_runs -jobs $ares_jobs
            foreach run $ip_runs {
                wait_on_run $run
                if {[get_property PROGRESS $run] ne "100%"} { error "IP synthesis failed: $run" }
            }
        }
    }
    launch_runs synth_1 -jobs $ares_jobs
    wait_on_run synth_1
    if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { error "ARES synthesis failed" }
    open_run synth_1
    set reports [file join [file dirname $ares_project] reports]
    file mkdir $reports
    check_timing -verbose -file [file join $reports check_timing_synth.rpt]
    report_utilization -file [file join $reports utilization_synth.rpt]
    report_utilization -hierarchical -hierarchical_depth 6 -file [file join $reports hierarchy_synth.rpt]
    report_timing_summary -report_unconstrained -file [file join $reports timing_synth.rpt]
    report_timing -max_paths 100 -file [file join $reports paths_synth.rpt]
    report_cdc -file [file join $reports cdc_synth.rpt]
    if {$ares_stage eq "route"} {
        # Vivado 2025.2 calls this run step "phys_opt_design (Post-Route)".
        launch_runs impl_1 -to_step {phys_opt_design (Post-Route)} -jobs $ares_jobs
        wait_on_run impl_1
        if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { error "ARES implementation failed" }
        open_run impl_1
        check_timing -verbose -file [file join $reports check_timing_routed.rpt]
        report_timing_summary -report_unconstrained -warn_on_violation -file [file join $reports timing_routed.rpt]
        report_utilization -file [file join $reports utilization_routed.rpt]
        report_cdc -file [file join $reports cdc_routed.rpt]
        report_clocks -file [file join $reports clocks_routed.rpt]
        report_methodology -file [file join $reports methodology_routed.rpt]
        report_route_status -file [file join $reports route_status.rpt]
        report_bus_skew -file [file join $reports bus_skew_routed.rpt]
        report_timing -max_paths 100 -file [file join $reports paths_routed.rpt]
        report_exceptions -file [file join $reports exceptions_routed.rpt]
    }
}
puts "ARES_PROJECT_GENERATED=$ares_project"
puts "PPA sign-off requires review of routed timing, complete constraints and CDC; generation/synthesis is not sign-off."
close_project
