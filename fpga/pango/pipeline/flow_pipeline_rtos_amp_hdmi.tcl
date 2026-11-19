# =============================================================================
# ARES RTOS AMP + camera -> DDR3 framebuf -> HDMI 720p30
#
# Top:    pipeline_rtos_amp_hdmi_board_top
# Device: Pangu 200Pro+ / PG2L200H-6IFBB676 (-6)
# Tool:   PDS 2025.2-SP3-EN
#
# This flow stops after the PDS compile action.  The final pin/clock FDC merge
# (AMP constraints + video_top.fdc + official_ddr3.fdc + video_fb.fdc) is
# intentionally deferred until compile/lint is clean; compile does not need
# timing constraints, and adding duplicate camera/UART/LED pin definitions from
# the standalone video FDC would only obscure RTL errors.
#
# Images: build/rtos_amp/{irom,dram,worker_irom,worker_dram}.hex must exist.
# =============================================================================
set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here .. .. ..]]
set work [file join $root build pds_rtos_amp_hdmi]
file mkdir $work
cd $work
source [file join $here stage_rtos_amp_images.tcl]

set_arch -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6

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

# Pango DDR3 IP (official 200Pro 2_9 IP).  The instance inside the RTL MUST be
# I_ips_ddr_top; official_ddr3.fdc references that absolute path.
add_design [file join $root fpga pango ip ddr3 ddr3_test ddr3_test.idf]

set inc_pipeline [file join $root rtl pipeline include]
set inc_core     [file join $root rtl pipeline core vsrc include]
set inc_video    [file join $root rtl video]

puts "RTOS_AMP_HDMI_COMPILE_START"
compile -top_module {pipeline_rtos_amp_hdmi_board_top} \
    -verilog_standard SystemVerilog \
    -compiler_directives ARES_FPGA \
    -include_path [list $inc_pipeline $inc_core $inc_video]
puts "RTOS_AMP_HDMI_COMPILE_DONE"
exit
