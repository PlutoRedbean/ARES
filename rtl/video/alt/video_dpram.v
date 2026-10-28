// ---------------------------------------------------------------------------
// video_dpram - inferred dual-port RAM replacing the vendor DRM instances
//
// The vendor framebuf chain instantiates wr_fram_buf (32-bit write / 256-bit
// read) and rd_fram_buf (256-bit write / 32-bit read).  Both are built from
// eight 512x32 simple dual-port RAM banks so no DRM IP regeneration is needed.
//
//   write address [2:0] selects the bank, [11:3] selects the 32-bit word
//   read data concatenates bank 7 ... bank 0 (low word = bank 0)
//
// Only the read output register is reset; the RAM arrays must not be reset or
// ADS will not infer block RAM.  Read latency is one clock.
// ---------------------------------------------------------------------------
`include "video_defs.vh"

module wr_fram_buf (
    input  wire [31:0]  wr_data,
    input  wire [11:0]  wr_addr,
    input  wire         wr_en,
    input  wire         wr_clk,
    input  wire         wr_rst,

    input  wire [8:0]   rd_addr,
    output reg  [255:0] rd_data,
    input  wire         rd_clk,
    input  wire         rd_rst
);

    reg [31:0] b0 [0:511];
    reg [31:0] b1 [0:511];
    reg [31:0] b2 [0:511];
    reg [31:0] b3 [0:511];
    reg [31:0] b4 [0:511];
    reg [31:0] b5 [0:511];
    reg [31:0] b6 [0:511];
    reg [31:0] b7 [0:511];

    wire [8:0] wword = wr_addr[11:3];
    wire [2:0] wbank = wr_addr[2:0];

    always @(posedge wr_clk) begin
        if (wr_en) begin
            case (wbank)
                3'd0: b0[wword] <= wr_data;
                3'd1: b1[wword] <= wr_data;
                3'd2: b2[wword] <= wr_data;
                3'd3: b3[wword] <= wr_data;
                3'd4: b4[wword] <= wr_data;
                3'd5: b5[wword] <= wr_data;
                3'd6: b6[wword] <= wr_data;
                default: b7[wword] <= wr_data;
            endcase
        end
    end

    always @(posedge rd_clk) begin
        if (rd_rst) begin
            rd_data <= 256'd0;
        end else begin
            rd_data <= {b7[rd_addr], b6[rd_addr], b5[rd_addr], b4[rd_addr],
                        b3[rd_addr], b2[rd_addr], b1[rd_addr], b0[rd_addr]};
        end
    end

endmodule


module rd_fram_buf (
    input  wire [255:0] wr_data,
    input  wire [8:0]   wr_addr,
    input  wire         wr_en,
    input  wire         wr_clk,
    input  wire         wr_rst,

    input  wire [11:0]  rd_addr,
    output reg  [31:0]  rd_data,
    input  wire         rd_clk,
    input  wire         rd_rst
);

    reg [31:0] b0 [0:511];
    reg [31:0] b1 [0:511];
    reg [31:0] b2 [0:511];
    reg [31:0] b3 [0:511];
    reg [31:0] b4 [0:511];
    reg [31:0] b5 [0:511];
    reg [31:0] b6 [0:511];
    reg [31:0] b7 [0:511];

    always @(posedge wr_clk) begin
        if (wr_en) begin
            b0[wr_addr] <= wr_data[31:0];
            b1[wr_addr] <= wr_data[63:32];
            b2[wr_addr] <= wr_data[95:64];
            b3[wr_addr] <= wr_data[127:96];
            b4[wr_addr] <= wr_data[159:128];
            b5[wr_addr] <= wr_data[191:160];
            b6[wr_addr] <= wr_data[223:192];
            b7[wr_addr] <= wr_data[255:224];
        end
    end

    wire [8:0] rword = rd_addr[11:3];
    wire [2:0] rbank = rd_addr[2:0];

    reg [31:0] rd_mux;
    always @(*) begin
        case (rbank)
            3'd0:    rd_mux = b0[rword];
            3'd1:    rd_mux = b1[rword];
            3'd2:    rd_mux = b2[rword];
            3'd3:    rd_mux = b3[rword];
            3'd4:    rd_mux = b4[rword];
            3'd5:    rd_mux = b5[rword];
            3'd6:    rd_mux = b6[rword];
            default: rd_mux = b7[rword];
        endcase
    end

    always @(posedge rd_clk) begin
        if (rd_rst) rd_data <= 32'd0;
        else        rd_data <= rd_mux;
    end

endmodule
