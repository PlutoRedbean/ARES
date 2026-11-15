//=============================================================================
// ScreenSense - frame-level argmax (B5)
//-----------------------------------------------------------------------------
// The stock post_cv3_conv2d picks the strongest channel *per grid cell* and
// emits one packet per cell.  For the L2 assist we need the single strongest
// detection *per frame*, plus a count of how many cells passed the threshold.
//
// Packet layout (unchanged from post_cv3_conv2d):
//     [31:24] class index   [23:16] cell x   [15:8] cell y   [7:0] confidence
//
// Tie-break: the first packet with the maximum confidence wins (strict '>').
// One frame of latency: the result is latched on frame_done.
//=============================================================================
`timescale 1ns / 1ps

module frame_argmax #(
    parameter [7:0] CONF_THRESH = 8'd0    // 0 = accept everything
) (
    input  wire        clk,
    input  wire        rst_n,

    // from post_cv3_conv2d
    input  wire        in_valid,
    input  wire [31:0] in_packet,
    input  wire        frame_done,

    // to OSD / UART
    output reg         out_valid,        // one-cycle pulse on frame_done
    output reg  [31:0] out_packet,       // strongest detection, same layout
    output reg  [15:0] det_count         // cells that passed CONF_THRESH
);

    reg [7:0]  best_conf;
    reg [31:0] best_pkt;
    reg [15:0] count;

    wire [7:0]  in_conf = in_packet[7:0];
    wire        accept  = in_valid && (in_conf >= CONF_THRESH);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            best_conf <= 8'd0;
            best_pkt  <= 32'd0;
            count     <= 16'd0;
            out_valid <= 1'b0;
            out_packet <= 32'd0;
            det_count  <= 16'd0;
        end else begin
            out_valid <= 1'b0;

            if (accept) begin
                count <= count + 16'd1;
                if (in_conf > best_conf) begin
                    best_conf <= in_conf;
                    best_pkt  <= in_packet;
                end
            end

            if (frame_done) begin
                out_valid  <= (count != 16'd0);
                out_packet <= best_pkt;
                det_count  <= count;
                best_conf  <= 8'd0;
                best_pkt   <= 32'd0;
                count      <= 16'd0;
            end
        end
    end

endmodule
