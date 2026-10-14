//=============================================================================
// ARES backend - 2-wide Decode / Dispatch (B02 + B03)
//-----------------------------------------------------------------------------
// Consumes the FE instruction interface (frontend_backend_contract.md 2) and
// allocates up to two CIQ entries per cycle:
//
//   * iq_accept_count is the only consumption handshake; it is a contiguous
//     prefix of the valid lanes and is limited by CIQ capacity, the
//     Serializing Dispatch Gate, IRQ Drain and a body Redirect (backend.md
//     5.1, contract 2/5).  Capacity is never borrowed from this cycle's
//     releases (backend.md 5.1, D-C0-05);
//   * a decode_err stops the prefix: that instruction and every younger one
//     stay in the IQ (D-C0-01), they never allocate a CIQ slot;
//   * source dependencies are bound against dispatch_base_map with the D0->D1
//     same-cycle tag bypass of backend.md 7 (only the tag is forwarded);
//   * the Producer Map writer update and the branch-checkpoint snapshot are
//     produced for the accepted prefix only (backend.md 7/15.2).
//
// Two be_decode instances do the instruction decoding; the decode cross-check
// against the FE predecode result is reported on decode_err.
//
// FREE items: FREE-02 (decode instantiated inside dispatch), FREE-04 (parallel
//             prefix/gate logic), FREE-09 (checkpoint snapshot construction).
//=============================================================================
module be_dispatch (
    input  logic        clk,
    input  logic        rst,

    //---- FE instruction interface (contract section 2) ---------------------
    input  logic [1:0]  iq_valid,
    input  ares_pkg::iq_entry_t   iq_inst [2],
    output logic [1:0]  iq_accept_count,

    //---- dispatch conditions ------------------------------------------------
    input  logic [4:0]  free_count,
    input  logic        serializing_present,
    input  logic        irq_drain,
    input  logic        redirect_active,
    input  logic [31:0] base_valid,
    input  ares_pkg::tag_t        base_tag [32],
    input  ares_pkg::tag_t        alloc_ptr,

    //---- CIQ allocate -------------------------------------------------------
    output logic [1:0]        alloc_valid,
    output ares_pkg::queue_entry_t      alloc_entry [2],

    //---- Producer Map writer update ----------------------------------------
    output logic [1:0]        pm_we,
    output logic [4:0]        pm_rd [2],
    output ares_pkg::tag_t              pm_tag [2],

    //---- Branch Map Checkpoint snapshot write ------------------------------
    output logic [1:0]        cp_we,
    output ares_pkg::tag_t              cp_wslot [2],
    output logic [31:0]       cp_wvalid [2],
    output ares_pkg::tag_t              cp_wtag [2][32],

    //---- decode error observability (SPEC-A1 / D-C0-01) --------------------
    output logic [1:0]        decode_err
);
    import ares_pkg::*;

    //-------------------------------------------------------------------------
    // Lane decoding (B02 x2)
    //-------------------------------------------------------------------------
    fu_type_t    d_fu_type [2];
    op_t         d_op [2];
    logic [4:0]  d_rd [2];
    logic [1:0]  d_rd_wen;
    logic [4:0]  d_rs1 [2];
    logic [1:0]  d_src1_used;
    logic [4:0]  d_rs2 [2];
    logic [1:0]  d_src2_used;
    logic [31:0] d_imm [2];
    logic [11:0] d_csr_addr [2];
    logic [1:0]  d_csr_write_en;
    logic [1:0]  d_is_serializing;
    logic [1:0]  d_is_cfi;
    logic [1:0]  d_is_branch;
    cfi_type_t   d_cfi_type [2];
    logic [1:0]  d_is_load, d_is_store, d_is_csr, d_is_fence;
    logic [1:0]  d_valid;

    for (genvar g = 0; g < 2; g++) begin : gen_decode
        be_decode u_decode (
            .iq             (iq_inst[g]),
            .decode_err     (decode_err[g]),
            .valid          (d_valid[g]),
            .fu_type        (d_fu_type[g]),
            .op             (d_op[g]),
            .rd             (d_rd[g]),
            .rd_wen         (d_rd_wen[g]),
            .rs1            (d_rs1[g]),
            .src1_used      (d_src1_used[g]),
            .rs2            (d_rs2[g]),
            .src2_used      (d_src2_used[g]),
            .imm            (d_imm[g]),
            .csr_addr       (d_csr_addr[g]),
            .csr_write_en   (d_csr_write_en[g]),
            .is_serializing (d_is_serializing[g]),
            .is_cfi         (d_is_cfi[g]),
            .is_branch      (d_is_branch[g]),
            .actual_cfi_type(d_cfi_type[g]),
            .is_load        (d_is_load[g]),
            .is_store       (d_is_store[g]),
            .is_csr         (d_is_csr[g]),
            .is_fence       (d_is_fence[g])
        );
    end

    //-------------------------------------------------------------------------
    // accept_count: contiguous prefix limited by capacity, serializing gate,
    // decode errors, IRQ drain and redirect (backend.md 5.1, contract 2).
    //-------------------------------------------------------------------------
    logic [1:0] available;
    assign available = {1'b0, iq_valid[0]} + {1'b0, iq_valid[1]};

    logic [1:0] limit_free, limit_gate, limit_err, accept;
    always_comb begin
        limit_free = (free_count >= 5'd2) ? 2'd2 : ((free_count == 5'd1) ? 2'd1 : 2'd0);

        if (serializing_present)                              limit_gate = 2'd0;
        else if (iq_valid[0] && d_is_serializing[0])          limit_gate = 2'd1;
        else                                                  limit_gate = 2'd2;

        if (decode_err[0])                                    limit_err = 2'd0;
        else if (iq_valid[1] && decode_err[1])                limit_err = 2'd1;
        else                                                  limit_err = 2'd2;

        accept = limit_free;
        if (limit_gate < accept) accept = limit_gate;
        if (limit_err  < accept) accept = limit_err;
        if (available   < accept) accept = available;
        if (irq_drain || redirect_active || rst) accept = 2'd0;
    end
    assign iq_accept_count = accept;

    logic acc0, acc1;
    assign acc0 = |iq_accept_count;     // lane 0 is accepted for count 1 and 2
    assign acc1 = iq_accept_count[1];   // lane 1 only for count == 2

    //-------------------------------------------------------------------------
    // Allocation tags (the CIQ allocate pointer is the base).
    //-------------------------------------------------------------------------
    tag_t tag_l [2];
    always_comb begin
        tag_l[0].slot_index = alloc_ptr.slot_index;
        tag_l[1].slot_index = alloc_ptr.slot_index + 4'd1;
    end

    //-------------------------------------------------------------------------
    // Source dependency binding (backend.md 7)
    //-------------------------------------------------------------------------
    logic       dep1_valid_l [2], dep2_valid_l [2];
    tag_t       dep1_tag_l [2],   dep2_tag_l [2];
    logic       d0_match1, d0_match2;

    assign d0_match1 = acc0 && d_rd_wen[0] && (d_rd[0] != 5'd0) && (d_rd[0] == d_rs1[1]);
    assign d0_match2 = acc0 && d_rd_wen[0] && (d_rd[0] != 5'd0) && (d_rd[0] == d_rs2[1]);

    always_comb begin
        // lane 0 binds against dispatch_base_map only
        dep1_valid_l[0] = d_src1_used[0] && (d_rs1[0] != 5'd0) && base_valid[d_rs1[0]];
        dep1_tag_l[0]   = base_tag[d_rs1[0]];
        dep2_valid_l[0] = d_src2_used[0] && (d_rs2[0] != 5'd0) && base_valid[d_rs2[0]];
        dep2_tag_l[0]   = base_tag[d_rs2[0]];

        // lane 1 prefers the D0 writer of this cycle, then dispatch_base_map
        dep1_valid_l[1] = d_src1_used[1] && (d_rs1[1] != 5'd0)
                          && (d0_match1 || base_valid[d_rs1[1]]);
        dep1_tag_l[1]   = d0_match1 ? tag_l[0] : base_tag[d_rs1[1]];
        dep2_valid_l[1] = d_src2_used[1] && (d_rs2[1] != 5'd0)
                          && (d0_match2 || base_valid[d_rs2[1]]);
        dep2_tag_l[1]   = d0_match2 ? tag_l[0] : base_tag[d_rs2[1]];
    end

    //-------------------------------------------------------------------------
    // CIQ entry assembly for the accepted prefix
    //-------------------------------------------------------------------------
    always_comb begin
        for (int unsigned l = 0; l < 2; l++) begin
            alloc_valid[l]      = (l == 0) ? acc0 : acc1;

            alloc_entry[l]      = '0;
            alloc_entry[l].valid = 1'b1;
            alloc_entry[l].state = ENTRY_WAIT;

            alloc_entry[l].pc            = iq_inst[l].pc;
            alloc_entry[l].pred_npc      = iq_inst[l].pred_npc;
            alloc_entry[l].pred_meta     = iq_inst[l].pred_meta;
            alloc_entry[l].need_redirect = iq_inst[l].need_redirect;
            alloc_entry[l].actual_cfi_type = d_cfi_type[l];

            alloc_entry[l].fu_type = d_fu_type[l];
            alloc_entry[l].op      = d_op[l];

            alloc_entry[l].rd     = d_rd[l];
            alloc_entry[l].rd_wen = d_rd_wen[l];

            alloc_entry[l].rs1            = d_rs1[l];
            alloc_entry[l].src1_used      = d_src1_used[l];
            alloc_entry[l].src1_dep_valid = dep1_valid_l[l];
            alloc_entry[l].src1_dep_tag   = dep1_tag_l[l];

            alloc_entry[l].rs2            = d_rs2[l];
            alloc_entry[l].src2_used      = d_src2_used[l];
            alloc_entry[l].src2_dep_valid = dep2_valid_l[l];
            alloc_entry[l].src2_dep_tag   = dep2_tag_l[l];

            alloc_entry[l].imm = d_imm[l];

            alloc_entry[l].csr_addr     = d_csr_addr[l];
            alloc_entry[l].csr_write_en = d_csr_write_en[l];
            alloc_entry[l].is_serializing = d_is_serializing[l];

            alloc_entry[l].is_branch = d_is_branch[l];
            alloc_entry[l].is_load   = d_is_load[l];
            alloc_entry[l].is_store  = d_is_store[l];
            alloc_entry[l].is_csr    = d_is_csr[l];
            alloc_entry[l].is_fence  = d_is_fence[l];
        end
    end

    //-------------------------------------------------------------------------
    // Producer Map writer update (backend.md 7)
    //-------------------------------------------------------------------------
    always_comb begin
        pm_we[0] = acc0 && d_rd_wen[0] && (d_rd[0] != 5'd0);
        pm_we[1] = acc1 && d_rd_wen[1] && (d_rd[1] != 5'd0);
        pm_rd[0] = d_rd[0];
        pm_rd[1] = d_rd[1];
        pm_tag[0] = tag_l[0];
        pm_tag[1] = tag_l[1];
    end

    //-------------------------------------------------------------------------
    // Branch Map Checkpoint snapshots (backend.md 15.2): D0's row already
    // contains D0's own rd update; D1's row contains D0 and D1.
    //-------------------------------------------------------------------------
    logic [31:0] snap0_valid, snap1_valid;
    tag_t        snap0_tag [32], snap1_tag [32];

    always_comb begin
        for (int unsigned r = 0; r < 32; r++) begin
            snap0_valid[r] = (r != 0) && (base_valid[r]
                             || (acc0 && d_rd_wen[0] && (d_rd[0] == 5'(r))));
            snap0_tag[r]   = (acc0 && d_rd_wen[0] && (d_rd[0] == 5'(r))) ? tag_l[0] : base_tag[r];

            snap1_valid[r] = (r != 0) && (snap0_valid[r]
                             || (acc1 && d_rd_wen[1] && (d_rd[1] == 5'(r))));
            snap1_tag[r]   = (acc1 && d_rd_wen[1] && (d_rd[1] == 5'(r))) ? tag_l[1] : snap0_tag[r];
        end
    end

    always_comb begin
        cp_we[0]    = acc0 && d_is_branch[0];
        cp_wslot[0] = tag_l[0];
        cp_wvalid[0] = snap0_valid;
        for (int unsigned r = 0; r < 32; r++) cp_wtag[0][r] = snap0_tag[r];

        cp_we[1]    = acc1 && d_is_branch[1];
        cp_wslot[1] = tag_l[1];
        cp_wvalid[1] = snap1_valid;
        for (int unsigned r = 0; r < 32; r++) cp_wtag[1][r] = snap1_tag[r];
    end

`ifdef CONFIG_SIMULATION
    always_ff @(posedge clk) begin
        if (!rst) begin
            a_accept_prefix : assert (iq_accept_count <= available);
            a_accept_two    : assert (iq_accept_count != 2'd2 || (iq_valid[0] && iq_valid[1]));
        end
    end

    // The decode lane valid bit mirrors the IQ valid bit, and the CIQ control
    // transfer flag is exactly the decoded CFI class.
    always_ff @(posedge clk) if (!rst) begin
        a_dec_valid0  : assert (d_valid[0]  == iq_valid[0]);
        a_dec_valid1  : assert (d_valid[1]  == iq_valid[1]);
        a_dec_branch0 : assert (d_is_branch[0] == d_is_cfi[0]);
        a_dec_branch1 : assert (d_is_branch[1] == d_is_cfi[1]);
    end
`endif
endmodule
