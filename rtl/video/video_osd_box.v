// ---------------------------------------------------------------------------
// video_osd_box - fixed rectangular OSD guide box.
//
// Combinational overlay for a 16-bit RGB565 pixel stream.  The caller supplies
// the active-pixel coordinates from its timing generator, so the box is
// aligned with the same pixel that is being written to the output register.
// Kept separate from video_hdmi_wrap so the standalone video projects can
// instantiate the wrapper with OSD_BOX=0 and pay no cost.
// ---------------------------------------------------------------------------
module video_osd_box #(
    parameter integer ENABLE = 0,
    parameter [11:0]  X0     = 12'd520,
    parameter [11:0]  Y0     = 12'd254,
    parameter [11:0]  X1     = 12'd760,
    parameter [11:0]  Y1     = 12'd404,
    parameter [11:0]  THICK  = 12'd3,
    parameter [15:0]  COLOR  = 16'h07E0
) (
    input  wire        de,
    input  wire [11:0] x,
    input  wire [11:0] y,
    input  wire [15:0] rgb_in,
    output wire [15:0] rgb_out
);
    wire in_box = (x >= X0) && (x <= X1) && (y >= Y0) && (y <= Y1);
    wire left   = (x >= X0) && (x <  X0 + THICK);
    wire right  = (x <= X1) && (x >  X1 - THICK);
    wire top    = (y >= Y0) && (y <  Y0 + THICK);
    wire bottom = (y <= Y1) && (y >  Y1 - THICK);

    assign rgb_out = (ENABLE != 0 && de && in_box &&
                      (left || right || top || bottom)) ? COLOR : rgb_in;
endmodule
