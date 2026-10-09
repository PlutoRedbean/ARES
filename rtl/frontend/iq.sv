module iq (
    input logic clk,
    input logic rst,

    // ---------- IFU Write Port ----------
    input logic wvalid,
    input fe_pkg::iq_entry_t wdata[fe_pkg::FETCH_WIDTH],
    input logic [fe_pkg::FETCH_WIDTH - 1:0] wmask,  // Fetch Block中Branch后的指令置为无效
    output logic wready,

    // ---------- IDU Read Port ----------
    output logic [fe_pkg::DECODE_WIDTH - 1:0] rvalid,  // HEAD中有效的指令槽
    input logic rready,
    input logic [$clog2(fe_pkg::DECODE_WIDTH+1) - 1:0] raccept_cnt,  // IDU实际消费的指令数
    output fe_pkg::iq_entry_t rbits[fe_pkg::DECODE_WIDTH],

    input logic flush
);
    import fe_pkg::*;

    localparam int unsigned BODY_DEPTH = IQ_DEPTH - DECODE_WIDTH;  // BODY entry 数
    localparam int unsigned BIDX_W = (BODY_DEPTH > 1) ? $clog2(BODY_DEPTH) : 1;
    localparam int unsigned BOFF_W = BIDX_W + 1;  // room for a wrap-around offset
    localparam int unsigned BODY_CNT_W = $clog2(BODY_DEPTH + 1);
    localparam int unsigned WCNT_W = (FETCH_WIDTH > 1) ? $clog2(FETCH_WIDTH + 1) : 1;
    // width used to compare a block size against a free-slot amount; wide enough
    // for both without truncating (the two counts scale with different params)
    localparam int unsigned WCHK_W = (BODY_CNT_W > WCNT_W) ? BODY_CNT_W : WCNT_W;

    // HEAD occupancy FSM (S_H0 = both HEAD and BODY empty)
    typedef enum logic [1:0] {
        S_H0 = 2'd0,  // HEAD empty
        S_H1 = 2'd1,  // HEAD slot0 valid
        S_H2 = 2'd2   // HEAD slot0 + slot1 valid
    } state_t;

    state_t                 head_state;
    state_t                 head_n_state;

    // ---------------- HEAD ----------------
    iq_entry_t              head0_r;
    iq_entry_t              head1_r;
    iq_entry_t              n_head0;
    iq_entry_t              n_head1;

    // ---------------- BODY ----------------
    iq_entry_t              body_mem     [BODY_DEPTH];
    logic      [BIDX_W-1:0] body_wptr;
    logic      [BIDX_W-1:0] body_rptr;

    // Advance a BODY ring pointer by `off`, wrapping at BODY_DEPTH.  `off` is at
    // most BODY_DEPTH (a promote of 2 or a write of up to BODY_DEPTH entries),
    // so a single conditional subtraction wraps it.  Binary pointers keep the
    // pointer cost logarithmic in BODY_DEPTH (and hence in IQ_DEPTH).
    function automatic logic [BIDX_W-1:0] body_add(input logic [BIDX_W-1:0] base,
                                                   input logic [BOFF_W-1:0] off);
        logic [BOFF_W-1:0] sum;
        sum = {1'b0, base} + off;
        body_add = (sum >= BOFF_W'(BODY_DEPTH)) ? BIDX_W'(sum - BOFF_W'(BODY_DEPTH)) : BIDX_W'(sum);
    endfunction

    wire  [BIDX_W-1:0] n_body_rptr = body_add(body_rptr, BOFF_W'(1));
    wire  [BIDX_W-1:0] n2_body_rptr = body_add(body_rptr, BOFF_W'(2));

    // ---------------- read / write control ----------------
    // number of valid entries offered this cycle (contiguous from slot 0)
    logic [WCNT_W-1:0] write_num;
    always_comb begin
        write_num = '0;
        for (int slot = 0; slot < FETCH_WIDTH; slot++) write_num = write_num + WCNT_W'(wmask[slot]);
    end

    logic [1:0] consume;
    // TODO: the specifig behavior of raccpet_cnt is under discusstion.
    // It's not sure whenn raccept_cnt will be changed and how it will be kept
    //in sync with rready.
    assign consume = rready ? 2'(raccept_cnt) : 2'd0;

    // HEAD occupancy left after the IDU consume
    logic [DECODE_WIDTH-1:0] head_after_consume;
    assign head_after_consume = 2'(head_state) - consume;

    // free HEAD slots after the consume
    logic [WCHK_W-1:0] head_room;
    assign head_room = WCHK_W'(DECODE_WIDTH) - WCHK_W'({1'b0, head_after_consume});

    // ---------------- BODY occupancy ----------------
    logic [BODY_CNT_W-1:0] body_occ;
    logic [BODY_CNT_W:0] body_occ_next_full;
    logic [BODY_CNT_W-1:0] body_w_inc;
    logic [BODY_CNT_W-1:0] body_r_dec;
    logic [BODY_CNT_W-1:0] n_body_occ;

    // BODY status derived from the occupancy counter
    logic body_empty;
    assign body_empty = (body_occ == '0);

    logic [BODY_CNT_W-1:0] free_slots;
    assign free_slots = BODY_CNT_W'(BODY_DEPTH) - body_occ;

    // BODY holds at least two entries?
    wire body_has_2_entries = (body_occ >= BODY_CNT_W'(2));

    // promote BODY entries into the HEAD when the HEAD has room; if the IDU
    // consumed two entries, promote two as well
    wire [1:0] push_body2head_num =
        (head_room == '0)                                   ? 2'd0 :
        body_empty                                          ? 2'd0 :
        ((head_room == WCHK_W'(DECODE_WIDTH)) && body_has_2_entries) ? 2'd2 : 2'd1;
    wire push_body2head = (push_body2head_num != 2'd0);
    wire body_r_fire = push_body2head;  // dequeue from BODY into HEAD

    // a BODY->HEAD promotion frees its slots in the same cycle, so the write
    // port may immediately reuse them
    assign body_r_dec = body_r_fire ? BODY_CNT_W'(push_body2head_num) : '0;
    wire [BODY_CNT_W-1:0] free_slots_eff = free_slots + body_r_dec;

    // only when the BODY is empty can the leading entries bypass into the HEAD
    logic [WCNT_W-1:0] head_take;
    assign head_take =
        body_empty ? ((WCHK_W'(write_num) < head_room) ? write_num : WCNT_W'(head_room)) : '0;

    // the remaining entries must go into the BODY
    logic [WCNT_W-1:0] body_take;
    assign body_take = write_num - head_take;

    // accept the whole block when the BODY can hold the remaining entries
    assign wready = (WCHK_W'(body_take) <= WCHK_W'(free_slots_eff));

    wire iq_w_fire = wvalid && wready && (write_num != '0);

    // leading entries written straight into the HEAD, rest into the BODY
    wire [WCNT_W-1:0] head_write_num = iq_w_fire ? head_take : '0;
    wire [WCNT_W-1:0] body_write_num = iq_w_fire ? body_take : '0;

    wire body_w_fire = iq_w_fire && (body_write_num != '0);  // enqueue into BODY

    // BODY occupancy update
    assign body_w_inc = body_w_fire ? BODY_CNT_W'(body_write_num) : '0;
    assign body_occ_next_full = {1'b0, body_occ} + body_w_inc - body_r_dec;
    assign n_body_occ = body_occ_next_full[BODY_CNT_W-1:0];

    wire bypass = (head_write_num != '0);

    // entries appended to the HEAD this cycle
    wire [1:0] head_append_num = push_body2head ? push_body2head_num : 2'(head_write_num);
    iq_entry_t head_append_entry0;
    iq_entry_t head_append_entry1;
    assign head_append_entry0 = bypass ? wdata[0] : body_mem[body_rptr];
    assign head_append_entry1 = bypass ? wdata[1] : body_mem[n_body_rptr];
    wire head_append_valid = (head_append_num != 2'd0);

    // entries shifted into the BODY (skip the ones that bypassed into HEAD)
    iq_entry_t body_wdata[FETCH_WIDTH];
    always_comb begin
        for (int slot = 0; slot < FETCH_WIDTH; slot++) begin
            if (int'(head_write_num) + slot < FETCH_WIDTH)
                body_wdata[slot] = wdata[int'(head_write_num)+slot];
            else body_wdata[slot] = '0;
        end
    end

    // next BODY write pointer (advanced by the number of BODY entries)
    wire [BIDX_W-1:0] n_body_wptr = body_add(body_wptr, BOFF_W'(body_write_num));

    // ---------------- HEAD next head_state ----------------
    always_comb begin
        // shift out the consumed entries
        unique case (consume)
            2'd0: begin
                n_head0 = head0_r;
                n_head1 = head1_r;
            end
            2'd1: begin
                n_head0 = head1_r;
                n_head1 = '0;
            end
            default: begin
                n_head0 = '0;
                n_head1 = '0;
            end
        endcase

        // append the promoted/bypassed entries at position `head_after_consume`
        if (head_append_valid) begin
            unique case (head_append_num)
                2'd1: begin
                    if (head_after_consume == 2'd0) n_head0 = head_append_entry0;
                    else n_head1 = head_append_entry0;
                end
                default: begin
                    n_head0 = head_append_entry0;
                    n_head1 = head_append_entry1;
                end
            endcase
        end
    end

    always_comb begin
        unique case (head_after_consume + head_append_num)
            2'd0: head_n_state = S_H0;
            2'd1: head_n_state = S_H1;
            default: head_n_state = S_H2;
        endcase
    end

    // ---------------- sequential ----------------
    always_ff @(posedge clk) begin
        if (rst) begin
            head0_r   <= '0;
            head1_r   <= '0;
            body_wptr <= '0;
            body_rptr <= '0;
            body_occ  <= '0;
        end else if (flush) begin
            body_wptr <= '0;
            body_rptr <= '0;
            body_occ  <= '0;
        end else begin
            head0_r  <= n_head0;
            head1_r  <= n_head1;
            body_occ <= n_body_occ;



            if (body_w_fire) begin
                for (int slot = 0; slot < FETCH_WIDTH; slot++) begin
                    if (int'(body_write_num) > slot)
                        body_mem[body_add(body_wptr, BOFF_W'(slot))] <= body_wdata[slot];
                end
                body_wptr <= n_body_wptr;
            end

            if (body_r_fire) begin
                body_rptr <= (push_body2head_num == 2'd2) ? n2_body_rptr : n_body_rptr;
            end
        end
    end

    // ---------------- FSM -------------------
    always_ff @(posedge clk) begin
        if (rst) head_state <= S_H0;
        else if (flush) head_state <= S_H0;
        else head_state <= head_n_state;
    end
    // ---------------- outputs ----------------
    assign rvalid[0] = (head_state != S_H0);
    assign rvalid[1] = (head_state == S_H2);
    assign rbits[0]  = head0_r;
    assign rbits[1]  = head1_r;

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        // occupancy must never leave the representable range
        if (body_r_fire && (body_r_dec > body_occ))
            $error("[iq] BODY underflow: body_r_dec=%0d body_occ=%0d", body_r_dec, body_occ);
        if (body_occ_next_full[BODY_CNT_W])
            $error(
                "[iq] BODY overflow: body_occ=%0d w_inc=%0d r_dec=%0d",
                body_occ,
                body_w_inc,
                body_r_dec
            );
    end

    /* verilator lint_off UNUSEDSIGNAL */
    // synthesis-only debug: number of valid entries currently held in the IQ
    // (HEAD 0/1/2 valid slots plus the BODY occupancy)
    localparam int unsigned DBG_OCC_W = $clog2(IQ_DEPTH + 1);
    wire [DBG_OCC_W - 1:0] dbg_occ = DBG_OCC_W'(body_occ) + DBG_OCC_W'(head_state);
    /* verilator lint_on UNUSEDSIGNAL */


    // IDU 保证 raccept_cnt <= popcount(rvalid)
    wire over_consume = rready && (raccept_cnt > $countones(rvalid));
    always_ff @(posedge clk) begin
        if (rst);  // no-op
        else if (over_consume)
            $error("[iq] over-consume: rvalid=%b raccept_cnt=%0d", rvalid, raccept_cnt);
    end
`endif
endmodule
