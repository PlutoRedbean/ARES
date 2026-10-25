//=============================================================================
// ARES SoC - minimal PLIC (32 sources, NUM_CONTEXTS machine contexts)
//-----------------------------------------------------------------------------
// Standard PLIC layout:
//   0x0000 + 4*source       : priority (source 0 reserved, reads 0)
//   0x1000                  : pending (read-only)
//   0x2000 + 0x80*ctx       : enable word for context ctx
//   0x200000 + 0x1000*ctx   : threshold for context ctx
//   0x200004 + 0x1000*ctx   : claim/complete for context ctx
//
// Sources are level-sensitive.  A source is forwarded once, held in service
// after a claim, and can be forwarded again only after completion (or after it
// deasserts and reasserts).  Priority 0 means "never interrupt".  Claim picks
// the highest priority enabled pending source; ties go to the lowest source ID.
//=============================================================================
module soc_plic #(
    parameter int unsigned NUM_CONTEXTS = 2
) (
    input  logic                    clk,
    input  logic                    rst,

    // Level-sensitive interrupt sources; bit 0 is reserved.
    input  logic [31:0]             src,

    // 32-bit MMIO request/response (single outstanding)
    input  logic                    req_valid,
    output logic                    req_ready,
    input  logic                    req_write,
    input  logic [31:0]             req_addr,
    input  logic [31:0]             req_wdata,
    input  logic [3:0]              req_wstrb,
    output logic                    rsp_valid,
    input  logic                    rsp_ready,
    output logic [31:0]             rsp_data,

    // Per-context external interrupt (MEIP)
    output logic [NUM_CONTEXTS-1:0] irq_out
);
    localparam logic [31:0] PENDING_ADDR = 32'h0000_1000;
    // Two-context target: keep the addresses explicit so the decode has no
    // variable-width address arithmetic.
    localparam logic [31:0] ENABLE_ADDR [NUM_CONTEXTS]    = '{32'h0000_2000, 32'h0000_2080};
    localparam logic [31:0] THRESHOLD_ADDR [NUM_CONTEXTS] = '{32'h0020_0000, 32'h0020_1000};
    localparam logic [31:0] CLAIM_ADDR [NUM_CONTEXTS]     = '{32'h0020_0004, 32'h0020_1004};

    logic [31:0] priority_q [32];
    logic [31:0] pending_q;
    logic [31:0] in_service_q;
    logic [31:0] enable_q [NUM_CONTEXTS];
    logic [31:0] threshold_q [NUM_CONTEXTS];

    logic        rsp_valid_q;
    logic [31:0] rsp_data_q;

    //-------------------------------------------------------------------------
    // Address decode
    //-------------------------------------------------------------------------
    logic             hit_priority, hit_pending, hit_enable, hit_threshold, hit_claim;
    logic [4:0]       priority_idx;
    logic             enable_ctx, threshold_ctx, claim_ctx;
    logic [31:0]      rd_data;

    always_comb begin
        hit_priority  = 1'b0;
        hit_pending   = 1'b0;
        hit_enable    = 1'b0;
        hit_threshold = 1'b0;
        hit_claim     = 1'b0;
        priority_idx  = 5'd0;
        enable_ctx    = '0;
        threshold_ctx = '0;
        claim_ctx     = '0;

        if (req_addr < 32'h0000_1000) begin
            priority_idx = req_addr[6:2];
            hit_priority = (req_addr[1:0] == 2'b00);
        end
        if (req_addr == PENDING_ADDR) hit_pending = 1'b1;

        for (int c = 0; c < NUM_CONTEXTS; c++) begin
            if (req_addr == ENABLE_ADDR[c]) begin
                hit_enable = 1'b1;
                enable_ctx = c[0];
            end
            if (req_addr == THRESHOLD_ADDR[c]) begin
                hit_threshold = 1'b1;
                threshold_ctx = c[0];
            end
            if (req_addr == CLAIM_ADDR[c]) begin
                hit_claim = 1'b1;
                claim_ctx = c[0];
            end
        end
    end

    //-------------------------------------------------------------------------
    // Claim arbitration for the context selected by the current address
    //-------------------------------------------------------------------------
    logic [4:0]  claim_id;
    logic [31:0] claim_best_prio;

    always_comb begin
        claim_id        = 5'd0;
        claim_best_prio = 32'd0;
        for (int s = 1; s < 32; s++) begin
            if (pending_q[s]
                && enable_q[claim_ctx][s]
                && (priority_q[s] != 32'd0)
                && (priority_q[s] > threshold_q[claim_ctx])
                && (priority_q[s] > claim_best_prio)) begin
                claim_id        = 5'(s);
                claim_best_prio = priority_q[s];
            end
        end
    end

    //-------------------------------------------------------------------------
    // Read mux (claim read returns claim_id, not a register)
    //-------------------------------------------------------------------------
    always_comb begin
        rd_data = 32'h0;
        if (hit_priority && (priority_idx != 5'd0)) rd_data = priority_q[priority_idx];
        else if (hit_pending) rd_data = pending_q;
        else if (hit_enable) rd_data = enable_q[enable_ctx];
        else if (hit_threshold) rd_data = threshold_q[threshold_ctx];
        else if (hit_claim) rd_data = {27'd0, claim_id};
    end

    //-------------------------------------------------------------------------
    // Byte-strobed write helper
    //-------------------------------------------------------------------------
    function automatic logic [31:0] merge_wstrb(input logic [31:0] old,
                                                input logic [31:0] new_data,
                                                input logic [3:0]  strb);
        logic [31:0] v;
        begin
            v = old;
            for (int i = 0; i < 4; i++)
                if (strb[i]) v[8*i +: 8] = new_data[8*i +: 8];
            merge_wstrb = v;
        end
    endfunction

    //-------------------------------------------------------------------------
    // Bus response
    //-------------------------------------------------------------------------
    assign req_ready = !rsp_valid_q;
    assign rsp_valid = rsp_valid_q;
    assign rsp_data  = rsp_data_q;

    wire claim_fire    = req_valid && req_ready && !req_write && hit_claim;
    wire complete_fire = req_valid && req_ready && req_write && hit_claim;

    always_ff @(posedge clk) begin
        if (rst) begin
            rsp_valid_q <= 1'b0;
            rsp_data_q  <= 32'h0;
        end else if (!rsp_valid_q) begin
            if (req_valid) begin
                rsp_valid_q <= 1'b1;
                rsp_data_q  <= req_write ? 32'h0 : rd_data;
            end
        end else if (rsp_ready) begin
            rsp_valid_q <= 1'b0;
        end
    end

    //-------------------------------------------------------------------------
    // Pending / in-service / configuration state
    //-------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            pending_q    <= 32'h0;
            in_service_q <= 32'h0;
            for (int s = 0; s < 32; s++) priority_q[s] <= 32'h0;
            for (int c = 0; c < NUM_CONTEXTS; c++) begin
                enable_q[c]    <= 32'h0;
                threshold_q[c] <= 32'h0;
            end
        end else begin
            // Level gateway: forward a source unless it is already pending or
            // still in service from a previous claim.
            for (int s = 1; s < 32; s++) begin
                if (src[s] && !pending_q[s] && !in_service_q[s])
                    pending_q[s] <= 1'b1;
            end

            if (req_valid && req_ready && req_write) begin
                if (hit_priority && (priority_idx != 5'd0))
                    priority_q[priority_idx] <= merge_wstrb(priority_q[priority_idx], req_wdata, req_wstrb);
                if (hit_enable)
                    enable_q[enable_ctx] <= merge_wstrb(enable_q[enable_ctx], req_wdata, req_wstrb);
                if (hit_threshold)
                    threshold_q[threshold_ctx] <= merge_wstrb(threshold_q[threshold_ctx], req_wdata, req_wstrb);
                if (complete_fire && (req_wdata[4:0] != 5'd0))
                    in_service_q[req_wdata[4:0]] <= 1'b0;
            end

            if (claim_fire && (claim_id != 5'd0)) begin
                pending_q[claim_id]    <= 1'b0;
                in_service_q[claim_id] <= 1'b1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // Per-context output
    //-------------------------------------------------------------------------
    always_comb begin
        for (int c = 0; c < NUM_CONTEXTS; c++) begin
            irq_out[c] = 1'b0;
            for (int s = 1; s < 32; s++) begin
                if (pending_q[s]
                    && enable_q[c][s]
                    && (priority_q[s] != 32'd0)
                    && (priority_q[s] > threshold_q[c]))
                    irq_out[c] = 1'b1;
            end
        end
    end

endmodule
