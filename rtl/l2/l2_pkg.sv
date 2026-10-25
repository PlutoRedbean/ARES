//=============================================================================
// ARES - shared L2 package
//-----------------------------------------------------------------------------
// Bring-up L2 geometry: 64 B lines, 16 B beats, 4 beats per line.  The top
// parameterises the number of sets/ways; 128 sets x 4 ways is 32 KiB per
// instance, 512 sets x 4 ways is 128 KiB.
//=============================================================================
package l2_pkg;
    localparam int unsigned LINE_BYTES = 64;
    localparam int unsigned BEAT_BYTES = 16;
    localparam int unsigned BEATS      = LINE_BYTES / BEAT_BYTES;
    localparam int unsigned OFFSET_W   = $clog2(LINE_BYTES);
    localparam int unsigned BEAT_W     = $clog2(BEATS);
endpackage
