# ScreenSense - camera -> DDR3 -> HDMI + YOLO overlay
# Video pipeline from the working S2 build; YOLO front end from rtl_pds.
set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here ".." ".."]]
set rtlpds [file normalize [file join $root ".." "fpga" "rtl_pds"]]

set_arch -family Logos2 -device PG2L200H -package FBB676 -speedgrade -6

add_constraint [file join $here "official_ddr3.fdc"]
add_constraint [file join $here "video_top.fdc"]
add_constraint [file join $here "video_fb.fdc"]

# ---- video pipeline ----
foreach f [list \
    "video_fb_top.v" "video_clk_reset.v" "video_ip_pll.v" "yolo_pll.v" \
    "video_fb_status.v" "video_hdmi_wrap.v" "video_pattern_gen.v" \
    "video_capture_wrap.v" "video_dvp_rgb565.v" \
    "video_osd.v" "video_font.v" "stereo_cap.v" "stereo_store.v" \
    "video_pip.v" "pip_buf.v" "cam_cap.v" "cam_fifo.v" "cam_store.v" \
    "yolo_stream.v" "det_to_box.v" \
    "legacy/wr_fram_buf.v" "legacy/rd_fram_buf.v" \
    "legacy/ipm2l_sdpram_v1_10_wr_fram_buf.v" \
    "legacy/ipm2l_sdpram_v1_10_rd_fram_buf.v" \
    "legacy/sync_vg.v" "legacy/ms7210_ctl.v" "legacy/iic_dri.v" \
    "legacy/reg_config.v" "legacy/i2c_com.v" "legacy/power_on_delay.v" \
    "legacy/fram_buf.v" "legacy/wr_buf.v" "legacy/rd_buf.v" \
    "legacy/wr_ctrl.v" "legacy/rd_ctrl.v" "legacy/wr_cmd_trans.v" \
    "legacy/wr_rd_ctrl_top.v" ] {
    add_design [file join $root "rtl" "video" $f]
}

# ---- YOLO front end (SystemVerilog) ----
foreach f [list \
    "top_yolo.sv" "layer_data_adapter.sv" "my_fifo.sv" \
    "target/frame_argmax.sv" ] {
    add_design [file join $rtlpds $f]
}
foreach f [list \
    "activation_lut.sv" "d_manager.sv" "extrema_finder.sv" "input_layer.sv" \
    "layer.sv" "max_pool2d.sv" "output_layer.sv" "pe.sv" "pe_col.sv" \
    "pe_page.sv" "post_cv3_conv2d.sv" "sdp_ram.sv" "w_manager.sv" ] {
    add_design [file join $rtlpds "data_process" $f]
}

add_design [file join $here "ip" "ddr3" "ddr3_test" "ddr3_test.idf"]

compile -top_module video_fb_top -system_verilog -include_path [list $rtlpds [file join $rtlpds data_process]]
synthesize -ads
dev_map
pnr -seed 5
report_timing -max_path 20
gen_bit_stream -create_bit true
puts {=== CAM_YOLO_DONE ===}
exit
