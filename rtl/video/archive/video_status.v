// ---------------------------------------------------------------------------
// video_status - board LEDs + one-way 115200 status UART
//
// S1 line (once per ~0.5 s, bytes back-to-back):
//   S1 V=xxxxxxxx L=xxxxxxxx P=xxxxxxxx\r\n
// V/L/P are the capture vsync / line / pixel counters, snapshotted in the
// pixel-clock domain and synchronized into the 27 MHz status domain.
// ---------------------------------------------------------------------------
`include "video_defs.vh"

module video_status (
    input  wire        clk_27m,
    input  wire        rst_sys,
    input  wire [31:0] status_word,
    input  wire [31:0] status_word2,
    input  wire [31:0] cap_vsync_cnt,
    input  wire [31:0] cap_line_cnt,
    input  wire [31:0] cap_pixel_cnt,
    output wire [7:0]  led,
    output wire        uart_tx
);

    // ------------------------------------------------------------- LEDs
    reg [23:0] beat;
    always @(posedge clk_27m) begin
        if (rst_sys) beat <= 24'd0;
        else         beat <= beat + 24'd1;
    end

    assign led[0] = beat[23];
    assign led[1] = status_word[0];                  // pll_lock
    assign led[2] = status_word[1];                  // ddr_init_done
    assign led[3] = status_word[2];                  // hdmi_init_done
    assign led[4] = status_word[3];                  // cam_init_done
    assign led[5] = status_word[4];                  // capture frame activity
    assign led[6] = status_word[5];                  // frame_drop
    assign led[7] = status_word[6] | status_word[8]; // fifo overflow / bist error

    // ------------------------------------------------------------- UART
    localparam [2:0] ST_GAP   = 3'd0;   // 0.5 s between messages
    localparam [2:0] ST_LOAD  = 3'd1;   // load next byte into shifter
    localparam [2:0] ST_START = 3'd2;
    localparam [2:0] ST_DATA  = 3'd3;
    localparam [2:0] ST_STOP  = 3'd4;

    localparam [5:0] MSG_LAST = 6'd36;  // 37 bytes: "S1 V=... L=... P=...\r\n"

    reg [2:0]  state;
    reg [15:0] div;
    reg [2:0]  bit_idx;
    reg [9:0]  shifter;
    reg [23:0] gap;
    reg [5:0]  msg_idx;
    reg        tx;

    wire tick = (div == (`VIDEO_UART_DIV - 16'd1));

    function [7:0] hex_ascii;
        input [3:0] v;
        begin
            if (v < 4'd10) hex_ascii = 8'h30 + {4'd0, v};
            else           hex_ascii = 8'h37 + {4'd0, v}; // 'A' - 10
        end
    endfunction

    reg [7:0] msg_byte;
    always @(*) begin
        case (msg_idx)
            6'd0:  msg_byte = 8'h53; // S
            6'd1:  msg_byte = 8'h31; // 1
            6'd2:  msg_byte = 8'h20; // ' '
            6'd3:  msg_byte = 8'h56; // V
            6'd4:  msg_byte = 8'h3D; // =
            6'd5:  msg_byte = hex_ascii(cap_vsync_cnt[31:28]);
            6'd6:  msg_byte = hex_ascii(cap_vsync_cnt[27:24]);
            6'd7:  msg_byte = hex_ascii(cap_vsync_cnt[23:20]);
            6'd8:  msg_byte = hex_ascii(cap_vsync_cnt[19:16]);
            6'd9:  msg_byte = hex_ascii(cap_vsync_cnt[15:12]);
            6'd10: msg_byte = hex_ascii(cap_vsync_cnt[11:8]);
            6'd11: msg_byte = hex_ascii(cap_vsync_cnt[7:4]);
            6'd12: msg_byte = hex_ascii(cap_vsync_cnt[3:0]);
            6'd13: msg_byte = 8'h20; // ' '
            6'd14: msg_byte = 8'h4C; // L
            6'd15: msg_byte = 8'h3D; // =
            6'd16: msg_byte = hex_ascii(cap_line_cnt[31:28]);
            6'd17: msg_byte = hex_ascii(cap_line_cnt[27:24]);
            6'd18: msg_byte = hex_ascii(cap_line_cnt[23:20]);
            6'd19: msg_byte = hex_ascii(cap_line_cnt[19:16]);
            6'd20: msg_byte = hex_ascii(cap_line_cnt[15:12]);
            6'd21: msg_byte = hex_ascii(cap_line_cnt[11:8]);
            6'd22: msg_byte = hex_ascii(cap_line_cnt[7:4]);
            6'd23: msg_byte = hex_ascii(cap_line_cnt[3:0]);
            6'd24: msg_byte = 8'h20; // ' '
            6'd25: msg_byte = 8'h50; // P
            6'd26: msg_byte = 8'h3D; // =
            6'd27: msg_byte = hex_ascii(cap_pixel_cnt[31:28]);
            6'd28: msg_byte = hex_ascii(cap_pixel_cnt[27:24]);
            6'd29: msg_byte = hex_ascii(cap_pixel_cnt[23:20]);
            6'd30: msg_byte = hex_ascii(cap_pixel_cnt[19:16]);
            6'd31: msg_byte = hex_ascii(cap_pixel_cnt[15:12]);
            6'd32: msg_byte = hex_ascii(cap_pixel_cnt[11:8]);
            6'd33: msg_byte = hex_ascii(cap_pixel_cnt[7:4]);
            6'd34: msg_byte = hex_ascii(cap_pixel_cnt[3:0]);
            6'd35: msg_byte = 8'h0D; // CR
            default: msg_byte = 8'h0A; // LF
        endcase
    end

    always @(posedge clk_27m) begin
        if (rst_sys) begin
            state   <= ST_GAP;
            div     <= 16'd0;
            bit_idx <= 3'd0;
            shifter <= 10'h3FF;
            gap     <= 24'd0;
            msg_idx <= 6'd0;
            tx      <= 1'b1;
        end else begin
            if (tick) div <= 16'd0;
            else      div <= div + 16'd1;

            case (state)
                // Wait between messages, not between bytes.
                ST_GAP: begin
                    tx <= 1'b1;
                    if (gap == `VIDEO_UART_PERIOD) begin
                        gap      <= 24'd0;
                        msg_idx  <= 6'd0;
                        div      <= 16'd0;
                        state    <= ST_LOAD;
                    end else begin
                        gap <= gap + 24'd1;
                    end
                end

                // One cycle to present the next byte to the shift register.
                ST_LOAD: begin
                    tx      <= 1'b1;
                    shifter <= {1'b1, msg_byte, 1'b0};
                    div     <= 16'd0;
                    state   <= ST_START;
                end

                ST_START: begin
                    if (tick) begin
                        tx      <= shifter[0];        // start bit (0)
                        shifter <= {1'b1, shifter[9:1]};
                        bit_idx <= 3'd0;
                        state   <= ST_DATA;
                    end
                end

                ST_DATA: begin
                    if (tick) begin
                        tx      <= shifter[0];
                        shifter <= {1'b1, shifter[9:1]};
                        if (bit_idx == 3'd7) begin
                            state <= ST_STOP;
                        end else begin
                            bit_idx <= bit_idx + 3'd1;
                        end
                    end
                end

                ST_STOP: begin
                    if (tick) begin
                        tx <= 1'b1;                   // stop bit
                        if (msg_idx == MSG_LAST) begin
                            msg_idx <= 6'd0;
                            gap     <= 24'd0;
                            state   <= ST_GAP;
                        end else begin
                            msg_idx <= msg_idx + 6'd1;
                            state   <= ST_LOAD;
                        end
                    end
                end

                default: state <= ST_GAP;
            endcase
        end
    end

    assign uart_tx = tx;

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, status_word, status_word2};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
