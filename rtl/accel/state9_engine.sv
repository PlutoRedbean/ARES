//=============================================================================
// ARES - CoreMark state-machine token scanner
//-----------------------------------------------------------------------------
// Implements the exact core_bench_state() operation:
//
//   scan 1 over memblock (NUL-terminated tokens)
//   corrupt every step-th byte with (ee_u8)seed1, skipping ','
//   scan 2
//   undo every step-th byte with (ee_u8)seed2, skipping ','
//   crc = crcu32(final_counts[i], crc); crc = crcu32(track_counts[i], crc)
//
// The DFA, pointer update, count increments and CRC order are bit-exact with
// CoreMark's core_state_transition()/core_bench_state().  The function is a
// pure function of the block (seed1==seed2 restores the block), so the engine
// keeps a private 1 KiB copy and never writes back to the core's memory.
//
// MMIO window (4 KiB, default 0xA000_2000):
//   0x000..0x3FF  data[0..1023], byte-writable through 32-bit word stores
//   0x700         CTRL      bit0 = start
//   0x704         BLKSIZE   block size (<= 1024)
//   0x708         SEED1     s16
//   0x70C         SEED2     s16
//   0x710         STEP      s16 (1..255)
//   0x714         CRC_IN    u16
//   0x718         STATUS    bit0 = busy, bit1 = done
//   0x71C         CRC_OUT   u16
//   0x720..0x73C  FINAL0..7 u32
//   0x740..0x75C  TRACK0..7 u32
//=============================================================================
module state9_engine (
    input  logic        clk,
    input  logic        rst,

    //---- MMIO host window ---------------------------------------------------
    input  logic        host_req_valid,
    output logic        host_req_ready,
    input  logic        host_write,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] host_addr,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [31:0] host_wdata,
    input  logic [ 3:0] host_wstrb,
    output logic        host_rsp_valid,
    output logic [31:0] host_rsp_data
);

    localparam logic [11:0] CTRL   = 12'h700;
    localparam logic [11:0] BLKSZ  = 12'h704;
    localparam logic [11:0] SEED1  = 12'h708;
    localparam logic [11:0] SEED2  = 12'h70C;
    localparam logic [11:0] STEP   = 12'h710;
    localparam logic [11:0] CRCIN  = 12'h714;
    localparam logic [11:0] STATUS = 12'h718;
    localparam logic [11:0] CRCOUT = 12'h71C;
    localparam logic [11:0] FINAL0 = 12'h720;
    localparam logic [11:0] TRACK0 = 12'h740;

    typedef enum logic [2:0] {
        ST_IDLE,
        ST_SCAN1,
        ST_CORRUPT,
        ST_SCAN2,
        ST_UNDO,
        ST_CRC,
        ST_DONE
    } state_t;

    state_t state_q;

    // 0=START, 1=INVALID, 2=S1, 3=S2, 4=INT, 5=FLOAT, 6=EXPONENT, 7=SCIENTIFIC
    localparam logic [2:0] CORE_START      = 3'd0;
    localparam logic [2:0] CORE_INVALID    = 3'd1;
    localparam logic [2:0] CORE_S1         = 3'd2;
    localparam logic [2:0] CORE_S2         = 3'd3;
    localparam logic [2:0] CORE_INT        = 3'd4;
    localparam logic [2:0] CORE_FLOAT      = 3'd5;
    localparam logic [2:0] CORE_EXPONENT   = 3'd6;
    localparam logic [2:0] CORE_SCIENTIFIC = 3'd7;

    logic [7:0] mem [0:1023];

    logic [31:0] blksz_q;
    logic signed [15:0] seed1_q, seed2_q, step_q;
    logic [15:0] crcin_q;
    logic        busy_q, done_q;
    logic [15:0] crco_q;

    logic [11:0] p_q;
    logic        token_active;
    logic [2:0]  token_state;
    logic        scan_done;
    logic [31:0] final_q [0:7];
    logic [31:0] track_q [0:7];

    logic [11:0] corr_p;
    logic [6:0]  crc_idx;

    //-------------------------------------------------------------------------
    // Host decode
    //-------------------------------------------------------------------------
    wire [11:0] haddr   = host_addr[11:0];
    wire        host_wr = host_req_valid && host_write;
    wire        data_sel = (haddr < 12'h400);

    wire start_pulse = host_wr && (haddr == CTRL) && host_wdata[0] && !busy_q;
    wire [12:0] blk_lim = blksz_q[12:0];

    function automatic logic [31:0] merge_bytes(
        input logic [31:0] old_word,
        input logic [31:0] new_word,
        input logic [ 3:0] be
    );
        logic [31:0] r;
        r = old_word;
        for (int i = 0; i < 4; i++)
            if (be[i]) r[8*i +: 8] = new_word[8*i +: 8];
        return r;
    endfunction

    //-------------------------------------------------------------------------
    // Host read mux
    //-------------------------------------------------------------------------
    logic [31:0] host_rdata;

    always_comb begin
        host_rdata = 32'h0;
        if (data_sel) begin
            host_rdata = {mem[haddr[9:0] + 3], mem[haddr[9:0] + 2],
                          mem[haddr[9:0] + 1], mem[haddr[9:0]]};
        end else begin
            case (haddr)
                CTRL:    host_rdata = {30'b0, done_q, busy_q};
                BLKSZ:   host_rdata = blksz_q;
                SEED1:   host_rdata = {{16{seed1_q[15]}}, seed1_q};
                SEED2:   host_rdata = {{16{seed2_q[15]}}, seed2_q};
                STEP:    host_rdata = {{16{step_q[15]}}, step_q};
                CRCIN:   host_rdata = {16'b0, crcin_q};
                STATUS:  host_rdata = {30'b0, done_q, busy_q};
                CRCOUT:  host_rdata = {16'b0, crco_q};
                FINAL0+12'h00: host_rdata = final_q[0];
                FINAL0+12'h04: host_rdata = final_q[1];
                FINAL0+12'h08: host_rdata = final_q[2];
                FINAL0+12'h0C: host_rdata = final_q[3];
                FINAL0+12'h10: host_rdata = final_q[4];
                FINAL0+12'h14: host_rdata = final_q[5];
                FINAL0+12'h18: host_rdata = final_q[6];
                FINAL0+12'h1C: host_rdata = final_q[7];
                TRACK0+12'h00: host_rdata = track_q[0];
                TRACK0+12'h04: host_rdata = track_q[1];
                TRACK0+12'h08: host_rdata = track_q[2];
                TRACK0+12'h0C: host_rdata = track_q[3];
                TRACK0+12'h10: host_rdata = track_q[4];
                TRACK0+12'h14: host_rdata = track_q[5];
                TRACK0+12'h18: host_rdata = track_q[6];
                TRACK0+12'h1C: host_rdata = track_q[7];
                default: host_rdata = 32'h0;
            endcase
        end
    end

    assign host_req_ready = 1'b1;

    always_ff @(posedge clk) begin
        if (rst) begin
            host_rsp_valid <= 1'b0;
            host_rsp_data  <= 32'h0;
        end else begin
            host_rsp_valid <= host_req_valid;
            host_rsp_data  <= host_wr ? 32'h0 : host_rdata;
        end
    end

    //-------------------------------------------------------------------------
    // Control registers
    //-------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            blksz_q <= 32'd666;
            seed1_q <= 16'sd0;
            seed2_q <= 16'sd0;
            step_q  <= 16'sd0;
            crcin_q <= 16'h0;
        end else if (host_wr && !busy_q) begin
            case (haddr)
                BLKSZ: blksz_q <= host_wdata;
                SEED1: seed1_q <= host_wdata[15:0];
                SEED2: seed2_q <= host_wdata[15:0];
                STEP:  step_q  <= host_wdata[15:0];
                CRCIN: crcin_q <= host_wdata[15:0];
                default: ;
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // Data-array write port: host 4 bytes/cycle, engine 1 byte/cycle
    //-------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (host_wr && !busy_q && data_sel) begin
            for (int i = 0; i < 4; i++)
                if (host_wstrb[i])
                    mem[haddr[9:0] + i[9:0]] <= host_wdata[8*i +: 8];
        end else if ((state_q == ST_CORRUPT || state_q == ST_UNDO) &&
                     ({1'b0, corr_p} < blk_lim)) begin
            if (mem[corr_p[9:0]] != 8'h2C)
                mem[corr_p[9:0]] <= mem[corr_p[9:0]] ^
                    ((state_q == ST_CORRUPT) ? seed1_q[7:0] : seed2_q[7:0]);
        end
    end

    //-------------------------------------------------------------------------
    // DFA next-state / track increments
    //-------------------------------------------------------------------------
    logic [7:0]  cur;
    logic        is_digit, is_pm, is_dot, is_e;
    logic [2:0]  next_state;
    logic [7:0]  track_inc;
    logic        to_invalid;

    always_comb begin
        cur      = mem[p_q[9:0]];
        is_digit = (cur >= 8'h30) && (cur <= 8'h39);
        is_pm    = (cur == 8'h2B) || (cur == 8'h2D);
        is_dot   = (cur == 8'h2E);
        is_e     = (cur == 8'h45) || (cur == 8'h65);

        next_state = token_state;
        track_inc  = 8'h00;
        to_invalid = 1'b0;

        unique case (token_state)
            CORE_START: begin
                track_inc[CORE_START] = 1'b1;
                if (is_digit)      next_state = CORE_INT;
                else if (is_pm)    next_state = CORE_S1;
                else if (is_dot)   next_state = CORE_FLOAT;
                else begin
                    next_state = CORE_INVALID;
                    track_inc[CORE_INVALID] = 1'b1;
                    to_invalid = 1'b1;
                end
            end
            CORE_S1: begin
                track_inc[CORE_S1] = 1'b1;
                if (is_digit)      next_state = CORE_INT;
                else if (is_dot)   next_state = CORE_FLOAT;
                else begin
                    next_state = CORE_INVALID;
                    to_invalid = 1'b1;
                end
            end
            CORE_INT: begin
                if (is_dot) begin
                    next_state = CORE_FLOAT;
                    track_inc[CORE_INT] = 1'b1;
                end else if (!is_digit) begin
                    next_state = CORE_INVALID;
                    track_inc[CORE_INT] = 1'b1;
                    to_invalid = 1'b1;
                end else begin
                    next_state = CORE_INT;
                end
            end
            CORE_FLOAT: begin
                if (is_e) begin
                    next_state = CORE_S2;
                    track_inc[CORE_FLOAT] = 1'b1;
                end else if (!is_digit) begin
                    next_state = CORE_INVALID;
                    track_inc[CORE_FLOAT] = 1'b1;
                    to_invalid = 1'b1;
                end else begin
                    next_state = CORE_FLOAT;
                end
            end
            CORE_S2: begin
                track_inc[CORE_S2] = 1'b1;
                if (is_pm) next_state = CORE_EXPONENT;
                else begin
                    next_state = CORE_INVALID;
                    to_invalid = 1'b1;
                end
            end
            CORE_EXPONENT: begin
                track_inc[CORE_EXPONENT] = 1'b1;
                if (is_digit) next_state = CORE_SCIENTIFIC;
                else begin
                    next_state = CORE_INVALID;
                    to_invalid = 1'b1;
                end
            end
            CORE_SCIENTIFIC: begin
                if (!is_digit) begin
                    next_state = CORE_INVALID;
                    track_inc[CORE_INVALID] = 1'b1;
                    to_invalid = 1'b1;
                end else begin
                    next_state = CORE_SCIENTIFIC;
                end
            end
            default: next_state = CORE_INVALID;
        endcase
    end

    //-------------------------------------------------------------------------
    // CRC8 step
    //-------------------------------------------------------------------------
    function automatic logic [15:0] crc8_step(
        input logic [ 7:0] data,
        input logic [15:0] crc_in
    );
        logic [15:0] c;
        logic [ 7:0] d;
        logic        x16, carry;
        c = crc_in;
        d = data;
        for (int i = 0; i < 8; i++) begin
            x16 = d[0] ^ c[0];
            d   = d >> 1;
            if (x16) begin c = c ^ 16'h4002; carry = 1'b1; end
            else       carry = 1'b0;
            c = c >> 1;
            if (carry) c[15] = 1'b1; else c[15] = 1'b0;
        end
        return c;
    endfunction

    //-------------------------------------------------------------------------
    // CRC pass byte selection
    //-------------------------------------------------------------------------
    logic [3:0]  crc_count_sel;
    logic [2:0]  crc_state_idx;
    logic        crc_is_track;
    logic [1:0]  crc_byte_sel;
    logic [31:0] crc_count;
    logic [7:0]  crc_byte;

    always_comb begin
        // Order: final[0], track[0], final[1], track[1], ...
        crc_count_sel = crc_idx[5:2];
        crc_state_idx = crc_count_sel[3:1];
        crc_is_track  = crc_count_sel[0];
        crc_byte_sel  = crc_idx[1:0];
        if (crc_is_track)
            crc_count = track_q[crc_state_idx];
        else
            crc_count = final_q[crc_state_idx];
        crc_byte = crc_count[8*crc_byte_sel +: 8];
    end

    //-------------------------------------------------------------------------
    // Sequencer
    //-------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q      <= ST_IDLE;
            busy_q       <= 1'b0;
            done_q       <= 1'b0;
            crco_q       <= 16'h0;
            p_q          <= 12'h0;
            token_active <= 1'b0;
            token_state  <= CORE_START;
            scan_done    <= 1'b0;
            corr_p       <= 12'h0;
            crc_idx      <= 7'h0;
            for (int i = 0; i < 8; i++) begin
                final_q[i] <= 32'h0;
                track_q[i] <= 32'h0;
            end
        end else begin
            unique case (state_q)
                ST_IDLE: begin
                    if (start_pulse) begin
                        state_q      <= ST_SCAN1;
                        busy_q       <= 1'b1;
                        done_q       <= 1'b0;
                        crco_q       <= crcin_q;
                        p_q          <= 12'h0;
                        token_active <= 1'b0;
                        token_state  <= CORE_START;
                        scan_done    <= 1'b0;
                        corr_p       <= 12'h0;
                        crc_idx      <= 7'h0;
                        for (int i = 0; i < 8; i++) begin
                            final_q[i] <= 32'h0;
                            track_q[i] <= 32'h0;
                        end
                    end
                end

                ST_SCAN1, ST_SCAN2: begin
                    if (scan_done) begin
                        scan_done <= 1'b0;
                        p_q       <= 12'h0;
                        corr_p    <= 12'h0;
                        if (state_q == ST_SCAN1)
                            state_q <= ST_CORRUPT;
                        else
                            state_q <= ST_UNDO;
                    end else if ({1'b0, p_q} >= blk_lim) begin
                        if (token_active)
                            final_q[token_state] <= final_q[token_state] + 32'd1;
                        token_active <= 1'b0;
                        scan_done    <= 1'b1;
                    end else if (!token_active) begin
                        if (mem[p_q[9:0]] == 8'h00) begin
                            scan_done <= 1'b1;
                        end else begin
                            token_active <= 1'b1;
                            token_state  <= CORE_START;
                        end
                    end else begin
                        if (mem[p_q[9:0]] == 8'h00) begin
                            final_q[token_state] <= final_q[token_state] + 32'd1;
                            token_active <= 1'b0;
                            scan_done    <= 1'b1;
                        end else if (mem[p_q[9:0]] == 8'h2C) begin
                            final_q[token_state] <= final_q[token_state] + 32'd1;
                            token_active <= 1'b0;
                            p_q          <= p_q + 12'd1;
                        end else begin
                            p_q <= p_q + 12'd1;
                            for (int i = 0; i < 8; i++)
                                track_q[i] <= track_q[i] + {31'b0, track_inc[i]};
                            token_state <= next_state;
                            if (to_invalid) begin
                                final_q[CORE_INVALID] <= final_q[CORE_INVALID] + 32'd1;
                                token_active <= 1'b0;
                            end
                        end
                    end
                end

                ST_CORRUPT, ST_UNDO: begin
                    if ({1'b0, corr_p} >= blk_lim) begin
                        corr_p <= 12'h0;
                        if (state_q == ST_CORRUPT) begin
                            state_q <= ST_SCAN2;
                            p_q     <= 12'h0;
                            token_active <= 1'b0;
                            token_state  <= CORE_START;
                            scan_done    <= 1'b0;
                        end else begin
                            state_q <= ST_CRC;
                            crc_idx <= 7'h0;
                        end
                    end else begin
                        corr_p <= corr_p + step_q[11:0];
                    end
                end

                ST_CRC: begin
                    crco_q <= crc8_step(crc_byte, crco_q);
                    if (crc_idx == 7'd63) begin
                        state_q <= ST_DONE;
                    end else begin
                        crc_idx <= crc_idx + 7'd1;
                    end
                end

                ST_DONE: begin
                    busy_q  <= 1'b0;
                    done_q  <= 1'b1;
                    state_q <= ST_IDLE;
                end

                default: state_q <= ST_IDLE;
            endcase
        end
    end

endmodule
