+incdir+rtl/video

# RTOS AMP + camera -> DDR3 framebuf -> HDMI 720p30
rtl/pipeline/soc/amp/pipeline_amp_video.sv
rtl/pipeline/board/pipeline_rtos_amp_hdmi_board_top.sv

# Video PLL / reset / HDMI / test pattern
rtl/video/video_clk_reset.v
rtl/video/video_ip_pll.v
rtl/video/video_osd_box.v
rtl/video/video_hdmi_wrap.v
rtl/video/video_pattern_gen.v

# Vendor framebuffer and HDMI glue
rtl/video/legacy/fram_buf.v
rtl/video/legacy/wr_buf.v
rtl/video/legacy/rd_buf.v
rtl/video/legacy/wr_ctrl.v
rtl/video/legacy/rd_ctrl.v
rtl/video/legacy/wr_cmd_trans.v
rtl/video/legacy/wr_rd_ctrl_top.v
rtl/video/legacy/wr_fram_buf.v
rtl/video/legacy/rd_fram_buf.v
rtl/video/legacy/ipm2l_sdpram_v1_10_rd_fram_buf.v
rtl/video/legacy/ipm2l_sdpram_v1_10_wr_fram_buf.v
rtl/video/legacy/sync_vg.v
rtl/video/legacy/ms7210_ctl.v
