# Sourced after generate.tcl by verify_cache_ip.py. Uses vendor BMG + UNISIM
# models, rather than the behavioral branch used by normal Verilator tests.
open_project $ares_project
set ares_ip_dir [file join $ares_build_dir ip]
open_run synth_1
set bram_count [llength [get_cells -hier -filter {REF_NAME == RAMB36E1}]]
if {$bram_count != 34} { error "Expected 34 cache data RAMB36E1, found $bram_count" }
puts "CACHE_BRAM_RAM36=$bram_count"
close_design
set sim_files [glob [file join $ares_build_dir verification_inputs *.sv]]
add_files -norecurse -fileset sim_1 $sim_files
set sim_defs [concat $ares_defines {CONFIG_SIMULATION ARES_CACHE_IP_SIM}]
foreach item {{tb_icache_way 32} {tb_dcache_arrays 16} {tb_dcache_arrays 32} {tb_dcache_arrays 64} {tb_dcache_top 32}} {
    lassign $item tb line_bytes
    set defs {}
    foreach def $sim_defs {
        if {![string match CONFIG_LINE_BYTES=* $def]} { lappend defs $def }
    }
    lappend defs CONFIG_LINE_BYTES=$line_bytes
    set_property verilog_define $defs [get_filesets sim_1]
    set_property top $tb [get_filesets sim_1]
    set_property top_auto_set 0 [get_filesets sim_1]
    set_property xsim.simulate.runtime all [get_filesets sim_1]
    update_compile_order -fileset sim_1
    launch_simulation -simset sim_1 -mode behavioral
    close_sim
    set log [file join $ares_build_dir ares.sim sim_1 behav xsim simulate.log]
    set f [open $log r]; set result [read $f]; close $f
    set saved [file join $ares_build_dir verification_results bmg-${tb}-${line_bytes}.log]
    file copy -force $log $saved
    if {![string match {*ALL TESTS PASSED*} $result] || [regexp {FATAL|Fatal:|Error:} $result]} {
        error "Vendor cache IP simulation failed: bmg $tb LINE_BYTES=$line_bytes (see $saved)"
    }
    puts "CACHE_IP_PASS=bmg $tb LINE_BYTES=$line_bytes"
}
close_project

# Compile primitive netlists explicitly in fresh work libraries. Project-based
# incremental simulation can retain compiled BMG wrappers, even when those
# generated files are disabled; never use it as evidence of primitive testing.
set shared {}
foreach name {fe_pkg.sv ares_pkg.sv lsu_pkg.sv icache_data_way.sv dcache_data_way.sv dcache_arrays.sv dcache_top.sv} {
    set matches [lsearch -all -inline -glob $ares_sources */$name]
    if {[llength $matches] != 1} { error "Cannot locate verification source $name" }
    lappend shared [lindex $matches 0]
}
foreach ip {ares_icache_data_bram ares_dcache_data_bram} {
    lappend shared [file join $ares_ip_dir $ip ${ip}_sim_netlist.v]
}
set start_dir [pwd]
foreach item {{tb_icache_way 32} {tb_dcache_arrays 16} {tb_dcache_arrays 32} {tb_dcache_arrays 64} {tb_dcache_top 32}} {
    lassign $item tb line_bytes
    set result_dir [file join $ares_build_dir verification_results primitive-${tb}-${line_bytes}]
    file mkdir $result_dir
    cd $result_dir
    set compile [list xvlog --sv --work work]
    foreach inc $ares_include_dirs { lappend compile -i $inc }
    foreach def $sim_defs {
        if {![string match CONFIG_LINE_BYTES=* $def]} { lappend compile -d $def }
    }
    lappend compile -d CONFIG_LINE_BYTES=$line_bytes
    lappend compile {*}$shared [file join $ares_build_dir verification_inputs ${tb}.sv]
    exec {*}$compile > compile.log 2>@1
    exec xelab --relax --mt 2 -L unisims_ver -s cache_primitive work.$tb work.glbl > elaborate.log 2>@1
    exec xsim cache_primitive -runall -log simulate.log > stdout.log 2>@1
    set f [open simulate.log r]; set result [read $f]; close $f
    if {![string match {*ALL TESTS PASSED*} $result] ||
        [regexp {FATAL|Fatal:|Error:|using a behavioral model} $result]} {
        error "Primitive cache IP simulation failed: $tb LINE_BYTES=$line_bytes (see $result_dir)"
    }
    puts "CACHE_IP_PASS=primitive $tb LINE_BYTES=$line_bytes"
    cd $start_dir
}
