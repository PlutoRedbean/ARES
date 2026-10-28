# ---------------------------------------------------------------------------
# ARES L2 board build for the Pangu 200Pro+ (PG2L200H-6IFBB676).
#
# Inputs, all in this directory (scripts/pango_build.py copies them here):
#   design.v              sv2v output from scripts/pango_prep.py
#   coremark_board.hex    48 KiB $readmemh image (scripts/build_coremark_image.py --board)
#   ares_2core.fdc        pins + 27 MHz clock
#
# PDS runs on Windows and cannot read the WSL repository, so this script is
# executed from the synced working directory (default D:\ares_pango\cpu):
#
#   D:\PDS_2022.2-SP6.4\bin\pds_shell.exe -file flow_cpu.tcl -project_name ares_cpu
#
# Stages: compile -> synthesize -ads -> dev_map -> pnr -> report_timing ->
#         gen_bit_stream.  No PLL, no DDR3; 27 MHz single clock domain.
# ---------------------------------------------------------------------------
set here [file dirname [file normalize [info script]]]

puts "ares-cpu: working directory [pwd]"
puts "ares-cpu: sources $here"

set_arch -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6

add_constraint [file join $here "ares_2core.fdc"]
add_design [file join $here "design.v"]

compile -top_module ares_pango_board -system_verilog
synthesize -ads
dev_map
pnr -seed 2
report_timing -max_path 20
gen_bit_stream -create_bit true

puts "ares-cpu: done"
