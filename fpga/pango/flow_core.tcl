# ---------------------------------------------------------------------------
# ARES core-only timing flow (ares_core_top: Backend + LSU).
#
# Inputs in this directory (scripts/pango_core_timing.py syncs them):
#   design.v        sv2v output from scripts/pango_prep.py
#   ares_core.fdc   100 MHz clock constraint, no board pins
#
# PDS runs on Windows, so this is executed from the synced working directory
# (default D:\ares_pango\core):
#
#   D:\PDS_2022.2-SP6.4\bin\pds_shell.exe -file flow_core.tcl -project_name ares_core
#
# No gen_bit_stream: this run produces resource usage and timing only.
# ---------------------------------------------------------------------------
set here [file dirname [file normalize [info script]]]

puts "ares-core: working directory [pwd]"

set_arch -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6

add_constraint [file join $here "ares_core.fdc"]
add_design [file join $here "design.v"]

compile -top_module ares_core_top -system_verilog
synthesize -ads
dev_map
pnr -seed 2
report_timing -max_path 20

puts "ares-core: done"
