#!/usr/bin/env python3
"""Validate PDS flow paths with Tcl stubs; this does not run PDS or timing."""
import hashlib
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
profile = 'rtos'
flow = root / f'fpga/pango/pipeline/flow_pipeline_{profile}.tcl'
stubs = r'''
proc set_arch {args} {}
proc add_constraint {path} {if {![file exists $path]} {error "missing constraint $path"}}
proc add_design {path} {if {![file exists $path]} {error "missing source $path"}}
proc compile {args} {
    if {[lindex $args 1] ne "pipeline_rtos_board_top"} {error "wrong top"}
}
proc synthesize {args} {}
proc dev_map {args} {}
proc pnr {args} {}
proc report_timing {args} {}
proc report_power {args} {}
proc gen_bit_stream {args} {}
if {[catch {source [lindex $argv 0]} msg]} {puts stderr $msg; exit 1}
puts "PDS Tcl path validation PASS (PDS not executed)"
'''
# Tcl's '-' reads the script from stdin; the following argument is the flow.
subprocess.run(['tclsh', '-', str(flow)], input=stubs.replace('[lindex $argv 0]', '[lindex $argv 1]').replace('pipeline_rtos_board_top', f'pipeline_{profile}_board_top'),
               text=True, cwd=root, check=True)
for name in ('irom.hex', 'dram.hex'):
    src = root / f'build/{profile}' / name
    dst = root / f'build/pds_{profile}/build/{profile}' / name
    assert hashlib.sha256(src.read_bytes()).digest() == hashlib.sha256(dst.read_bytes()).digest()
