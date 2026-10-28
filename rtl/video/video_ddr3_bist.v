// ---------------------------------------------------------------------------
// video_ddr3_bist - two-phase native-AXI DDR3 write/read pattern test
//
// The Pango 200H DDR3 IP has no rready/bresp; it presents a 256-bit,
// 28-bit-word-address AXI slave with 16-beat INCR bursts.
//
// One pass covers two 4 MiB regions:
//   region 0: word address 0x0000_0000 (low 4 MiB)
//   region 1: word address 0x0040_0000 (byte 16 MiB, framebuffer base)
//
// Phase 1 writes every burst of both regions.  After a drain delay the whole
// range is read back and compared.  Read-after-write over the whole range
// avoids relying on write/read ordering inside the IP for a just-written burst.
//
// Four data patterns rotate every pass:
//   pat 0: {4'd0, word address}   pat 1: ~{4'd0, word address}
//   pat 2: {addr[15:0], ~addr[15:0]}  pat 3: {~addr[15:0], addr[15:0]}
//
// pass_cnt counts completed error-free passes; done is sticky once a full
// pass completed.  error is sticky; on the first mismatch the failing beat,
// its expected/actual low 32 bits and its word address are latched.  The
// current pass still runs to completion to give a meaningful error count.
// The next pass only starts when the previous one was error-free.
// ---------------------------------------------------------------------------
`include "video_defs.vh"

module video_ddr3_bist #(
    parameter [27:0] BIST_WORDS    = 28'h0010_0000, // 1 Mi words = 4 MiB per region
    parameter [27:0] BIST_BASE0    = 28'h0000_0000, // word address
    parameter [27:0] BIST_BASE1    = 28'h0040_0000, // 16 MiB byte offset, word units
    parameter [15:0] DRAIN_WAIT    = 16'd16384,     // ~131 us at 125 MHz
    parameter integer INJECT_FAULT = 0
) (
    input  wire         clk,          // DDR3 core_clk
    input  wire         rst,          // active high, held until ddr_init_done
    input  wire         start,
    output reg          done,         // at least one full pass completed
    output reg          error,        // sticky mismatch
    output reg  [31:0]  pass_cnt,     // completed error-free passes
    output reg  [31:0]  error_cnt,    // mismatched 256-bit beats
    output reg  [27:0]  error_addr,   // first mismatching 32-bit word address
    output reg  [3:0]   error_beat,   // first mismatching beat in the burst
    output reg  [31:0]  error_expected, // expected low 32 bits of that beat
    output reg  [31:0]  error_actual,   // actual low 32 bits of that beat
    output reg  [1:0]   pat_sel,      // current data pattern

    // AXI4 master to I_ips_ddr_top
    output wire [27:0]  axi_awaddr,
    output wire [3:0]   axi_awlen,
    output reg          axi_awvalid,
    input  wire         axi_awready,
    output wire [255:0] axi_wdata,
    output wire [31:0]  axi_wstrb,
    output reg          axi_wvalid,
    input  wire         axi_wready,
    output wire [27:0]  axi_araddr,
    output wire [3:0]   axi_arlen,
    output reg          axi_arvalid,
    input  wire         axi_arready,
    input  wire [255:0] axi_rdata,
    input  wire         axi_rvalid,
    input  wire         axi_rlast
);

    localparam [3:0] S_IDLE    = 4'd0;
    localparam [3:0] S_WR_AW   = 4'd1;
    localparam [3:0] S_WR_W    = 4'd2;
    localparam [3:0] S_WR_NEXT = 4'd3;
    localparam [3:0] S_DRAIN   = 4'd4;
    localparam [3:0] S_RD_AW   = 4'd5;
    localparam [3:0] S_RD_R    = 4'd6;
    localparam [3:0] S_RD_NEXT = 4'd7;
    localparam [3:0] S_PASS    = 4'd8;
    localparam [3:0] S_DONE    = 4'd9;

    reg [3:0]  state;
    reg [27:0] addr;
    reg [3:0]  beat;
    reg [15:0] wait_cnt;
    reg        region;

    wire [27:0] region_base = region ? BIST_BASE1 : BIST_BASE0;
    wire [27:0] region_end  = region_base + BIST_WORDS;

    assign axi_awaddr = addr;
    assign axi_araddr = addr;
    assign axi_awlen  = 4'd15;          // 16 beats
    assign axi_arlen  = 4'd15;
    assign axi_wstrb  = 32'hFFFF_FFFF;

    // ---------------------------------------------------------- patterns
    function [31:0] word_data;
        input [27:0] w;
        input [1:0]  p;
        begin
            case (p)
                2'd0:    word_data = {4'd0, w};
                2'd1:    word_data = ~{4'd0, w};
                2'd2:    word_data = {w[15:0], ~w[15:0]};
                default: word_data = {~w[15:0], w[15:0]};
            endcase
        end
    endfunction

    function [255:0] pat;
        input [27:0] base;
        input [3:0]  b;
        input [1:0]  p;
        reg [27:0] w;
        begin
            w = base + {21'd0, b, 3'b000};
            pat = {
                word_data(w + 28'd7, p), word_data(w + 28'd6, p),
                word_data(w + 28'd5, p), word_data(w + 28'd4, p),
                word_data(w + 28'd3, p), word_data(w + 28'd2, p),
                word_data(w + 28'd1, p), word_data(w + 28'd0, p)
            };
        end
    endfunction

    assign axi_wdata = pat(addr, beat, pat_sel);

    // One deliberate bit flip, for the BIST self-test build.
    wire inject = (INJECT_FAULT != 0) && (region == 1'b0) &&
                  (addr == (region_base + 28'h0000_0100)) &&
                  (beat == 4'd3);
    wire [255:0] expected_data = pat(addr, beat, pat_sel) ^ {255'd0, inject};

    always @(posedge clk) begin
        if (rst) begin
            state          <= S_IDLE;
            addr           <= BIST_BASE0;
            beat           <= 4'd0;
            wait_cnt       <= 16'd0;
            region         <= 1'b0;
            pat_sel        <= 2'd0;
            done           <= 1'b0;
            error          <= 1'b0;
            pass_cnt       <= 32'd0;
            error_cnt      <= 32'd0;
            error_addr     <= 28'd0;
            error_beat     <= 4'd0;
            error_expected <= 32'd0;
            error_actual   <= 32'd0;
            axi_awvalid    <= 1'b0;
            axi_arvalid    <= 1'b0;
            axi_wvalid     <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    done  <= 1'b0;
                    error <= 1'b0;
                    if (start) begin
                        addr     <= BIST_BASE0;
                        region   <= 1'b0;
                        pat_sel  <= 2'd0;
                        beat     <= 4'd0;
                        pass_cnt <= 32'd0;
                        state    <= S_WR_AW;
                    end
                end

                // ------------------------------------------------ write phase
                S_WR_AW: begin
                    axi_awvalid <= 1'b1;
                    if (axi_awvalid && axi_awready) begin
                        axi_awvalid <= 1'b0;
                        beat        <= 4'd0;
                        state       <= S_WR_W;
                    end
                end

                S_WR_W: begin
                    axi_wvalid <= 1'b1;
                    if (axi_wvalid && axi_wready) begin
                        if (beat == 4'd15) begin
                            axi_wvalid <= 1'b0;
                            state      <= S_WR_NEXT;
                        end else begin
                            beat <= beat + 4'd1;
                        end
                    end
                end

                S_WR_NEXT: begin
                    if ((addr + 28'd128) >= region_end) begin
                        if (!region) begin
                            region <= 1'b1;
                            addr   <= BIST_BASE1;
                            beat   <= 4'd0;
                            state  <= S_WR_AW;
                        end else begin
                            region   <= 1'b0;
                            addr     <= BIST_BASE0;
                            beat     <= 4'd0;
                            wait_cnt <= 16'd0;
                            state    <= S_DRAIN;
                        end
                    end else begin
                        addr  <= addr + 28'd128;
                        beat  <= 4'd0;
                        state <= S_WR_AW;
                    end
                end

                // Let the controller commit all writes before reading.
                S_DRAIN: begin
                    if (wait_cnt == DRAIN_WAIT) begin
                        wait_cnt <= 16'd0;
                        state    <= S_RD_AW;
                    end else begin
                        wait_cnt <= wait_cnt + 16'd1;
                    end
                end

                // ------------------------------------------------- read phase
                S_RD_AW: begin
                    axi_arvalid <= 1'b1;
                    if (axi_arvalid && axi_arready) begin
                        axi_arvalid <= 1'b0;
                        beat        <= 4'd0;
                        state       <= S_RD_R;
                    end
                end

                S_RD_R: begin
                    if (axi_rvalid) begin
                        if (axi_rdata !== expected_data) begin
                            if (!error) begin
                                error_addr     <= addr + {21'd0, beat, 3'b000};
                                error_beat     <= beat;
                                error_expected <= expected_data[31:0];
                                error_actual   <= axi_rdata[31:0];
                            end
                            error     <= 1'b1;
                            error_cnt <= error_cnt + 32'd1;
                        end
                        if (axi_rlast || (beat == 4'd15)) begin
                            state <= S_RD_NEXT;
                        end else begin
                            beat <= beat + 4'd1;
                        end
                    end
                end

                S_RD_NEXT: begin
                    if ((addr + 28'd128) >= region_end) begin
                        if (!region) begin
                            region <= 1'b1;
                            addr   <= BIST_BASE1;
                            beat   <= 4'd0;
                            state  <= S_RD_AW;
                        end else begin
                            region <= 1'b0;
                            addr   <= BIST_BASE0;
                            beat   <= 4'd0;
                            state  <= S_PASS;
                        end
                    end else begin
                        addr  <= addr + 28'd128;
                        beat  <= 4'd0;
                        state <= S_RD_AW;
                    end
                end

                S_PASS: begin
                    done <= 1'b1;
                    if (error) begin
                        state <= S_DONE;
                    end else begin
                        // Keep soaking the interface: next pattern, same range.
                        pass_cnt <= pass_cnt + 32'd1;
                        pat_sel  <= pat_sel + 2'd1;
                        addr     <= BIST_BASE0;
                        region   <= 1'b0;
                        wait_cnt <= 16'd0;
                        state    <= S_WR_AW;
                    end
                end

                S_DONE: begin
                    done <= 1'b1;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
