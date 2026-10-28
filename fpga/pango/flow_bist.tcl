# ---------------------------------------------------------------------------
# DDR3 BIST flow for the Pangu 200Pro+ (PG2L200H-6IFBB676).
#
# Top: video_bist_top (PLL + DDR3 IP + native-AXI BIST + status LEDs/UART)
# The DDR3 IP is added through its .idf; I_ips_ddr_top must be a direct child
# of the top so the absolute paths in official_ddr3.fdc match.
#
# Official Pangu 200Pro 2_9 IP: 1000 Mbps, DEVICE_100H_EN=false.
# Constraints: official_ddr3.fdc (pins / clocks / DDRPHY CPD / multicycle subset
# of the official 2_9 ipcore/ddr3_test/pnr/ddr_test.fdc).
# No PHY placement PCF is appended.  With the official 2_9 IP + FDC the design
# meets timing at 1000 Mbps and BIST passes with G=0 / E=0.
#
# Usage (Windows, from this directory):
#   D:\PDS_2022.2-SP6.4\bin\pds_shell.exe -file flow_bist.tcl -project_name video_bist
# ---------------------------------------------------------------------------
set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here ".." ".."]]

puts "video-bist: repo $root"
set_arch -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6

# IP constraints first: they create ref_clk / ddrphy_sysclk.
add_constraint [file join $here "official_ddr3.fdc"]
add_constraint [file join $here "bist_top.fdc"]

foreach f [list \
    "video_bist_top.v" \
    "video_ddr3_bist.v" \
    "video_clk_reset.v" \
    "video_ip_pll.v" \
    "video_bist_status.v" ] {
    add_design [file join $root "rtl" "video" $f]
}

add_design [file join $here "ip" "ddr3" "ddr3_test" "ddr3_test.idf"]

compile -top_module video_bist_top
synthesize -ads
dev_map
pnr -seed 2
report_timing -max_path 20
gen_bit_stream -create_bit true
