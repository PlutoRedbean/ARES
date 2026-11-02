# ---------------------------------------------------------------------------
# Pango PDS flow - single-issue pipeline SoC (pipeline_rtos_board_top)
#
# Device: Pangu 200Pro+ / PG2L200H-6IFBB676
# Tool:   PDS 2022.2-SP6.4, synthesize -ads
#
# Usage (Windows, from the repository root):
#   D:\PDS_2022.2-SP6.4\bin\pds_shell.exe -file fpga/pango/pipeline/flow_pipeline_rtos.tcl -project_name pipeline_rtos
#
# Prerequisites (run on the Linux/build host first):
#   make rtos-image
#   -> build/rtos/irom.hex and build/rtos/dram.hex
# The flow snapshots RTOS images and implements under build/pds_rtos;
# the RTOS top selects build/rtos/*.hex relative to that workspace.
# ---------------------------------------------------------------------------
set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here ".." ".." ".."]]

puts "pipeline-rtos: repo $root"
cd $root

set irom_hex [file join $root "build" "rtos" "irom.hex"]
set dram_hex [file join $root "build" "rtos" "dram.hex"]
if {![file exists $irom_hex]} {
    error "missing $irom_hex; run 'make rtos-image' first"
}
if {![file exists $dram_hex]} {
    error "missing $dram_hex; run 'make rtos-image' first"
}

# Keep implementation reports, temporary netlists and bitstreams out of the
# existing CoreMark project. Relative RAM initialization paths resolve here.
set work [file join $root "build" "pds_rtos"]
set image_dir [file join $work "build" "rtos"]
file mkdir $image_dir
file copy -force $irom_hex [file join $image_dir "irom.hex"]
file copy -force $dram_hex [file join $image_dir "dram.hex"]
cd $work

set_arch -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6

add_constraint [file join $here "pipeline_rtos_board.fdc"]

# ---------------------------------------------------------------------------
# Source list: reuse rtl/pipeline/pipeline_pango.f (keeps simulation-only DPI
# models and the XPM CDC library out of the synthesis project).
# ---------------------------------------------------------------------------
set fp [open [file join $root "rtl" "pipeline" "pipeline_pango.f"] r]
while {[gets $fp line] >= 0} {
    set line [string trim $line]
    if {$line eq ""} { continue }
    if {[string index $line 0] eq "#"} { continue }
    if {[string match "+incdir+*" $line]} { continue }
    add_design [file join $root $line]
}
close $fp
add_design [file join $root "rtl" "pipeline" "board" "pipeline_rtos_board_top.v"]

set inc_pipeline [file join $root "rtl" "pipeline" "include"]
set inc_core     [file join $root "rtl" "pipeline" "core" "vsrc" "include"]

compile -top_module {pipeline_rtos_board_top} -system_verilog \
    -include_path [list $inc_pipeline $inc_core]

synthesize -ads
dev_map
pnr -seed 2
report_timing -max_path 20
report_power
gen_bit_stream -create_bit true
