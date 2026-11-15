//=============================================================================
// ScreenSense - YOLO stream front end for the camera path
//-----------------------------------------------------------------------------
// Takes a 24-bit RGB pixel stream (camera read-out, 1280x720) and emits the
// frame-level argmax of the plate detector.  This is the same input stage
// hdmi_loop.sv uses, packaged so it can be dropped into video_fb_top.
//
//   pixel domain (clk_pix, 37.125 MHz)  : 2-stage delay -> row marker + RGB FIFO
//   network domain (clk_pe, 74.25 MHz)  : layer_data_adapter -> top_yolo
//                                         -> frame_argmax
//
// clk_pe must be 2x the pixel clock: the adapter consumes one pixel every two
// clk_pe cycles (CYCLE_PERIOD_OUT_LAYER0 / STEP_COL / STEP_ROW = 8/2/2).
//=============================================================================
`timescale 1ns / 1ps

`include "data_process/header/layer0.vh"
`include "data_process/header/layer7.vh"

module yolo_stream #(
    parameter CONF_THRESH = 8'h40,
    parameter integer FIFO_DEPTH = 4096
) (
    // ---- pixel domain ----
    input  wire        pix_clk,
    input  wire        pix_rst_n,
    input  wire        vs,
    input  wire        hs,
    input  wire        de,
    input  wire [23:0] rgb,

    // ---- network domain (2x pixel clock) ----
    input  wire        clk_pe,
    input  wire        pe_rst_n,

    // ---- results (clk_pe domain) ----
    output wire [31:0] tgt_packet,
    output wire        tgt_valid,
    output wire [15:0] det_count
);

    localparam bit CONV_POSITIVE = 1;
    localparam int CONF_WIDTH    = 8;

    // ---------------------------------------------------------------- pixel side
    reg [23:0] rgb_d1, rgb_d2;
    reg        de_d1,  de_d2;

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            rgb_d1 <= 24'd0; rgb_d2 <= 24'd0;
            de_d1  <= 1'b0;  de_d2  <= 1'b0;
        end else begin
            rgb_d1 <= rgb;   rgb_d2 <= rgb_d1;
            de_d1  <= de;    de_d2  <= de_d1;
        end
    end

    reg        fifo_wr;
    reg [31:0] fifo_din;

    always @(posedge pix_clk or negedge pix_rst_n) begin
        if (!pix_rst_n) begin
            fifo_wr  <= 1'b0;
            fifo_din <= 32'd0;
        end else if (de_d1 & ~de_d2) begin
            fifo_wr  <= 1'b1;
            fifo_din <= 32'hFF_00_00_00;          // row marker
        end else if (de_d2) begin
            fifo_wr  <= 1'b1;
            fifo_din <= {8'd0, rgb_d2[7:0], rgb_d2[15:8], rgb_d2[23:16]};
        end else begin
            fifo_wr  <= 1'b0;
        end
    end

    wire        fifo_full, fifo_empty, fifo_rd;
    wire [31:0] fifo_dout;

    my_fifo #(
        .DATA_WIDTH (32),
        .FIFO_DEPTH (FIFO_DEPTH)
    ) u_fifo (
        .rd_clk (clk_pe),
        .wr_clk (pix_clk),
        .rst    (~pix_rst_n),
        .wr_en  (fifo_wr),
        .din    (fifo_din),
        .rd_en  (fifo_rd),
        .dout   (fifo_dout),
        .full   (fifo_full),
        .empty  (fifo_empty)
    );

    // ------------------------------------------------------------- network side
    wire        new_line_1;
    wire [PE_PAGE_NUM_LAYER0-1:0][DATA_WIDTH_LAYER0-1:0] data_to_layer;
    wire        adapter_valid;
    wire [31:0] post_packet_data;
    wire        post_packet_valid;
    wire        post_frame_done;
    wire [PE_COL_NUM_LAYER7-1:0][OUT_WIDTH_LAYER7-1:0] layer_y_out_layer7;
    wire        out_valid_layer7;
    wire        new_line_out_1_layer7;

    layer_data_adapter #(
        .DATA_WIDTH        (DATA_WIDTH_LAYER0),
        .CHANNEL_IN        (PE_PAGE_NUM_LAYER0),
        .CYCLE_PERIOD_OUT  (CYCLE_PERIOD_OUT_LAYER0 / STEP_COL_LAYER0 / STEP_ROW_LAYER0),
        .OUT_WIDTH_POST_33 (32),
        .OUT_WIDTH_LAYER23 (OUT_WIDTH_LAYER7)
    ) u_adapter (
        .clk              (clk_pe),
        .rst_n            (pe_rst_n),
        .usb_fifo_data    (fifo_dout),
        .usb_fifo_empty   (fifo_empty),
        .usb_rd_en        (fifo_rd),
        .new_line_1       (new_line_1),
        .pe_parallel_data (data_to_layer),
        .input_valid      (adapter_valid),
        .packet_data      (post_packet_data),
        .packet_valid     (post_packet_valid),
        .frame_done       (post_frame_done),
        .layer23_data     (layer_y_out_layer7[0]),
        .layer23_valid    (out_valid_layer7),
        .usb_wr_en        (),
        .usb_wr_data      ()
    );

    top_yolo #(
        .LUT_FILE      ("E:/qs/ScreenSense/fpga/rtl_pds/data_process/mem_data/sigmoid_lut_9bit_to_8bit_h.mem"),
        .CONV_POSITIVE (CONV_POSITIVE),
        .CONF_WIDTH    (CONF_WIDTH),
        .CONF_THRESH   (CONF_THRESH)
    ) u_top_yolo (
        .clk                   (clk_pe),
        .clk_en                (1'b1),
        .rst_n                 (pe_rst_n),
        .new_line_input_1      (new_line_1),
        .data_input_valid      (adapter_valid),
        .data_input            (data_to_layer),
        .layer_y_out_layer7    (layer_y_out_layer7),
        .out_valid_layer7      (out_valid_layer7),
        .new_line_out_1_layer7 (new_line_out_1_layer7),
        .post_packet_data      (post_packet_data),
        .post_packet_valid     (post_packet_valid),
        .post_frame_done       (post_frame_done)
    );

    frame_argmax u_argmax (
        .clk        (clk_pe),
        .rst_n      (pe_rst_n),
        .in_valid   (post_packet_valid),
        .in_packet  (post_packet_data),
        .frame_done (post_frame_done),
        .out_valid  (tgt_valid),
        .out_packet (tgt_packet),
        .det_count  (det_count)
    );

endmodule
