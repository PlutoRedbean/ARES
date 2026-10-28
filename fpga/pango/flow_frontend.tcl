# ---------------------------------------------------------------------------
# frontend-only synthesis (BPU + IFU + ICache).
#
# Inputs in this directory (synced by scripts/pango_frontend.py):
#   design.v            sv2v output of scripts/pango_prep.py (one file, all modules)
#   ares_frontend.fdc   100 MHz clock, no board pins
#
# Run (Windows, PDS cannot read the WSL repo):
#   D:\PDS_2022.2-SP6.4\bin\pds_shell.exe -file flow_frontend.tcl -project_name ares_fe
#
# Only compile + synthesize + report_timing; no dev_map/pnr/bitstream.
# Expect the compile stage to take >15 minutes (rtl-data-opt is the slow part).
# ---------------------------------------------------------------------------
set here [file dirname [file normalize [info script]]]

puts "ares-frontend: working directory [pwd]"

set_arch -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6

add_constraint [file join $here "ares_frontend.fdc"]
add_design [file join $here "design.v"]

compile -top_module frontend -system_verilog
synthesize -ads
report_timing -max_path 20

puts "ares-frontend: done"
