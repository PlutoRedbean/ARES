// ---------------------------------------------------------------------------
// board_gesture -- gesture application board top.
//
// One ARES (Mundus) nine-stage core + one miniTensor (ares_soc) plus the OV5640
// capture front end of the gesture application:
//
//   OV5640 DVP 8-bit --video_dvp_rgb565--> pixel_clk/DE/RGB565
//      --cam_cap--> 32x32 thumbnail writes --cam_fifo--> cam_store (BRAM)
//      --cam_addr/cam_bank--> ares_soc window 0xD000_2000
//
// The firmware samples the thumbnail, letterboxes the 13x11 ROI to 32x32,
// quantises it and runs the four-layer INT8 CNN on the accelerator; the class
// goes out on the UART at 10 Hz for the gesture-bridge / Three.js page.
//
// Verilog-2001 on purpose: the SoC itself is SystemVerilog and goes through
// tools/pango_prep.py before PDS.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps
module board_gesture (
    input  wire       clk_27m,      // D18
    input  wire       rst_n,        // C22
    input  wire       uart_rx,      // B24
    output wire       uart_tx,      // C24
    output wire [7:0] led,

    // OV5640 DVP (pinout in fpga/pango/camera_pins.fdc)
    input  wire       cmos1_pclk,
    input  wire       cmos1_vsync,
    input  wire       cmos1_href,
    input  wire [7:0] cmos1_data
);

    // ------------------------------------------------------- clock liveness
    reg [25:0] free_cnt;
    always @(posedge clk_27m) free_cnt <= free_cnt + 26'd1;

    // ---------------------------------------------------------------- reset
    reg [1:0]  rst_sync;
    reg [15:0] por_cnt;
    reg        por_done;

    always @(posedge clk_27m or negedge rst_n) begin
        if (!rst_n) begin
            rst_sync <= 2'b00;
            por_cnt  <= 16'd0;
            por_done <= 1'b0;
        end else begin
            rst_sync <= {rst_sync[0], 1'b1};
            if (!por_done) begin
                if (por_cnt == 16'hFFFF) por_done <= 1'b1;
                else                     por_cnt  <= por_cnt + 16'd1;
            end
        end
    end

    wire rst = ~(rst_sync[1] & por_done);

    // ------------------------------------------------- OV5640 DVP decoding
    wire        pixel_clk, pixel_de, pixel_vsync_raw;
    wire [15:0] pixel_rgb565;

    video_dvp_rgb565 u_dvp (
        .pclk      (cmos1_pclk),
        .rst_n     (rst_n),
        .de_i      (cmos1_href),
        .pdata_i   (cmos1_data),
        .vs_i      (cmos1_vsync),
        .pixel_clk (pixel_clk),
        .de_o      (pixel_de),
        .pdata_o   (pixel_rgb565)
    );

    // VSYNC into the pixel-clock domain.
    reg [1:0] vs_sync;
    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) vs_sync <= 2'b00;
        else        vs_sync <= {vs_sync[0], cmos1_vsync};
    end
    wire pixel_vsync = vs_sync[1];
    wire pixel_rst   = ~rst_n;

    // ------------------------------------------- 32x32 thumbnail + FIFO
    wire        cam_wr_en, cam_tog;
    wire [27:0] cam_wr_word;
    wire [31:0] cam_wr_cnt;
    wire [23:0] cam_dbg_pix;
    wire        cam_fifo_empty, cam_fifo_rd_en;
    wire [27:0] cam_fifo_word;
    wire [10:0] cam_rd_addr;
    wire        cam_rd_bank;
    wire [15:0] cam_rd_data;

    cam_cap u_cam_cap (
        .pixel_clk    (pixel_clk),
        .pixel_rst    (pixel_rst),
        .pixel_de     (pixel_de),
        .pixel_rgb565 (pixel_rgb565),
        .pixel_vsync  (pixel_vsync),
        .wr_en        (cam_wr_en),
        .wr_data      (cam_wr_word),
        .frame_tog    (cam_tog),
        .wr_cnt       (cam_wr_cnt),
        .dbg          (cam_dbg_pix)
    );

    cam_fifo #(
        .WIDTH (28),
        .AW    (5),
        .DEPTH (32)
    ) u_cam_fifo (
        .wr_clk  (pixel_clk),
        .wr_rst  (pixel_rst),
        .wr_en   (cam_wr_en),
        .wr_data (cam_wr_word),
        .full    (),
        .rd_clk  (clk_27m),
        .rd_rst  (rst),
        .rd_en   (cam_fifo_rd_en),
        .rd_data (cam_fifo_word),
        .empty   (cam_fifo_empty)
    );

    cam_store u_cam_store (
        .clk        (clk_27m),
        .rst        (rst),
        .fifo_data  (cam_fifo_word),
        .fifo_empty (cam_fifo_empty),
        .fifo_rd_en (cam_fifo_rd_en),
        .rd_addr    (cam_rd_addr),
        .rd_bank    (cam_rd_bank),
        .rd_data    (cam_rd_data)
    );

    // ------------------------------------ frame counter / status crossings
    // frame_tog is a pixel-domain toggle; count its edges on clk_27m and hand
    // the firmware a 32-bit frame counter, as the capture path did before.
    reg [2:0]  tog_sync;
    reg [31:0] cam_frame_q;
    always @(posedge clk_27m) begin
        if (rst) begin
            tog_sync    <= 3'd0;
            cam_frame_q <= 32'd0;
        end else begin
            tog_sync <= {tog_sync[1:0], cam_tog};
            if (tog_sync[2] != tog_sync[1])
                cam_frame_q <= cam_frame_q + 32'd1;
        end
    end

    reg [31:0] cam_wrcnt_s1, cam_wrcnt_s2;
    reg [23:0] cam_dbg_s1, cam_dbg_s2;
    always @(posedge clk_27m) begin
        if (rst) begin
            cam_wrcnt_s1 <= 32'd0;
            cam_wrcnt_s2 <= 32'd0;
            cam_dbg_s1   <= 24'd0;
            cam_dbg_s2   <= 24'd0;
        end else begin
            cam_wrcnt_s1 <= cam_wr_cnt;
            cam_wrcnt_s2 <= cam_wrcnt_s1;
            cam_dbg_s1   <= cam_dbg_pix;
            cam_dbg_s2   <= cam_dbg_s1;
        end
    end

    // ------------------------------------------------------------------ SoC
    wire        soc_uart_tx;
    wire [31:0] dbg_pc;
    wire        dbg_commit, dbg_halt;

    ares_soc #(
        .ICACHE_SETS       (16),     // 16 x 4 x 32 B = 2 KiB
        .ICACHE_WAYS       (4),
        .ICACHE_LINE_BYTES (32),
        .SCRATCH_WORDS     (4096),
        .ROM_WORDS         (4096),
        .DDR_WORDS         (65536)   // 1 MiB, matches __stack_top = 0x800F_0000
    ) u_soc (
        .clk        (clk_27m),
        .rst        (rst),
        .uart_rx    (uart_rx),
        .uart_tx    (soc_uart_tx),
        .gpio_in    (32'd0),
        .gpio_out   (),
        .gpio_dir   (),
        .cam_addr   (cam_rd_addr),
        .cam_bank   (cam_rd_bank),
        .cam_data   (cam_rd_data),
        .cam_frame  (cam_frame_q),
        .cam_wrcnt  (cam_wrcnt_s2),
        .cam_dbg    (cam_dbg_s2),
        .cam2_addr  (),
        .cam2_data  (16'd0),
        .cam2_frame (32'd0),
        .st_l_addr  (),
        .st_l_data  (8'd0),
        .st_r_addr  (),
        .st_r_data  (8'd0),
        .osd_boxes  (),
        .osd_tog    (),
        .osd_text   (),
        .mt_irq     (),
        .dbg_halt   (dbg_halt),
        .dbg_pc     (dbg_pc),
        .dbg_commit (dbg_commit),
        .dbg_pc_f   (),
        .dbg_ifid_valid  (),
        .dbg_idex_valid  (),
        .dbg_exmem_valid (),
        .dbg_memwb_valid (),
        .dbg_if_pending  ()
    );

    assign uart_tx  = soc_uart_tx;
    assign led[0]   = free_cnt[24];
    assign led[1]   = ~rst;
    assign led[2]   = dbg_commit;
    assign led[3]   = dbg_halt;
    assign led[7:4] = dbg_pc[7:4];

endmodule
