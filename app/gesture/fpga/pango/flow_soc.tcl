# ---------------------------------------------------------------------------
# flow_soc.tcl - PDS flow for the ARES-L application SoCs.
#
# Two applications share one RTL tree (rtl/core + rtl/minitensor + rtl/soc);
# the gesture project adds rtl/cam and its own board top.
#
#   1. tools/pango_prep.py mirrors rtl/**/*.sv into build/pango/syn/rtl/**/*.v
#      (SystemVerilog -> the ADS Verilog subset).  Plain .v files stay in rtl/.
#   2. This script adds the packages first, then the converted tree, then the
#      hand-written Verilog (core wrappers, DDR stubs, boot ROM, board top).
#
# Environment:
#   ARES_STAGE   b2 | b3 | b4 | b5   (default b5)
#                     b2  CPU + ROM + UART, no memory model
#                     b3  + BRAM behind the DDR port (self-test)
#                     b4  same as b3, boot loader firmware
#                     b5  + miniTensor (MMIO shim + accelerator)
#   ARES_BOARD   board_cpu (default) | board_gesture
#   ARES_NO_PNR  1 -> stop after dev_map (fast check)
# ---------------------------------------------------------------------------
set stage "b5"
if {[info exists ::env(ARES_STAGE)]} { set stage $::env(ARES_STAGE) }

set board "board_cpu"
if {[info exists ::env(ARES_BOARD)]} { set board $::env(ARES_BOARD) }

set do_pnr 1
if {[info exists ::env(ARES_NO_PNR)]} { set do_pnr 0 }

set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here ".." ".."]]
set syn  [file join $root "build" "pango" "syn" "rtl"]

puts "soc: stage=$stage board=$board"
puts "soc: workdir=[pwd]"

set_arch -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6
add_constraint [file join $here "board_pins.fdc"]
if {[file exists [file join $here "camera_pins.fdc"]]} {
    add_constraint [file join $here "camera_pins.fdc"]
}

proc walk {dir} {
  set out {}
  foreach f [lsort [glob -nocomplain -directory $dir *]] {
    if {[file isdirectory $f]} { set out [concat $out [walk $f]] } \
    elseif {[string match "*.v" $f]} { lappend out $f }
  }
  return $out
}

# ---------------------------------------------------------------- directives
switch -- $stage {
  b2      { set defs {ARES_NO_MT ARES_NO_DDR ARES_BOOT_ROM ARES_FPGA} }
  b3      { set defs {ARES_NO_MT ARES_BRAM ARES_BOOT_ROM ARES_FPGA} }
  b4      { set defs {ARES_NO_MT ARES_BRAM ARES_BOOT_ROM ARES_FPGA} }
  default { set defs {ARES_BRAM ARES_BOOT_ROM ARES_FPGA} }
}

# ------------------------------------------------------------------- sources
# Packages first: every converted file imports them.
set pkgs [list \
    common/ares_pkg.v \
    minitensor/common/minitensor_pkg.v \
    minitensor/tensor/tensor_pkg.v \
    minitensor/vector/vpu_pkg.v]
foreach p $pkgs { add_design [file join $syn $p] }

foreach f [walk $syn] {
    set skip 0
    foreach p $pkgs { if {[string match "*/$p" $f]} { set skip 1 } }
    # Board tops and boot ROM are added from rtl/ below (plain Verilog).
    if {[string match "*/board/*" $f]} { set skip 1 }
    if {!$skip} { add_design $f }
}

# Hand-written Verilog: core package (Mundus + wrappers + ICache), DDR stubs,
# miniTensor stub, boot ROM and the selected board top.
foreach f [walk [file join $root "rtl" "core"]] { add_design $f }
foreach f [list \
    [file join $root "rtl" "soc" "mt"  "mt_cluster_stub.v"] \
    [file join $root "rtl" "soc" "ddr" "ddr_stub.v"] \
    [file join $root "rtl" "soc" "ddr" "ddr_bram.v"] \
    [file join $root "rtl" "board" "boot_rom.v"] \
    [file join $root "rtl" "board" "$board.v"]] {
    add_design $f
}

compile -top_module $board -system_verilog -compiler_directives $defs

synthesize -ads
dev_map

if {$do_pnr} {
    pnr
    report_timing -max_path 20
    gen_bit_stream -create_bit true
}
