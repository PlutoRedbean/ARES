# =============================================================================
# ARES RTOS AMP + camera -> DDR3 framebuf -> HDMI — synthesize + dev_map
#
# Validates the merged FDC (AMP + camera + video PLL/HDMI + DDR3 + CDC) and
# produces resource/timing reports.  It stops before place/route.
# =============================================================================
set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here .. .. ..]]
set work [file join $root build pds_rtos_amp_hdmi_synth]
file mkdir $work
cd $work
source [file join $here stage_rtos_amp_images.tcl]

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

puts "RTOS_AMP_HDMI_SYNTH_COMPILE_START"
compile -top_module {pipeline_rtos_amp_hdmi_board_top} \
    -verilog_standard SystemVerilog \
    -compiler_directives ARES_FPGA \
    -include_path [list $inc_pipeline $inc_core $inc_video]
puts "RTOS_AMP_HDMI_SYNTH_COMPILE_DONE"

puts "RTOS_AMP_HDMI_SYNTH_START"
synthesize -ads
puts "RTOS_AMP_HDMI_SYNTH_DONE"

puts "RTOS_AMP_HDMI_DEVMAP_START"
dev_map
puts "RTOS_AMP_HDMI_DEVMAP_DONE"

# Post-synthesis timing is written to pipeline_rtos_amp_hdmi_board_top.snr.
# report_timing requires PnR; use flow_pipeline_rtos_amp_hdmi_pnr.tcl for that.
exit
