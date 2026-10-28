// ---------------------------------------------------------------------------
// video_bist_status - LEDs + 115200 status UART for the DDR3 BIST top
//
// LED map (also documented in fpga/pango/README.md):
//   led[0] heartbeat            led[4] ddr_init_done
//   led[1] system PLL lock      led[5] dbg_ddrphy_init_fail
//   led[2] DDR3 PLL lock        led[6] BIST error (latched)
//   led[3] ddrphy_cpd_lock      led[7] BIST pass (>=1 pass, no error)
//
// UART line, once per ~0.5 s (115200 8N1), fields are hex:
//   BIST I=1 F=0 A=0 G=0 D=1 E=0 P=0000000A C=00000000 X=0000000
//   I ddr_init_done, F init_fail, A align_error, G dbg_error_status,
//   D BIST done, E BIST error, P completed passes, C mismatched beats,
//   X first error word address.
//
// All values are latched when a line starts, so a line is self-consistent
// even if the BIST counters advance while it is being transmitted.
// ---------------------------------------------------------------------------
`include "video_defs.vh"

module video_bist_status (
    input  wire        clk_27m,
    input  wire        rst_sys,

    input  wire        sys_pll_lock,
    input  wire        ddr_pll_lock,
    input  wire        ddr_cpd_lock,
    input  wire        init_done,
    input  wire        init_fail,
    input  wire        align_error,
    input  wire [3:0]  calib_status,
    input  wire        bist_done,
    input  wire        bist_error,
    input  wire [31:0] bist_pass_cnt,
    input  wire [31:0] bist_error_cnt,
    input  wire [27:0] bist_error_addr,
    input  wire [3:0]  bist_error_beat,
    input  wire [31:0] bist_error_expected,
    input  wire [31:0] bist_error_actual,

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
    assign led[1] = sys_pll_lock;
    assign led[2] = ddr_pll_lock;
    assign led[3] = ddr_cpd_lock;
    assign led[4] = init_done;
    assign led[5] = init_fail;
    assign led[6] = bist_error;
    assign led[7] = bist_done & ~bist_error;

    // ------------------------------------------------------------- UART
    localparam [2:0] ST_GAP   = 3'd0;
    localparam [2:0] ST_LOAD  = 3'd1;
    localparam [2:0] ST_START = 3'd2;
    localparam [2:0] ST_DATA  = 3'd3;
    localparam [2:0] ST_STOP  = 3'd4;

    // phase 0 = "BIST " tag, 1..12 = fields, 13 = CR, 14 = LF
    localparam [4:0] PH_CR = 5'd13;
    localparam [4:0] PH_LF = 5'd14;

    reg [2:0]  state;
    reg [15:0] div;
    reg [2:0]  bit_idx;
    reg [9:0]  shifter;
    reg [23:0] gap;
    reg        tx;

    reg [4:0]  phase;
    reg [3:0]  field_idx;
    reg [3:0]  sub;
    reg [2:0]  tag_idx;

    // Latched snapshot for the current line.
    reg        lat_init_done;
    reg        lat_init_fail;
    reg        lat_align;
    reg [3:0]  lat_calib;
    reg        lat_done;
    reg        lat_error;
    reg [31:0] lat_pass;
    reg [31:0] lat_errcnt;
    reg [27:0] lat_erraddr;
    reg [3:0]  lat_errbeat;
    reg [31:0] lat_errexp;
    reg [31:0] lat_erract;

    wire tick = (div == (`VIDEO_UART_DIV - 16'd1));

    /* verilator lint_off UNUSEDSIGNAL */
    function [7:0] hex_ascii;
        input [31:0] v;
        begin
            if (v[3:0] < 4'd10) hex_ascii = 8'h30 + {4'd0, v[3:0]};
            else                hex_ascii = 8'h37 + {4'd0, v[3:0]}; // 'A' - 10
        end
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    // --------------------------------------------------- field descriptors
    reg [7:0]  label0;
    reg [31:0] field_val;
    reg [4:0]  field_len;

    always @(*) begin
        label0    = 8'h49;              // 'I'
        field_val = 32'd0;
        field_len = 5'd1;
        case (field_idx)
            4'd0: begin label0 = 8'h49; field_val = {31'd0, lat_init_done}; end
            4'd1: begin label0 = 8'h46; field_val = {31'd0, lat_init_fail}; end
            4'd2: begin label0 = 8'h41; field_val = {31'd0, lat_align};     end
            4'd3: begin label0 = 8'h47; field_val = {28'd0, lat_calib};     end
            4'd4: begin label0 = 8'h44; field_val = {31'd0, lat_done};      end
            4'd5: begin label0 = 8'h45; field_val = {31'd0, lat_error};     end
            4'd6: begin label0 = 8'h50; field_val = lat_pass;    field_len = 5'd8; end
            4'd7: begin label0 = 8'h43; field_val = lat_errcnt;  field_len = 5'd8; end
            4'd8: begin label0 = 8'h58; field_val = {4'd0, lat_erraddr}; field_len = 5'd7; end
            4'd9: begin label0 = 8'h42; field_val = {28'd0, lat_errbeat}; end
            4'd10: begin label0 = 8'h59; field_val = lat_errexp; field_len = 5'd8; end
            default: begin
                label0    = 8'h5A;      // 'Z'
                field_val = lat_erract;
                field_len = 5'd8;
            end
        endcase
    end

    wire [4:0]  sub5     = {1'b0, sub};
    wire [4:0]  last_sub = field_len + 5'd2;   // label0, '=', digits..., separator
    wire [3:0]  nib_idx  = field_len[3:0] - 4'd1 - (sub - 4'd2);
    wire [5:0]  nib_shift = {nib_idx, 2'b00};

    reg [7:0] msg_byte;
    always @(*) begin
        msg_byte = 8'h20;
        if (phase == 5'd0) begin
            case (tag_idx)
                3'd0:    msg_byte = 8'h42; // B
                3'd1:    msg_byte = 8'h49; // I
                3'd2:    msg_byte = 8'h53; // S
                3'd3:    msg_byte = 8'h54; // T
                default: msg_byte = 8'h20; // ' '
            endcase
        end else if (phase <= 5'd12) begin
            if (sub == 4'd0)                       msg_byte = label0;
            else if (sub == 4'd1)                  msg_byte = 8'h3D; // '='
            else if (sub5 < last_sub)              msg_byte = hex_ascii(field_val >> nib_shift);
            else                                   msg_byte = 8'h20;
        end else if (phase == PH_CR) begin
            msg_byte = 8'h0D;
        end else begin
            msg_byte = 8'h0A;
        end
    end

    always @(posedge clk_27m) begin
        if (rst_sys) begin
            state   <= ST_GAP;
            div     <= 16'd0;
            bit_idx <= 3'd0;
            shifter <= 10'h3FF;
            gap     <= 24'd0;
            tx      <= 1'b1;
            phase   <= 5'd0;
            field_idx <= 4'd0;
            sub     <= 4'd0;
            tag_idx <= 3'd0;
            lat_init_done <= 1'b0;
            lat_init_fail <= 1'b0;
            lat_align     <= 1'b0;
            lat_calib     <= 4'd0;
            lat_done      <= 1'b0;
            lat_error     <= 1'b0;
            lat_pass      <= 32'd0;
            lat_errcnt    <= 32'd0;
            lat_erraddr   <= 28'd0;
            lat_errbeat   <= 4'd0;
            lat_errexp    <= 32'd0;
            lat_erract    <= 32'd0;
        end else begin
            if (tick) div <= 16'd0;
            else      div <= div + 16'd1;

            case (state)
                ST_GAP: begin
                    tx <= 1'b1;
                    if (gap == `VIDEO_UART_PERIOD) begin
                        gap   <= 24'd0;
                        div   <= 16'd0;
                        // Latch one consistent snapshot.
                        lat_init_done <= init_done;
                        lat_init_fail <= init_fail;
                        lat_align     <= align_error;
                        lat_calib     <= calib_status;
                        lat_done      <= bist_done;
                        lat_error     <= bist_error;
                        lat_pass      <= bist_pass_cnt;
                        lat_errcnt    <= bist_error_cnt;
                        lat_erraddr   <= bist_error_addr;
                        lat_errbeat   <= bist_error_beat;
                        lat_errexp    <= bist_error_expected;
                        lat_erract    <= bist_error_actual;
                        phase     <= 5'd0;
                        tag_idx   <= 3'd0;
                        field_idx <= 4'd0;
                        sub       <= 4'd0;
                        state     <= ST_LOAD;
                    end else begin
                        gap <= gap + 24'd1;
                    end
                end

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
                        if (phase == 5'd0) begin
                            if (tag_idx == 3'd4) begin
                                tag_idx   <= 3'd0;
                                field_idx <= 4'd0;
                                sub       <= 4'd0;
                                phase     <= 5'd1;
                            end else begin
                                tag_idx <= tag_idx + 3'd1;
                            end
                            state <= ST_LOAD;
                        end else if (phase <= 5'd12) begin
                            if (sub5 >= last_sub) begin
                                if (field_idx == 4'd11) begin
                                    phase <= PH_CR;
                                end else begin
                                    field_idx <= field_idx + 4'd1;
                                    sub       <= 4'd0;
                                end
                            end else begin
                                sub <= sub + 4'd1;
                            end
                            state <= ST_LOAD;
                        end else if (phase == PH_CR) begin
                            phase <= PH_LF;
                            state <= ST_LOAD;
                        end else begin
                            phase <= 5'd0;
                            gap   <= 24'd0;
                            state <= ST_GAP;
                        end
                    end
                end

                default: state <= ST_GAP;
            endcase
        end
    end

    assign uart_tx = tx;

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
