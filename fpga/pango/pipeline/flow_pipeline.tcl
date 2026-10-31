# ---------------------------------------------------------------------------
# Pango PDS flow - single-issue pipeline SoC (pipeline_board_top)
#
# Device: Pangu 200Pro+ / PG2L200H-6IFBB676
# Tool:   PDS 2022.2-SP6.4, synthesize -ads
#
# Usage (Windows, from the repository root):
#   D:\PDS_2022.2-SP6.4\bin\pds_shell.exe -file fpga/pango/pipeline/flow_pipeline.tcl -project_name pipeline_soc
#
# Prerequisites (run on the Linux/build host first):
#   make pipeline-image
#   -> build/pipeline/irom.hex and build/pipeline/dram.hex
# The flow changes the process working directory to the repository root so
# the $readmemh defaults in irom_bmem32.sv / pipeline_bram.v resolve.
# ---------------------------------------------------------------------------
set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here ".." ".." ".."]]

puts "pipeline-soc: repo $root"
cd $root

set irom_hex [file join $root "build" "pipeline" "irom.hex"]
set dram_hex [file join $root "build" "pipeline" "dram.hex"]
if {![file exists $irom_hex]} {
    error "missing $irom_hex; run 'make pipeline-image' first"
}
if {![file exists $dram_hex]} {
    error "missing $dram_hex; run 'make pipeline-image' first"
}

set_arch -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6

add_constraint [file join $here "pipeline_board.fdc"]

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

set inc_pipeline [file join $root "rtl" "pipeline" "include"]
set inc_core     [file join $root "rtl" "pipeline" "core" "vsrc" "include"]

compile -top_module {pipeline_board_top} -system_verilog \
    -include_path [list $inc_pipeline $inc_core]

synthesize -ads
dev_map
pnr -seed 2
report_timing -max_path 20
report_power
gen_bit_stream -create_bit true
