# ---------------------------------------------------------------------------
# PDS flow for the standalone video top, Pangu 200Pro+ (PG2L200H-6IFBB676).
#
# Prerequisites:
#   * fpga/pango/video_top.fdc exists (see docs/video_subsystem_v1_design.md §7.4)
#   * fpga/pango/ip/ddr3/ is copied from 5-stage-baseline
#   * rtl/video/ contains the implemented datapath (this skeleton only has
#     video_top.v with safe tie-offs)
#
# Usage (Windows):
#   cd fpga/pango
#   D:\PDS_2022.2-SP6.4\bin\pds_shell.exe -file flow_video.tcl
#
# PDS' bundled Synplify has no license on this machine, so synthesize -ads is
# the only supported path.
# ---------------------------------------------------------------------------
set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here ".." ".."]]

puts "video: repo   $root"
puts "video: fpga   $here"

set_arch -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6

# DDR3 pins, PHY placement and generated clocks live in the IP constraint file.
add_constraint [file join $here "video_top.fdc"]
add_constraint [file join $here "ip" "ddr3" "ddr3_ip.fdc"]

# Collect .v files under rtl/video, skipping test/ and sim/.
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
puts "video: added $n RTL files"

# The DDR3 IP is added through its .idf so PDS pulls in the encrypted .vp
# sources and the generated wrappers.
add_design [file join $here "ip" "ddr3" "ddr3_test" "ddr3_test.idf"]

# Stage selection: edit VIDEO_STAGE_SEL in rtl/video/video_defs.vh for PDS
# builds.  Verilator can override it with +define+VIDEO_STAGE_SEL=<n>.
compile -top_module video_top
synthesize -ads
dev_map
pnr
report_timing -max_path 20
gen_bit_stream -create_bit true
