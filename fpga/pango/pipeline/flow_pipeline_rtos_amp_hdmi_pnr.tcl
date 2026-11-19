# =============================================================================
# ARES RTOS AMP + camera -> DDR3 framebuf -> HDMI — full PnR + bitstream
#
# Run from the repository root (or copy to a standalone project directory):
#   pds_shell.exe -file fpga/pango/pipeline/flow_pipeline_rtos_amp_hdmi_pnr.tcl \
#       -project_name pipeline_rtos_amp_hdmi_pnr
# =============================================================================
set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here .. .. ..]]
set work [file join $root build pds_rtos_amp_hdmi_pnr]
file mkdir $work
cd $work

set_arch -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6
add_constraint [file join $root fpga pango pipeline pipeline_rtos_amp_hdmi.fdc]

foreach list {rtl/pipeline/pipeline_amp_pango.f build/rtos_amp/pango_extra.f rtl/pipeline/pipeline_rtos_amp_hdmi_extra.f} {
    set fp [open [file join $root $list] r]
    while {[gets $fp line] >= 0} {
        set line [string trim $line]
        if {$line eq "" || [string index $line 0] eq "#" || [string match "+incdir+*" $line]} {
            continue
        }
        add_design [file join $root $line]
    }
    close $fp
}

add_design [file join $root fpga pango ip ddr3 ddr3_test ddr3_test.idf]

set inc_pipeline [file join $root rtl pipeline include]
set inc_core     [file join $root rtl pipeline core vsrc include]
set inc_video    [file join $root rtl video]

puts "RTOS_AMP_HDMI_PNR_COMPILE_START"
compile -top_module {pipeline_rtos_amp_hdmi_board_top} \
    -verilog_standard SystemVerilog \
    -compiler_directives ARES_FPGA \
    -include_path [list $inc_pipeline $inc_core $inc_video]
puts "RTOS_AMP_HDMI_PNR_COMPILE_DONE"

puts "RTOS_AMP_HDMI_PNR_SYNTH_START"
synthesize -ads
puts "RTOS_AMP_HDMI_PNR_SYNTH_DONE"

puts "RTOS_AMP_HDMI_PNR_DEVMAP_START"
dev_map
puts "RTOS_AMP_HDMI_PNR_DEVMAP_DONE"

puts "RTOS_AMP_HDMI_PNR_PLACE_START"
pnr -gplace_seed 2 -groute_seed 2 -gplace_times 1 -groute_times 1
puts "RTOS_AMP_HDMI_PNR_PLACE_DONE"

puts "RTOS_AMP_HDMI_PNR_REPORT_START"
report_timing -max_path 20
puts "RTOS_AMP_HDMI_PNR_REPORT_DONE"

puts "RTOS_AMP_HDMI_PNR_BITSTREAM_START"
gen_bit_stream -create_bit true
puts "RTOS_AMP_HDMI_PNR_BITSTREAM_DONE"

set sbit [file join [pwd] prj_tasks pnr_1 generate_bitstream pipeline_rtos_amp_hdmi_board_top.sbit]
if {[file exists $sbit]} {
    file mkdir [file join [pwd] generate_bitstream]
    file copy -force $sbit [file join [pwd] generate_bitstream pipeline_rtos_amp_hdmi_board_top.sbit]
    puts "RTOS_AMP_HDMI_PNR_BITSTREAM_COPIED"
}
exit
