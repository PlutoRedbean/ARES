# ---------------------------------------------------------------------------
# PDS flow for S0 (display bring-up only), Pangu 200Pro+ PG2L200H-6IFBB676.
#
# S0 instantiates:
#   video_clk_reset + video_ip_pll (GTP_GPLL)
#   video_hdmi_wrap + video_pattern_gen
#   video_status
#   legacy sync_vg / ms7210_ctl / iic_dri
#
# It does NOT instantiate the DDR3 IP; ddr3_pins_s0.fdc keeps the DDR3 balls
# constrained while the top ties them off.
#
# Usage (Windows, from this directory):
#   D:\PDS_2022.2-SP6.4\bin\pds_shell.exe -file flow_video_s0.tcl -project_name video_s0
# ---------------------------------------------------------------------------
set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here ".." ".."]]

puts "video-s0: repo   $root"
puts "video-s0: fpga   $here"

set_arch -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6

add_constraint [file join $here "video_top.fdc"]
# S0 leaves the unused DDR3 pins unconstrained (PDS 200H rejects the IP's
# HSTL15D_I attribute on these banks).  S2/BIST uses ip/ddr3/ddr3_ip.fdc.
add_constraint [file join $here "ddr3_pins_s0.fdc"]

proc walk_v {dir} {
    set out {}
    foreach f [lsort [glob -nocomplain -directory $dir *]] {
        if {[file isdirectory $f]} {
            set base [file tail $f]
            if {$base eq "test" || $base eq "sim"} {
                continue
            }
            set out [concat $out [walk_v $f]]
        } elseif {[string match "*.v" $f]} {
            lappend out $f
        }
    }
    return $out
}

set n 0
foreach f [walk_v [file join $root "rtl" "video"]] {
    add_design $f
    incr n
}
puts "video-s0: added $n RTL files"

compile -top_module video_top
synthesize -ads
dev_map
pnr
report_timing -max_path 20
gen_bit_stream -create_bit true
