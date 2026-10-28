// ---------------------------------------------------------------------------
// GTP_CLKBUFG behavioral model for Verilator.
//
// The preview top pushes the divided camera pixel clock through a Pango global
// clock buffer (see video_cam_preview_top).  Simulation only needs the buffer
// to pass the clock through.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

module GTP_CLKBUFG (
    input  wire CLKIN,
    output wire CLKOUT
);

    assign CLKOUT = CLKIN;

endmodule
