//=============================================================================
// ScreenSense - detection packet to OSD box
//-----------------------------------------------------------------------------
// Converts the frame argmax result {cls[31:24], x[23:16], y[15:8], conf[7:0]}
// into the 4x48-bit box vector video_osd expects: {x1, y1, x0, y0} per box.
//
// Grid geometry: 80 x 45 cells over a 1280 x 720 frame -> 16 px per cell.
// The drawn box is a fixed 64 x 40 window centred on the cell.
//=============================================================================
`timescale 1ns / 1ps

module det_to_box (
    input  wire         clk,          // clk_pe domain
    input  wire         rst_n,
    input  wire         tgt_valid,
    input  wire [31:0]  tgt_packet,
    output reg  [191:0] boxes,
    output reg          box_tog
);

    localparam integer CELL    = 16;
    localparam integer BOX_W   = 64;
    localparam integer BOX_H   = 40;

    wire [7:0] gx = tgt_packet[23:16];
    wire [7:0] gy = tgt_packet[15:8];

    wire [15:0] cx = gx * CELL + CELL / 2;
    wire [15:0] cy = gy * CELL + CELL / 2;

    wire [11:0] x0c = (cx > BOX_W / 2) ? (cx - BOX_W / 2) : 16'd0;
    wire [11:0] y0c = (cy > BOX_H / 2) ? (cy - BOX_H / 2) : 16'd0;
    wire [11:0] x1c = x0c + BOX_W;
    wire [11:0] y1c = y0c + BOX_H;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            boxes   <= 192'd0;
            box_tog <= 1'b0;
        end else if (tgt_valid) begin
            boxes   <= {48'd0, 48'd0, 48'd0, {x1c, y1c, x0c, y0c}};
            box_tog <= ~box_tog;
        end
    end

endmodule
