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

    localparam logic [4:0] ST_IDLE      = 5'd0;
    localparam logic [4:0] ST_LOAD_B    = 5'd1;
    localparam logic [4:0] ST_ADD_CONST = 5'd2;
    localparam logic [4:0] ST_MUL_CONST = 5'd3;
    localparam logic [4:0] ST_VECT      = 5'd4;
    localparam logic [4:0] ST_SUM1      = 5'd5;
    localparam logic [4:0] ST_MATMUL    = 5'd6;
    localparam logic [4:0] ST_MATMUL_WR = 5'd7;
    localparam logic [4:0] ST_SUM2      = 5'd8;
    localparam logic [4:0] ST_BITEXT    = 5'd9;
    localparam logic [4:0] ST_BITEXT_WR = 5'd10;
    localparam logic [4:0] ST_SUM3      = 5'd11;
    localparam logic [4:0] ST_RESTORE   = 5'd12;
    localparam logic [4:0] ST_DONE      = 5'd13;
    // One drain cycle after the last element of a row: the MAC is pipelined
    // (product register + accumulate), so the ninth product reaches pe_acc one
    // cycle after the ninth multiply.
    localparam logic [4:0] ST_MATMUL_DR  = 5'd14;
    localparam logic [4:0] ST_BITEXT_DR  = 5'd15;
    // Two CRC cycles at the end of a pass (low byte, high byte).
    localparam logic [4:0] ST_CRC1       = 5'd16;
    localparam logic [4:0] ST_CRC2       = 5'd17;
    // One extra cycle per matrix_sum pass: the A/C array output is registered
    // before the multiply/accumulate stage.  This breaks the RAM -> multiplier
    // -> 32-bit sum -> compare path that limited the SoC to ~108 MHz.
    localparam logic [4:0] ST_MUL_CONST_DR = 5'd18;
    localparam logic [4:0] ST_SUM1_DR      = 5'd19;
    localparam logic [4:0] ST_SUM2_DR      = 5'd20;
    localparam logic [4:0] ST_SUM3_DR      = 5'd21;
    localparam logic [4:0] ST_VECT_DR      = 5'd22;

    logic [4:0] state_q;

    logic [3:0]  n_reg;
    logic signed [15:0] val_reg;
    logic        busy_q;
    logic        done_q;
    logic [15:0] crc_q;
    logic signed [15:0] sum_q [0:3];

    //-------------------------------------------------------------------------
    // Data arrays
    //   A: 81 x 16 used (window 0x000..0x143, one int16 per 32-bit word)
    //   B: 81 x 16 used (window 0x200..0x343)
    //   C: 81 x 32      (window 0x400..0x543)
    //
    // Each array is four 128x8 byte lanes; every lane has one write port and
    // one asynchronous read port, which is the shape Synplify infers
    // distributed RAM from.  The previous form (a 256x32 and an 81x32 register
    // array with three asynchronous read ports) could not be a RAM: PDS built
    // the reads as 81:1 LUT mux trees with a 321-fanout select line and kept
    // the data in flip-flops, which owned the slowest path of the whole SoC
    // (9.5 ns available, 11.0 ns needed at 100 MHz) and 52% of its LUTs.
    //
    // Read port: the engine owns the arrays while busy, the host reads them
    // only when idle.  Host data writes were already ignored while busy, so
    // this matches the existing ownership contract; a host data read while
    // busy now returns zero instead of the engine's data.
    //
    // The arrays are deliberately not reset: distributed RAM has no reset
    // port, and adding one would stop the inference and bring the mux trees
    // back.  C is fully written by the engine before the matrix_sum loops read
    // it, and the host writes A/B before START.
    //-------------------------------------------------------------------------
    // Both spellings are given: the Pango flow synthesises with Synplify
    // (syn_ramstyle) while the rest of this tree uses the Vivado spelling.
    (* ram_style = "distributed", syn_ramstyle = "distributed" *) logic [7:0] a_l0 [0:127];
    (* ram_style = "distributed", syn_ramstyle = "distributed" *) logic [7:0] a_l1 [0:127];
    (* ram_style = "distributed", syn_ramstyle = "distributed" *) logic [7:0] a_l2 [0:127];
    (* ram_style = "distributed", syn_ramstyle = "distributed" *) logic [7:0] a_l3 [0:127];
    (* ram_style = "distributed", syn_ramstyle = "distributed" *) logic [7:0] b_l0 [0:127];
    (* ram_style = "distributed", syn_ramstyle = "distributed" *) logic [7:0] b_l1 [0:127];
    (* ram_style = "distributed", syn_ramstyle = "distributed" *) logic [7:0] b_l2 [0:127];
    (* ram_style = "distributed", syn_ramstyle = "distributed" *) logic [7:0] b_l3 [0:127];
    (* ram_style = "distributed", syn_ramstyle = "distributed" *) logic [7:0] c_l0 [0:127];
    (* ram_style = "distributed", syn_ramstyle = "distributed" *) logic [7:0] c_l1 [0:127];
    (* ram_style = "distributed", syn_ramstyle = "distributed" *) logic [7:0] c_l2 [0:127];
    (* ram_style = "distributed", syn_ramstyle = "distributed" *) logic [7:0] c_l3 [0:127];

    //-------------------------------------------------------------------------
    // Host decode
    //-------------------------------------------------------------------------
    wire [11:0] haddr   = host_addr[11:0];
    wire        host_wr = host_req_valid && host_write;

    wire        a_sel = (haddr < 12'h144);
    wire        b_sel = (haddr >= 12'h200) && (haddr < 12'h344);
    wire        c_sel = (haddr >= 12'h400) && (haddr < 12'h544);

    // Word indices into the 128-entry byte lanes (A/B/C each occupy 0..80).
    // The three windows are 0x000 / 0x200 / 0x400 based, so the word index is
    // haddr[8:2] in every case (b_sel implies haddr[9], i.e. word 128 + n).
    wire [6:0]  a_word  = haddr[8:2];
    wire [6:0]  b_word  = haddr[8:2];
    wire [6:0]  c_word  = haddr[8:2];

    wire start_pulse = host_wr && (haddr == CTRL) && host_wdata[0] && !busy_q;

    integer sum_i;

    //-------------------------------------------------------------------------
    // Array read ports
    //   One asynchronous read port per array.  The engine drives the addresses
    //   below and owns the ports while it runs; the host reads only when idle,
    //   mirroring the write-port ownership.
    //-------------------------------------------------------------------------
    logic [6:0] a_rd_addr;            // registered, see the PE operand pipeline
    logic [6:0] b_rd_addr, c_rd_addr;

    wire [6:0] a_rd_idx = busy_q ? a_rd_addr : a_word;
    wire [6:0] b_rd_idx = busy_q ? b_rd_addr : b_word;
    wire [6:0] c_rd_idx = busy_q ? c_rd_addr : c_word;

    wire [31:0] a_rd_word = {a_l3[a_rd_idx], a_l2[a_rd_idx], a_l1[a_rd_idx], a_l0[a_rd_idx]};
    wire [31:0] b_rd_word = {b_l3[b_rd_idx], b_l2[b_rd_idx], b_l1[b_rd_idx], b_l0[b_rd_idx]};
    wire [31:0] c_rd_word = {c_l3[c_rd_idx], c_l2[c_rd_idx], c_l1[c_rd_idx], c_l0[c_rd_idx]};

    // The engine only ever consumes the low int16 of A and B.
    wire signed [15:0] a_rd_data = a_rd_word[15:0];
    wire signed [15:0] b_rd_data = b_rd_word[15:0];
    wire signed [31:0] c_rd_data = c_rd_word;

    //-------------------------------------------------------------------------
    // Host read mux
    //-------------------------------------------------------------------------
    logic [31:0] host_rdata;

    always_comb begin
        host_rdata = 32'h0;
        // A data read only returns data while the engine is idle: the arrays
        // have a single read port and the engine owns it while busy.
        if (a_sel)
            host_rdata = busy_q ? 32'h0 : a_rd_word;
        else if (b_sel)
            host_rdata = busy_q ? 32'h0 : b_rd_word;
        else if (c_sel)
            host_rdata = busy_q ? 32'h0 : c_rd_word;
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

    logic        a_wr_en;
    logic [6:0]  a_wr_addr;
    logic signed [15:0] a_wr_data;
    logic        c_wr_en;
    logic [6:0]  c_wr_addr;
    logic signed [31:0] c_wr_data;

    // B column cache, one 16-entry row per output column.  The stride is 16 so
    // a PE reads bcol[{row, mk}] - a plain bit concatenation with no adder
    // between the k counter and the RAM address pins.  With the old stride-9
    // layout every PE needed (row*9 + mk) in front of the read port, which put
    // two LUT levels and a fanout-45 counter onto the critical path.
    (* syn_ramstyle = "distributed" *)
    logic signed [15:0] bcol [0:143];
    logic signed [31:0] pe_acc [0:8];
    logic signed [31:0] pe_prod_0, pe_prod_1, pe_prod_2, pe_prod_3, pe_prod_4,
                         pe_prod_5, pe_prod_6, pe_prod_7, pe_prod_8;
    logic signed [31:0] pe_add_0, pe_add_1, pe_add_2, pe_add_3, pe_add_4,
                         pe_add_5, pe_add_6, pe_add_7, pe_add_8;
    // MAC stage 1: registered 16x16 products (see "9 PEs" below).
    logic signed [31:0] pe_prod_q [0:8];
    // Stage 2 qualifier: a product registered in the previous cycle belongs to
    // a real element (and not to the write-back state's held operands).
    logic               mac_valid_q;
    // C write-port stage (see "Array write ports").
    logic               c_wr_en_q;
    logic [6:0]         c_wr_addr_q;
    logic signed [31:0] c_wr_data_q;

    logic signed [31:0] sum_tmp, sum_prev;
    logic signed [31:0] sum_cur_q;
    logic               sum_valid_q;
    logic signed [15:0] v_a_q, v_b_q;
    logic               v_valid_q;
    logic signed [15:0] sum_ret;
    logic signed [31:0] sum_cur, sum_tmp_n, sum_tmp_n2, sum_prev_n;
    logic signed [15:0] sum_ret_n;
    logic signed [15:0] clipval_s16;
    logic signed [31:0] clipval_s32;

    logic signed [31:0] v_acc, v_acc_n, v_prod;
    logic signed [31:0] mul_cur;

    //-------------------------------------------------------------------------
    // Address generation
    //
    // Every engine RAM read address is a flip-flop output.  B and C follow
    // idx directly; A has its own register (a_rd_addr) because the operand
    // pipeline runs one element ahead - see "PE operand pipeline" below.
    //
    // The previous form computed (mi*9 + mk) / (ld_k*9 + ld_j) in two LUT
    // levels and drove them through fanout-45/23/16 nets: that one segment was
    // 5.4 ns (42%) of the 13.0 ns cpu_clk critical path in the Pango report.
    //-------------------------------------------------------------------------
    always_comb begin
        b_rd_addr = idx;
        c_rd_addr = idx;
        a_wr_en   = 1'b0;
        a_wr_addr = idx;
        a_wr_data = 16'sd0;
        c_wr_en   = 1'b0;
        c_wr_addr = idx;
        c_wr_data = 32'sd0;

        unique case (state_q)
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

            ST_VECT_DR: begin
                c_wr_en   = 1'b1;
                c_wr_addr = {3'b000, vi};
                c_wr_data = v_acc_n;
            end

            ST_SUM1, ST_SUM2, ST_SUM3: begin
                c_rd_addr = idx;
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
    // PE operand pipeline
    //
    // Both multiplier operands come from registers, so neither the A read nor
    // the bcol read shares a cycle with the 16x16 multiply, the bit-extract
    // multiply and the 32-bit accumulate.  The read port runs one element
    // ahead - element k+1 is fetched while k is accumulated, and the write-back
    // state fetches element 0 of the next row - so a row still costs 9 cycles
    // and the engine's cycle count is unchanged.
    //
    // Timeline for row i (idx = element index, a_rd_addr = read address):
    //   MATMUL  k=0..8 : a_rd_addr = idx+1 .. idx+9, bcol column = k+1
    //   MATMUL_WR      : a_rd_addr held at (i+1)*9, bcol column 0
    //   last WR cycle  : both advance, so row i+1 sees a[(i+1)*9] x bcol[0]
    // The linear scan states (ADD_CONST / MUL_CONST / VECT / RESTORE) read and
    // write the same index in one cycle, so there a_rd_addr simply mirrors idx.
    //-------------------------------------------------------------------------
    logic [3:0]         pe_k;                 // bcol column being prefetched
    logic signed [15:0] pe_a_q;               // A operand
    logic signed [15:0] pe_b_q [0:8];         // one B column per PE

    always_ff @(posedge clk) begin
        // No reset: ST_IDLE holds both counters at 0 every cycle.
        unique case (state_q)
            ST_ADD_CONST, ST_MUL_CONST, ST_VECT, ST_RESTORE:
                a_rd_addr <= (idx == 7'd80) ? 7'd0 : (a_rd_addr + 7'd1);
            ST_MATMUL, ST_BITEXT:
                // Hold at the row end: this address is (i+1)*9 and has to
                // survive the drain and write-back states as the next row's
                // element 0.
                if (mk != 4'd8) a_rd_addr <= a_rd_addr + 7'd1;
            ST_MATMUL_DR, ST_BITEXT_DR:
                ;                       // hold, like the first write-back cycle
            ST_MATMUL_WR, ST_BITEXT_WR:
                if (wj == 4'd8) a_rd_addr <= a_rd_addr + 7'd1;
            ST_SUM1, ST_SUM2:
                a_rd_addr <= (idx == 7'd80) ? 7'd1 : 7'd0;
            ST_VECT_DR, ST_MUL_CONST_DR, ST_SUM1_DR, ST_SUM2_DR, ST_SUM3_DR:
                ;                       // hold the last pipeline-stage address
            ST_CRC1, ST_CRC2:
                ;                       // hold: the next pass starts on this
            default:
                a_rd_addr <= 7'd0;
        endcase
    end

    always_ff @(posedge clk) begin
        unique case (state_q)
            ST_MATMUL, ST_BITEXT:
                pe_k <= (mk == 4'd8) ? 4'd0 : (pe_k + 4'd1);
            ST_MATMUL_DR, ST_BITEXT_DR:
                pe_k <= 4'd0;           // same column the first write-back cycle holds
            ST_MATMUL_WR, ST_BITEXT_WR:
                pe_k <= (wj == 4'd8) ? 4'd1 : 4'd0;
            ST_SUM1, ST_SUM2:
                pe_k <= (idx == 7'd80) ? 4'd1 : 4'd0;
            ST_MUL_CONST_DR, ST_SUM1_DR, ST_SUM2_DR, ST_SUM3_DR:
                ;                       // hold the last sum-state column
            ST_CRC1, ST_CRC2:
                ;                       // hold, same reason as a_rd_addr
            default:
                pe_k <= 4'd0;
        endcase
    end

    always_ff @(posedge clk) begin
        // No reset: pure payload, rewritten before the first accumulate.
        //
        // Held across the two CRC cycles at the end of a pass: by then the
        // address pipeline has already moved to the next pass's element 1, so
        // loading again would overwrite the element 0 that the first MAC of
        // that pass consumes.
        if (state_q != ST_CRC1 && state_q != ST_CRC2 &&
            state_q != ST_VECT_DR && state_q != ST_MUL_CONST_DR &&
            state_q != ST_SUM1_DR && state_q != ST_SUM2_DR &&
            state_q != ST_SUM3_DR) begin
            pe_a_q    <= a_rd_data;
            pe_b_q[0] <= bcol[{4'd0, pe_k}];
            pe_b_q[1] <= bcol[{4'd1, pe_k}];
            pe_b_q[2] <= bcol[{4'd2, pe_k}];
            pe_b_q[3] <= bcol[{4'd3, pe_k}];
            pe_b_q[4] <= bcol[{4'd4, pe_k}];
            pe_b_q[5] <= bcol[{4'd5, pe_k}];
            pe_b_q[6] <= bcol[{4'd6, pe_k}];
            pe_b_q[7] <= bcol[{4'd7, pe_k}];
            pe_b_q[8] <= bcol[{4'd8, pe_k}];
        end
    end

    //-------------------------------------------------------------------------
    // 9 PEs
    //-------------------------------------------------------------------------
    // Stage 1: register the nine 16x16 products.  The MAC used to be one
    // combinational cone (bcol BRAM output -> 16x16 APM -> bit-extract APM ->
    // 32-bit accumulate, ~6.3 ns of logic at 200 MHz and the only structure
    // left in the fast-corner report), so the product is registered here and
    // the accumulate runs one cycle behind it, qualified by mac_valid_q.
    always_ff @(posedge clk) begin
        // No reset: pure payload, rewritten before the first accumulate.
        pe_prod_q[0] <= $signed(pe_a_q) * $signed(pe_b_q[0]);
        pe_prod_q[1] <= $signed(pe_a_q) * $signed(pe_b_q[1]);
        pe_prod_q[2] <= $signed(pe_a_q) * $signed(pe_b_q[2]);
        pe_prod_q[3] <= $signed(pe_a_q) * $signed(pe_b_q[3]);
        pe_prod_q[4] <= $signed(pe_a_q) * $signed(pe_b_q[4]);
        pe_prod_q[5] <= $signed(pe_a_q) * $signed(pe_b_q[5]);
        pe_prod_q[6] <= $signed(pe_a_q) * $signed(pe_b_q[6]);
        pe_prod_q[7] <= $signed(pe_a_q) * $signed(pe_b_q[7]);
        pe_prod_q[8] <= $signed(pe_a_q) * $signed(pe_b_q[8]);
    end

    // Stage 2 input: bit-extract the registered product in ST_BITEXT (and in
    // its drain cycle), otherwise pass it through.
    always_comb begin
        pe_prod_0 = pe_prod_q[0];
        pe_prod_1 = pe_prod_q[1];
        pe_prod_2 = pe_prod_q[2];
        pe_prod_3 = pe_prod_q[3];
        pe_prod_4 = pe_prod_q[4];
        pe_prod_5 = pe_prod_q[5];
        pe_prod_6 = pe_prod_q[6];
        pe_prod_7 = pe_prod_q[7];
        pe_prod_8 = pe_prod_q[8];
        if (state_q == ST_BITEXT || state_q == ST_BITEXT_DR)
            pe_add_0 = (($signed(pe_prod_0) >>> 2) & 32'sh0000_000F)
                       * (($signed(pe_prod_0) >>> 5) & 32'sh0000_007F);
        else
            pe_add_0 = pe_prod_0;
        if (state_q == ST_BITEXT || state_q == ST_BITEXT_DR)
            pe_add_1 = (($signed(pe_prod_1) >>> 2) & 32'sh0000_000F)
                       * (($signed(pe_prod_1) >>> 5) & 32'sh0000_007F);
        else
            pe_add_1 = pe_prod_1;
        if (state_q == ST_BITEXT || state_q == ST_BITEXT_DR)
            pe_add_2 = (($signed(pe_prod_2) >>> 2) & 32'sh0000_000F)
                       * (($signed(pe_prod_2) >>> 5) & 32'sh0000_007F);
        else
            pe_add_2 = pe_prod_2;
        if (state_q == ST_BITEXT || state_q == ST_BITEXT_DR)
            pe_add_3 = (($signed(pe_prod_3) >>> 2) & 32'sh0000_000F)
                       * (($signed(pe_prod_3) >>> 5) & 32'sh0000_007F);
        else
            pe_add_3 = pe_prod_3;
        if (state_q == ST_BITEXT || state_q == ST_BITEXT_DR)
            pe_add_4 = (($signed(pe_prod_4) >>> 2) & 32'sh0000_000F)
                       * (($signed(pe_prod_4) >>> 5) & 32'sh0000_007F);
        else
            pe_add_4 = pe_prod_4;
        if (state_q == ST_BITEXT || state_q == ST_BITEXT_DR)
            pe_add_5 = (($signed(pe_prod_5) >>> 2) & 32'sh0000_000F)
                       * (($signed(pe_prod_5) >>> 5) & 32'sh0000_007F);
        else
            pe_add_5 = pe_prod_5;
        if (state_q == ST_BITEXT || state_q == ST_BITEXT_DR)
            pe_add_6 = (($signed(pe_prod_6) >>> 2) & 32'sh0000_000F)
                       * (($signed(pe_prod_6) >>> 5) & 32'sh0000_007F);
        else
            pe_add_6 = pe_prod_6;
        if (state_q == ST_BITEXT || state_q == ST_BITEXT_DR)
            pe_add_7 = (($signed(pe_prod_7) >>> 2) & 32'sh0000_000F)
                       * (($signed(pe_prod_7) >>> 5) & 32'sh0000_007F);
        else
            pe_add_7 = pe_prod_7;
        if (state_q == ST_BITEXT || state_q == ST_BITEXT_DR)
            pe_add_8 = (($signed(pe_prod_8) >>> 2) & 32'sh0000_000F)
                       * (($signed(pe_prod_8) >>> 5) & 32'sh0000_007F);
        else
            pe_add_8 = pe_prod_8;
    end

    // Stage 2: accumulate the product registered in the previous cycle.  The
    // qualifier is registered from the multiply state, so the first accumulate
    // of a row lands one cycle after the first multiply and the ninth one in
    // the drain state - the write-back then reads final values.
    always_ff @(posedge clk) begin
        if (rst) mac_valid_q <= 1'b0;
        else     mac_valid_q <= (state_q == ST_MATMUL) || (state_q == ST_BITEXT);
    end

    always_ff @(posedge clk) begin
        // No reset: ST_IDLE clears every accumulator each cycle, so the
        // 9x32 reset loads would be pure duplication on the reset net.
        if (state_q == ST_IDLE) begin
            pe_acc[0] <= 32'sd0;
            pe_acc[1] <= 32'sd0;
            pe_acc[2] <= 32'sd0;
            pe_acc[3] <= 32'sd0;
            pe_acc[4] <= 32'sd0;
            pe_acc[5] <= 32'sd0;
            pe_acc[6] <= 32'sd0;
            pe_acc[7] <= 32'sd0;
            pe_acc[8] <= 32'sd0;
        end else if (mac_valid_q) begin
            pe_acc[0] <= pe_acc[0] + pe_add_0;
            pe_acc[1] <= pe_acc[1] + pe_add_1;
            pe_acc[2] <= pe_acc[2] + pe_add_2;
            pe_acc[3] <= pe_acc[3] + pe_add_3;
            pe_acc[4] <= pe_acc[4] + pe_add_4;
            pe_acc[5] <= pe_acc[5] + pe_add_5;
            pe_acc[6] <= pe_acc[6] + pe_add_6;
            pe_acc[7] <= pe_acc[7] + pe_add_7;
            pe_acc[8] <= pe_acc[8] + pe_add_8;
        end else if ((state_q == ST_MATMUL_WR || state_q == ST_BITEXT_WR)
                     && (wj == 4'd8)) begin
            pe_acc[0] <= 32'sd0;
            pe_acc[1] <= 32'sd0;
            pe_acc[2] <= 32'sd0;
            pe_acc[3] <= 32'sd0;
            pe_acc[4] <= 32'sd0;
            pe_acc[5] <= 32'sd0;
            pe_acc[6] <= 32'sd0;
            pe_acc[7] <= 32'sd0;
            pe_acc[8] <= 32'sd0;
        end
    end

    //-------------------------------------------------------------------------
    // Shared multipliers and matrix_sum recurrence
    //-------------------------------------------------------------------------
    always_comb begin
        mul_cur = $signed(a_rd_data) * $signed(val_reg);
        // ST_VECT multiplies A[vi][vj] by B[vj], and B[j] is exactly
        // bcol[j][0]: ST_LOAD_B already cached the whole B block there, and
        // the host cannot write B while the engine runs.  Reading the cache
        // instead of the B array keeps the vector path off the array's 81:1
        // read mux and leaves B with a single read port.
        v_prod  = $signed(v_a_q) * $signed(v_b_q);
        v_acc_n = v_acc + v_prod;

        clipval_s16 = 16'hF000 | val_reg;
        clipval_s32 = {{16{clipval_s16[15]}}, clipval_s16};

        unique case (state_q)
            ST_MUL_CONST, ST_MUL_CONST_DR:
                sum_cur = $signed(sum_cur_q) * $signed(val_reg);
            ST_SUM1, ST_SUM1_DR, ST_SUM2, ST_SUM2_DR,
            ST_SUM3, ST_SUM3_DR:
                sum_cur = sum_cur_q;
            default:
                sum_cur = c_rd_data;
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

    // Sum-input pipeline register.  The RAM output is captured here so the
    // multiplier / 32-bit accumulate / compare cone starts from a flop instead
    // of from the distributed-RAM output.  ST_*_DR consumes the final element
    // after the last RAM read; the state machine only adds one cycle per pass.
    always_ff @(posedge clk) begin
        if (rst) begin
            sum_cur_q   <= 32'sd0;
            sum_valid_q <= 1'b0;
        end else begin
            if (state_q == ST_MUL_CONST)
                sum_cur_q <= a_rd_data;
            else if (state_q == ST_SUM1 || state_q == ST_SUM2 || state_q == ST_SUM3)
                sum_cur_q <= c_rd_data;

            sum_valid_q <= (state_q == ST_MUL_CONST) ||
                           (state_q == ST_MUL_CONST_DR) ||
                           (state_q == ST_SUM1) ||
                           (state_q == ST_SUM1_DR) ||
                           (state_q == ST_SUM2) ||
                           (state_q == ST_SUM2_DR) ||
                           (state_q == ST_SUM3) ||
                           (state_q == ST_SUM3_DR);
        end
    end

    // Vector path pipeline: capture A and the bcol operand before the
    // multiplier.  ST_VECT_DR consumes the last column (vj=8) after the row's
    // ninth A/bcol read, so each 9-element row costs one extra cycle.
    always_ff @(posedge clk) begin
        if (rst) begin
            v_a_q     <= 16'sd0;
            v_b_q     <= 16'sd0;
            v_valid_q <= 1'b0;
        end else begin
            if (state_q == ST_VECT) begin
                v_a_q <= a_rd_data;
                v_b_q <= bcol[{vj, 4'd0}];
            end
            // The drain state is followed directly by the next VECT row
            // (or by SUM1).  Clear the valid flag when leaving VECT_DR so the
            // first read of the next row is a fill cycle, not a stale product.
            v_valid_q <= (state_q == ST_VECT_DR) ? 1'b0 :
                         (state_q == ST_VECT);
        end
    end

    //-------------------------------------------------------------------------
    // CRC16 recurrence (crcu16: low byte then high byte)
    //
    // The update is one byte per cycle in ST_CRC1/ST_CRC2 instead of a single
    // cone that ran the 32-bit sum, the clipping compare and sixteen CRC
    // rounds in the same cycle (12 logic levels, ~4.5 ns at 200 MHz).  The CRC
    // only changes at the end of a pass, so the extra cycles are four per
    // matrix_test and the sum path keeps only add + compare.
    //-------------------------------------------------------------------------
    reg [15:0] crc_in_q;
    logic [4:0] crc_next_state_q;

    function automatic logic [15:0] crc8_step(
        input logic [15:0] crc_in,
        input logic [ 7:0] data_in
    );
        logic [15:0] w;
        logic [ 7:0] d;
        logic        x;
        integer      i;
        begin
            w = crc_in;
            d = data_in;
            for (i = 0; i < 8; i = i + 1) begin
                x = d[0] ^ w[0];
                d = d >> 1;
                if (x) w = w ^ 16'h4002;
                w    = w >> 1;
                w[15] = x;
            end
            crc8_step = w;
        end
    endfunction

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
            // Common pipeline-stage-2 update: only consume sum_cur_q on the
            // cycle after the corresponding RAM read.  The first cycle of a
            // sum state is the fill cycle and is ignored.
            if (sum_valid_q &&
                (state_q == ST_MUL_CONST || state_q == ST_MUL_CONST_DR ||
                 state_q == ST_SUM1 || state_q == ST_SUM1_DR ||
                 state_q == ST_SUM2 || state_q == ST_SUM2_DR ||
                 state_q == ST_SUM3 || state_q == ST_SUM3_DR)) begin
                sum_tmp  <= sum_tmp_n2;
                sum_prev <= sum_prev_n;
                sum_ret  <= sum_ret_n;
            end

            if (v_valid_q && (state_q == ST_VECT || state_q == ST_VECT_DR))
                v_acc <= v_acc_n;

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
                    bcol[{ld_j, ld_k}] <= b_rd_data;
                    // idx is the B read address; the terminal beat below
                    // overrides the increment and restarts it at 0.
                    idx <= idx + 7'd1;
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
                    if (idx == 7'd80) begin
                        state_q <= ST_MUL_CONST_DR;
                    end else begin
                        idx <= idx + 7'd1;
                    end
                end

                ST_MUL_CONST_DR: begin
                    sum_q[0]         <= sum_ret_n;
                    crc_in_q         <= sum_ret_n;
                    crc_next_state_q <= ST_VECT;
                    state_q          <= ST_CRC1;
                    idx      <= 7'd0;
                    vi       <= 4'd0;
                    vj       <= 4'd0;
                    v_acc    <= 32'sd0;
                end

                ST_VECT: begin
                    idx <= idx + 7'd1;
                    if (vj == 4'd8)
                        state_q <= ST_VECT_DR;
                    else
                        vj <= vj + 4'd1;
                end

                ST_VECT_DR: begin
                    vj    <= 4'd0;
                    v_acc <= 32'sd0;
                    if (vi == 4'd8) begin
                        state_q  <= ST_SUM1;
                        idx      <= 7'd0;
                        sum_tmp  <= 32'sd0;
                        sum_prev <= 32'sd0;
                        sum_ret  <= 16'sd0;
                    end else begin
                        vi      <= vi + 4'd1;
                        state_q <= ST_VECT;
                    end
                end

                ST_SUM1: begin
                    if (idx == 7'd80) begin
                        state_q <= ST_SUM1_DR;
                    end else begin
                        idx <= idx + 7'd1;
                    end
                end

                ST_SUM1_DR: begin
                    sum_q[1]         <= sum_ret_n;
                    crc_in_q         <= sum_ret_n;
                    crc_next_state_q <= ST_MATMUL;
                    state_q          <= ST_CRC1;
                    idx      <= 7'd0;
                    mi       <= 4'd0;
                    mk       <= 4'd0;
                end

                ST_MATMUL: begin
                    // Rows are contiguous (row i+1 starts where row i ended),
                    // so idx walks 0..80 across the whole pass.
                    idx <= idx + 7'd1;
                    if (mk == 4'd8) begin
                        state_q <= ST_MATMUL_DR;
                        mk      <= 4'd0;
                        wj      <= 4'd0;
                    end else begin
                        mk <= mk + 4'd1;
                    end
                end

                ST_MATMUL_DR: begin
                    // Drain: the ninth product lands in pe_acc here.  The
                    // operand pipeline is held exactly like the first
                    // write-back cycle, so row i+1 starts on element 0.
                    state_q <= ST_MATMUL_WR;
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
                    if (idx == 7'd80) begin
                        state_q <= ST_SUM2_DR;
                    end else begin
                        idx <= idx + 7'd1;
                    end
                end

                ST_SUM2_DR: begin
                    sum_q[2]         <= sum_ret_n;
                    crc_in_q         <= sum_ret_n;
                    crc_next_state_q <= ST_BITEXT;
                    state_q          <= ST_CRC1;
                    idx      <= 7'd0;
                    mi       <= 4'd0;
                    mk       <= 4'd0;
                end

                ST_BITEXT: begin
                    idx <= idx + 7'd1;
                    if (mk == 4'd8) begin
                        state_q <= ST_BITEXT_DR;
                        mk      <= 4'd0;
                        wj      <= 4'd0;
                    end else begin
                        mk <= mk + 4'd1;
                    end
                end

                ST_BITEXT_DR: begin
                    state_q <= ST_BITEXT_WR;
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
                    if (idx == 7'd80) begin
                        state_q <= ST_SUM3_DR;
                    end else begin
                        idx <= idx + 7'd1;
                    end
                end

                ST_SUM3_DR: begin
                    sum_q[3]         <= sum_ret_n;
                    crc_in_q         <= sum_ret_n;
                    crc_next_state_q <= ST_RESTORE;
                    state_q          <= ST_CRC1;
                    idx      <= 7'd0;
                end

                ST_RESTORE: begin
                    if (idx == 7'd80) begin
                        state_q <= ST_DONE;
                        idx     <= 7'd0;
                    end else begin
                        idx <= idx + 7'd1;
                    end
                end

                ST_CRC1: begin
                    crc_q <= crc8_step(crc_q, crc_in_q[7:0]);
                    state_q <= ST_CRC2;
                end

                ST_CRC2: begin
                    crc_q   <= crc8_step(crc_q, crc_in_q[15:8]);
                    state_q <= crc_next_state_q;
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
    // Array write ports
    //   A: host byte-strobed word write, or the engine's 16-bit sign-extended
    //      write (ST_ADD_CONST / ST_RESTORE)
    //   B: host byte-strobed word write only; the engine reads it into bcol
    //   C: engine word write, or host word write
    // A host data write is ignored while busy, so the engine and the host
    // never drive a port in the same cycle.
    //-------------------------------------------------------------------------
    wire       a_host_wr = host_wr && !busy_q && a_sel;
    wire       b_host_wr = host_wr && !busy_q && b_sel;
    wire       c_host_wr = host_wr && !busy_q && c_sel;
    wire [6:0] a_wr_idx  = a_host_wr ? a_word : a_wr_addr;

    always_ff @(posedge clk) begin
        if (a_host_wr) begin
            if (host_wstrb[0]) a_l0[a_wr_idx] <= host_wdata[7:0];
            if (host_wstrb[1]) a_l1[a_wr_idx] <= host_wdata[15:8];
            if (host_wstrb[2]) a_l2[a_wr_idx] <= host_wdata[23:16];
            if (host_wstrb[3]) a_l3[a_wr_idx] <= host_wdata[31:24];
        end else if (a_wr_en) begin
            a_l0[a_wr_idx] <= a_wr_data[7:0];
            a_l1[a_wr_idx] <= a_wr_data[15:8];
            a_l2[a_wr_idx] <= {{8{a_wr_data[15]}}};
            a_l3[a_wr_idx] <= {{8{a_wr_data[15]}}};
        end
    end

    always_ff @(posedge clk) begin
        if (b_host_wr) begin
            if (host_wstrb[0]) b_l0[b_word] <= host_wdata[7:0];
            if (host_wstrb[1]) b_l1[b_word] <= host_wdata[15:8];
            if (host_wstrb[2]) b_l2[b_word] <= host_wdata[23:16];
            if (host_wstrb[3]) b_l3[b_word] <= host_wdata[31:24];
        end
    end

    // Engine C write stage.  The write data is a MAC result (the accumulator
    // in the write-back states, the VECT product sum in ST_VECT), so it is
    // registered here before it reaches the array's write port: that keeps the
    // 32-bit adder and the multiplier out of the RAM write path.  It costs one
    // cycle of write latency and no extra cycles - the port still takes one
    // word per cycle, and the engine never reads C until a later state.
    always_ff @(posedge clk) begin
        if (rst) c_wr_en_q <= 1'b0;
        else     c_wr_en_q <= c_wr_en;
        c_wr_addr_q <= c_wr_addr;
        c_wr_data_q <= c_wr_data;
    end

    always_ff @(posedge clk) begin
        if (c_wr_en_q) begin
            c_l0[c_wr_addr_q] <= c_wr_data_q[7:0];
            c_l1[c_wr_addr_q] <= c_wr_data_q[15:8];
            c_l2[c_wr_addr_q] <= c_wr_data_q[23:16];
            c_l3[c_wr_addr_q] <= c_wr_data_q[31:24];
        end else if (c_host_wr) begin
            c_l0[c_word] <= host_wdata[7:0];
            c_l1[c_word] <= host_wdata[15:8];
            c_l2[c_word] <= host_wdata[23:16];
            c_l3[c_word] <= host_wdata[31:24];
        end
    end

`ifdef CONFIG_SIMULATION
    a_start_only_idle: assert property (@(posedge clk) disable iff (rst)
        start_pulse |-> !busy_q);
`endif

endmodule
