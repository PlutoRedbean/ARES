# PG2L200H board flow. Run 'make pipeline-rtos-amp-pango-prep' first.
set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here .. .. ..]]
set work [file join $root build pds_rtos_amp]
set image_dir [file join $work build rtos_amp]
file mkdir $image_dir
foreach image {irom.hex dram.hex worker_irom.hex worker_dram.hex} {
    file copy -force [file join $root build rtos_amp $image] $image_dir
}
cd $work

set_arch -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6
add_constraint [file join $here pipeline_rtos_shell_board.fdc]
add_constraint [file join $here pipeline_rtos_amp_camera.fdc]
foreach list {rtl/pipeline/pipeline_amp_pango.f build/rtos_amp/pango_extra.f} {
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

compile -top_module pipeline_rtos_amp_board_top -system_verilog \
    -compiler_directives ARES_FPGA \
    -include_path [list [file join $root rtl pipeline include] \
                        [file join $root rtl pipeline core vsrc include] [file join $root rtl video]]
synthesize -ads
dev_map
pnr -seed 2
report_timing -max_path 20
report_power
gen_bit_stream -create_bit true
