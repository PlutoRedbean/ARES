//=============================================================================
// ARES - 9-PE INT16 matrix engine for CoreMark matrix_test
//-----------------------------------------------------------------------------
// Implements the exact CoreMark matrix_test() operation for N=9:
//
//   matrix_add_const(A, val)
//   C = A * val                    -> matrix_sum -> crc16
//   C[0..8] = A * B[0..8]          -> matrix_sum (C[9..80] keep the previous
//                                     pass's values, exactly like the C code)
//   C = A * B                      -> matrix_sum -> crc16
//   C = bitextract(A * B)          -> matrix_sum -> crc16
//   matrix_add_const(A, -val)      (restore the engine's A copy)
//
// Host interface (word-addressed 4 KiB MMIO window):
//   0x000..0x143  A[0..80], one signed 16-bit value per 32-bit word
//   0x200..0x343  B[0..80], one signed 16-bit value per 32-bit word
//   0x400..0x543  C[0..80], signed 32-bit result (debug/read-back)
//   0x700         CTRL      bit0 = start (write 1)
//   0x704         N         must be 9 (software falls back otherwise)
//   0x708         VAL       signed 16-bit constant
//   0x70C         STATUS    bit0 = busy, bit1 = done
//   0x710         CRC       matrix_test() return value (signed 16-bit)
//   0x720..0x72C  SUM0..3   the four matrix_sum() results (debug)
//
// The engine is decoupled from the core pipeline: software copies A/B into the
// window, writes START, polls DONE, reads CRC.  matrix_test is a pure function
// of A, B, val (A is restored, B is unchanged, C is unused by CoreMark), so no
// cache maintenance or coherence protocol is required.
//
// Datapath: 9 INT16 multipliers/accumulators (one output column each) for the
// two 9x9x9 matmuls; one shared multiplier for mul_const/mul_vect; one serial
// matrix_sum() unit (the C recurrence is inherently serial).  B columns are
// cached in a 9x9 register file, so a matmul is 9 MAC cycles per row.
//=============================================================================
module mtx9_engine (
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
    localparam logic [11:0] N_REG  = 12'h704;
    localparam logic [11:0] VAL    = 12'h708;
    localparam logic [11:0] STATUS = 12'h70C;
    localparam logic [11:0] CRC    = 12'h710;
    localparam logic [11:0] SUM0   = 12'h720;

    localparam logic [3:0] ST_IDLE      = 4'd0;
    localparam logic [3:0] ST_LOAD_B    = 4'd1;
    localparam logic [3:0] ST_ADD_CONST = 4'd2;
    localparam logic [3:0] ST_MUL_CONST = 4'd3;
    localparam logic [3:0] ST_VECT      = 4'd4;
    localparam logic [3:0] ST_SUM1      = 4'd5;
    localparam logic [3:0] ST_MATMUL    = 4'd6;
    localparam logic [3:0] ST_MATMUL_WR = 4'd7;
    localparam logic [3:0] ST_SUM2      = 4'd8;
    localparam logic [3:0] ST_BITEXT    = 4'd9;
    localparam logic [3:0] ST_BITEXT_WR = 4'd10;
    localparam logic [3:0] ST_SUM3      = 4'd11;
    localparam logic [3:0] ST_RESTORE   = 4'd12;
    localparam logic [3:0] ST_DONE      = 4'd13;

    logic [3:0] state_q;

    logic [3:0]  n_reg;
    logic signed [15:0] val_reg;
    logic        busy_q;
    logic        done_q;
    logic [15:0] crc_q;
    logic signed [15:0] sum_q [0:3];

    // A at abuf[0..80], B at abuf[128..208].
    logic [31:0] abuf [0:255];
    logic signed [31:0] c_mem [0:80];

    //-------------------------------------------------------------------------
    // Host decode
    //-------------------------------------------------------------------------
    wire [11:0] haddr   = host_addr[11:0];
    wire        host_wr = host_req_valid && host_write;

    wire        a_sel = (haddr < 12'h144);
    wire        b_sel = (haddr >= 12'h200) && (haddr < 12'h344);
    wire        c_sel = (haddr >= 12'h400) && (haddr < 12'h544);

    wire [7:0]  a_word  = {1'b0, haddr[8:2]};
    wire [7:0]  b_word  = haddr[9:2] - 8'd128;
    wire [6:0]  c_word  = haddr[8:2];

    wire start_pulse = host_wr && (haddr == CTRL) && host_wdata[0] && !busy_q;

    integer sum_i;
    integer init_i;

    reg [31:0] a_merge;
    reg [31:0] b_merge;
    integer merge_i;

    always @(*) begin
        a_merge = abuf[a_word];
        b_merge = abuf[8'd128 + b_word];
        for (merge_i = 0; merge_i < 4; merge_i = merge_i + 1) begin
            if (host_wstrb[merge_i]) begin
                a_merge[8*merge_i +: 8] = host_wdata[8*merge_i +: 8];
                b_merge[8*merge_i +: 8] = host_wdata[8*merge_i +: 8];
            end
        end
    end

    //-------------------------------------------------------------------------
    // Host read mux
    //-------------------------------------------------------------------------
    logic [31:0] host_rdata;

    always_comb begin
        host_rdata = 32'h0;
        if (a_sel)
            host_rdata = abuf[a_word];
        else if (b_sel)
            host_rdata = abuf[8'd128 + b_word];
        else if (c_sel)
            host_rdata = c_mem[c_word];
        else begin
            case (haddr)
                CTRL:    host_rdata = {30'b0, done_q, busy_q};
                N_REG:   host_rdata = {28'b0, n_reg};
                VAL:     host_rdata = {{16{val_reg[15]}}, val_reg};
                STATUS:  host_rdata = {30'b0, done_q, busy_q};
                CRC:     host_rdata = {16'b0, crc_q};
                SUM0:    host_rdata = {{16{sum_q[0][15]}}, sum_q[0]};
                12'h724: host_rdata = {{16{sum_q[1][15]}}, sum_q[1]};
                12'h728: host_rdata = {{16{sum_q[2][15]}}, sum_q[2]};
                12'h72C: host_rdata = {{16{sum_q[3][15]}}, sum_q[3]};
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
    // Control registers (data storage is written in one block below)
    //-------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            n_reg   <= 4'd9;
            val_reg <= 16'sd0;
        end else if (host_wr && !busy_q) begin
            case (haddr)
                N_REG: n_reg   <= host_wdata[3:0];
                VAL:   val_reg <= host_wdata[15:0];
                default: ;
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // Engine datapath registers / counters
    //-------------------------------------------------------------------------
    logic [3:0] ld_k, ld_j;
    logic [6:0] idx;
    logic [3:0] mi, mk;
    logic [3:0] vi, vj;
    logic [3:0] wj;

    logic [6:0] a_rd_addr, b_rd_addr, c_rd_addr;
    logic        a_wr_en;
    logic [6:0]  a_wr_addr;
    logic signed [15:0] a_wr_data;
    logic        c_wr_en;
    logic [6:0]  c_wr_addr;
    logic signed [31:0] c_wr_data;

    logic signed [15:0] bcol [0:8][0:8];
    logic signed [31:0] pe_acc [0:8];
    logic signed [31:0] pe_prod [0:8];
    logic signed [31:0] pe_add [0:8];

    logic signed [31:0] sum_tmp, sum_prev;
    logic signed [15:0] sum_ret;
    logic signed [31:0] sum_cur, sum_tmp_n, sum_tmp_n2, sum_prev_n;
    logic signed [15:0] sum_ret_n;
    logic signed [15:0] clipval_s16;
    logic signed [31:0] clipval_s32;

    logic signed [31:0] v_acc, v_acc_n, v_prod;
    logic signed [31:0] mul_cur;

    wire signed [15:0] a_rd_data = abuf[{1'b0, a_rd_addr}][15:0];
    wire signed [15:0] b_rd_data = abuf[8'd128 + {1'b0, b_rd_addr}][15:0];
    wire signed [31:0] c_rd_data = c_mem[c_rd_addr];

    //-------------------------------------------------------------------------
    // Address generation
    //-------------------------------------------------------------------------
    always_comb begin
        a_rd_addr = idx;
        b_rd_addr = idx;
        c_rd_addr = idx;
        a_wr_en   = 1'b0;
        a_wr_addr = idx;
        a_wr_data = 16'sd0;
        c_wr_en   = 1'b0;
        c_wr_addr = idx;
        c_wr_data = 32'sd0;

        unique case (state_q)
            ST_LOAD_B: begin
                b_rd_addr = ({3'b000, ld_k} * 7'd9) + {3'b000, ld_j};
            end

            ST_ADD_CONST: begin
                a_wr_en   = 1'b1;
                a_wr_addr = idx;
                a_wr_data = a_rd_data + val_reg;
            end

            ST_MUL_CONST: begin
                c_wr_en   = 1'b1;
                c_wr_addr = idx;
                c_wr_data = mul_cur;
            end

            ST_VECT: begin
                a_rd_addr = ({3'b000, vi} * 7'd9) + {3'b000, vj};
                b_rd_addr = {3'b000, vj};
                if (vj == 4'd8) begin
                    c_wr_en   = 1'b1;
                    c_wr_addr = {3'b000, vi};
                    c_wr_data = v_acc_n;
                end
            end

            ST_SUM1, ST_SUM2, ST_SUM3: begin
                c_rd_addr = idx;
            end

            ST_MATMUL, ST_BITEXT: begin
                a_rd_addr = ({3'b000, mi} * 7'd9) + {3'b000, mk};
            end

            ST_MATMUL_WR, ST_BITEXT_WR: begin
                c_wr_en   = 1'b1;
                c_wr_addr = ({3'b000, mi} * 7'd9) + {3'b000, wj};
                c_wr_data = pe_acc[wj];
            end

            ST_RESTORE: begin
                a_wr_en   = 1'b1;
                a_wr_addr = idx;
                a_wr_data = a_rd_data - val_reg;
            end

            default: ;
        endcase
    end

    //-------------------------------------------------------------------------
    // 9 PEs
    //-------------------------------------------------------------------------
    genvar gj;
    generate
        for (gj = 0; gj < 9; gj++) begin : g_pe
            always_comb begin
                pe_prod[gj] = $signed(a_rd_data) * $signed(bcol[gj][mk]);
                if (state_q == ST_BITEXT) begin
                    pe_add[gj] = (($signed(pe_prod[gj]) >>> 2) & 32'sh0000_000F)
                               * (($signed(pe_prod[gj]) >>> 5) & 32'sh0000_007F);
                end else begin
                    pe_add[gj] = pe_prod[gj];
                end
            end

            always_ff @(posedge clk) begin
                if (rst)
                    pe_acc[gj] <= 32'sd0;
                else if (state_q == ST_IDLE)
                    pe_acc[gj] <= 32'sd0;
                else if (state_q == ST_MATMUL || state_q == ST_BITEXT)
                    pe_acc[gj] <= pe_acc[gj] + pe_add[gj];
                else if ((state_q == ST_MATMUL_WR || state_q == ST_BITEXT_WR)
                         && (wj == 4'd8))
                    pe_acc[gj] <= 32'sd0;
            end
        end
    endgenerate

    //-------------------------------------------------------------------------
    // Shared multipliers and matrix_sum recurrence
    //-------------------------------------------------------------------------
    always_comb begin
        mul_cur = $signed(a_rd_data) * $signed(val_reg);
        v_prod  = $signed(a_rd_data) * $signed(b_rd_data);
        v_acc_n = v_acc + v_prod;

        clipval_s16 = 16'hF000 | val_reg;
        clipval_s32 = {{16{clipval_s16[15]}}, clipval_s16};

        unique case (state_q)
            ST_MUL_CONST: sum_cur = mul_cur;
            default:      sum_cur = c_rd_data;
        endcase

        sum_tmp_n = sum_tmp + sum_cur;
        if (sum_tmp_n > clipval_s32) begin
            sum_ret_n  = sum_ret + 16'sd10;
            sum_tmp_n2 = 32'sd0;
        end else begin
            sum_ret_n  = sum_ret + ((sum_cur > sum_prev) ? 16'sd1 : 16'sd0);
            sum_tmp_n2 = sum_tmp_n;
        end
        sum_prev_n = sum_cur;
    end

    //-------------------------------------------------------------------------
    // CRC16 recurrence (crcu16: low byte then high byte)
    //-------------------------------------------------------------------------
    reg [15:0] crc16_work;
    reg [15:0] crc16_next;
    reg [15:0] crc8_work;
    reg [ 7:0] crc8_data;
    reg        crc8_x16;
    reg        crc8_carry;
    integer crc16_i;
    integer crc8_i;

    always @(*) begin
        crc16_work = crc_q;
        for (crc16_i = 0; crc16_i < 2; crc16_i = crc16_i + 1) begin
            if (crc16_i == 0)
                crc8_data = sum_ret_n[7:0];
            else
                crc8_data = sum_ret_n[15:8];
            crc8_work = crc16_work;
            for (crc8_i = 0; crc8_i < 8; crc8_i = crc8_i + 1) begin
                crc8_x16 = crc8_data[0] ^ crc8_work[0];
                crc8_data = crc8_data >> 1;
                if (crc8_x16) begin
                    crc8_work = crc8_work ^ 16'h4002;
                    crc8_carry = 1'b1;
                end else begin
                    crc8_carry = 1'b0;
                end
                crc8_work = crc8_work >> 1;
                if (crc8_carry) crc8_work[15] = 1'b1;
                else            crc8_work[15] = 1'b0;
            end
            crc16_work = crc8_work;
        end
        crc16_next = crc16_work;
    end

    //-------------------------------------------------------------------------
    // Sequencer
    //-------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            state_q  <= ST_IDLE;
            busy_q   <= 1'b0;
            done_q   <= 1'b0;
            crc_q    <= 16'h0;
            ld_k     <= 4'd0;
            ld_j     <= 4'd0;
            idx      <= 7'd0;
            mi       <= 4'd0;
            mk       <= 4'd0;
            vi       <= 4'd0;
            vj       <= 4'd0;
            wj       <= 4'd0;
            v_acc    <= 32'sd0;
            sum_tmp  <= 32'sd0;
            sum_prev <= 32'sd0;
            sum_ret  <= 16'sd0;
            for (sum_i = 0; sum_i < 4; sum_i = sum_i + 1)
                sum_q[sum_i] <= 16'sd0;
        end else begin
            unique case (state_q)
                ST_IDLE: begin
                    if (start_pulse) begin
                        state_q  <= ST_LOAD_B;
                        busy_q   <= 1'b1;
                        done_q   <= 1'b0;
                        crc_q    <= 16'h0;
                        ld_k     <= 4'd0;
                        ld_j     <= 4'd0;
                        idx      <= 7'd0;
                        mi       <= 4'd0;
                        mk       <= 4'd0;
                        vi       <= 4'd0;
                        vj       <= 4'd0;
                        wj       <= 4'd0;
                        v_acc    <= 32'sd0;
                        sum_tmp  <= 32'sd0;
                        sum_prev <= 32'sd0;
                        sum_ret  <= 16'sd0;
                        for (sum_i = 0; sum_i < 4; sum_i = sum_i + 1)
                            sum_q[sum_i] <= 16'sd0;
                    end
                end

                ST_LOAD_B: begin
                    bcol[ld_j][ld_k] <= b_rd_data;
                    if (ld_j == 4'd8) begin
                        ld_j <= 4'd0;
                        if (ld_k == 4'd8) begin
                            state_q <= ST_ADD_CONST;
                            ld_k    <= 4'd0;
                            idx     <= 7'd0;
                        end else begin
                            ld_k <= ld_k + 4'd1;
                        end
                    end else begin
                        ld_j <= ld_j + 4'd1;
                    end
                end

                ST_ADD_CONST: begin
                    if (idx == 7'd80) begin
                        state_q  <= ST_MUL_CONST;
                        idx      <= 7'd0;
                        sum_tmp  <= 32'sd0;
                        sum_prev <= 32'sd0;
                        sum_ret  <= 16'sd0;
                    end else begin
                        idx <= idx + 7'd1;
                    end
                end

                ST_MUL_CONST: begin
                    sum_tmp  <= sum_tmp_n2;
                    sum_prev <= sum_prev_n;
                    sum_ret  <= sum_ret_n;
                    if (idx == 7'd80) begin
                        sum_q[0] <= sum_ret_n;
                        crc_q    <= crc16_next;
                        state_q  <= ST_VECT;
                        idx      <= 7'd0;
                        vi       <= 4'd0;
                        vj       <= 4'd0;
                        v_acc    <= 32'sd0;
                    end else begin
                        idx <= idx + 7'd1;
                    end
                end

                ST_VECT: begin
                    if (vj == 4'd8) begin
                        vj    <= 4'd0;
                        v_acc <= 32'sd0;
                        if (vi == 4'd8) begin
                            state_q  <= ST_SUM1;
                            idx      <= 7'd0;
                            sum_tmp  <= 32'sd0;
                            sum_prev <= 32'sd0;
                            sum_ret  <= 16'sd0;
                        end else begin
                            vi <= vi + 4'd1;
                        end
                    end else begin
                        v_acc <= v_acc_n;
                        vj    <= vj + 4'd1;
                    end
                end

                ST_SUM1: begin
                    sum_tmp  <= sum_tmp_n2;
                    sum_prev <= sum_prev_n;
                    sum_ret  <= sum_ret_n;
                    if (idx == 7'd80) begin
                        sum_q[1] <= sum_ret_n;
                        crc_q    <= crc16_next;
                        state_q  <= ST_MATMUL;
                        idx      <= 7'd0;
                        mi       <= 4'd0;
                        mk       <= 4'd0;
                    end else begin
                        idx <= idx + 7'd1;
                    end
                end

                ST_MATMUL: begin
                    if (mk == 4'd8) begin
                        state_q <= ST_MATMUL_WR;
                        mk      <= 4'd0;
                        wj      <= 4'd0;
                    end else begin
                        mk <= mk + 4'd1;
                    end
                end

                ST_MATMUL_WR: begin
                    if (wj == 4'd8) begin
                        wj <= 4'd0;
                        if (mi == 4'd8) begin
                            state_q  <= ST_SUM2;
                            idx      <= 7'd0;
                            sum_tmp  <= 32'sd0;
                            sum_prev <= 32'sd0;
                            sum_ret  <= 16'sd0;
                        end else begin
                            mi      <= mi + 4'd1;
                            state_q <= ST_MATMUL;
                        end
                    end else begin
                        wj <= wj + 4'd1;
                    end
                end

                ST_SUM2: begin
                    sum_tmp  <= sum_tmp_n2;
                    sum_prev <= sum_prev_n;
                    sum_ret  <= sum_ret_n;
                    if (idx == 7'd80) begin
                        sum_q[2] <= sum_ret_n;
                        crc_q    <= crc16_next;
                        state_q  <= ST_BITEXT;
                        idx      <= 7'd0;
                        mi       <= 4'd0;
                        mk       <= 4'd0;
                    end else begin
                        idx <= idx + 7'd1;
                    end
                end

                ST_BITEXT: begin
                    if (mk == 4'd8) begin
                        state_q <= ST_BITEXT_WR;
                        mk      <= 4'd0;
                        wj      <= 4'd0;
                    end else begin
                        mk <= mk + 4'd1;
                    end
                end

                ST_BITEXT_WR: begin
                    if (wj == 4'd8) begin
                        wj <= 4'd0;
                        if (mi == 4'd8) begin
                            state_q  <= ST_SUM3;
                            idx      <= 7'd0;
                            sum_tmp  <= 32'sd0;
                            sum_prev <= 32'sd0;
                            sum_ret  <= 16'sd0;
                        end else begin
                            mi      <= mi + 4'd1;
                            state_q <= ST_BITEXT;
                        end
                    end else begin
                        wj <= wj + 4'd1;
                    end
                end

                ST_SUM3: begin
                    sum_tmp  <= sum_tmp_n2;
                    sum_prev <= sum_prev_n;
                    sum_ret  <= sum_ret_n;
                    if (idx == 7'd80) begin
                        sum_q[3] <= sum_ret_n;
                        crc_q    <= crc16_next;
                        state_q  <= ST_RESTORE;
                        idx      <= 7'd0;
                    end else begin
                        idx <= idx + 7'd1;
                    end
                end

                ST_RESTORE: begin
                    if (idx == 7'd80) begin
                        state_q <= ST_DONE;
                        idx     <= 7'd0;
                    end else begin
                        idx <= idx + 7'd1;
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

    //-------------------------------------------------------------------------
    // Single write block for the data arrays
    //-------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            for (init_i = 0; init_i < 256; init_i = init_i + 1)
                abuf[init_i] <= 32'h0;
            for (init_i = 0; init_i < 81; init_i = init_i + 1)
                c_mem[init_i] <= 32'sd0;
        end else begin
            if (host_wr && !busy_q && a_sel)
                abuf[a_word] <= a_merge;
            else if (a_wr_en)
                abuf[{1'b0, a_wr_addr}] <= {{16{a_wr_data[15]}}, a_wr_data};

            if (host_wr && !busy_q && b_sel)
                abuf[8'd128 + b_word] <= b_merge;

            if (c_wr_en)
                c_mem[c_wr_addr] <= c_wr_data;
            else if (host_wr && !busy_q && c_sel)
                c_mem[c_word] <= $signed(host_wdata);
        end
    end

`ifdef CONFIG_SIMULATION
    a_start_only_idle: assert property (@(posedge clk) disable iff (rst)
        start_pulse |-> !busy_q);
`endif

endmodule
