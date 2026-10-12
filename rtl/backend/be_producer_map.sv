//=============================================================================
// ARES backend - Producer Map (B04)
//-----------------------------------------------------------------------------
// 32 x {valid, tag}: the youngest not-yet-committed writer of each register
// (backend.md sections 6, 7, 15.3, 14.5).  It converts architectural register
// dependencies into fixed CIQ tag dependencies at dispatch time.
//
//   * dispatch_base_map = producer_map with this cycle's normal commit clears
//     already applied (backend.md 7); dispatch binds sources against it so a
//     new entry can never depend on a producer that retires in this cycle;
//   * next state = base + D0 writer update + D1 writer update, in program
//     order (the younger lane overwrites a same-rd older lane);
//   * x0 is never valid;
//   * a validated branch-checkpoint restore replaces the whole map and takes
//     priority over the normal commit clears (backend.md 15.3); a flush cycle
//     never dispatches, so no writer update competes with the restore.
//
// FREE items: FREE-04 (parallel 32-entry compare/update), FREE-09 (register
//             array storage for the map and its restore path).
//=============================================================================
module be_producer_map (
    input  logic        clk,
    input  logic        rst,

    //---- normal commit clears (backend.md 6.2) -----------------------------
    input  logic [1:0]  commit_fire,
    input  tag_t        commit_tag [2],
    input  logic [1:0]  commit_rd_wen,
    input  logic [4:0]  commit_rd [2],

    //---- dispatch writer updates, lane 0 older than lane 1 ------------------
    input  logic [1:0]  disp_valid,
    input  logic [1:0]  disp_rd_wen,
    input  logic [4:0]  disp_rd [2],
    input  tag_t        disp_tag [2],

    //---- validated checkpoint restore (be_checkpoint) -----------------------
    input  logic        restore_valid,
    input  logic [31:0] restore_valid_map,
    input  tag_t        restore_tag [32],

    //---- map for dispatch source binding ------------------------------------
    output logic [31:0] base_valid,
    output tag_t        base_tag [32]
);
    import ares_pkg::*;

    logic [31:0] map_valid;
    tag_t        map_tag [32];

    // dispatch_base_map: apply this cycle's commit clears to the registered map.
    always_comb begin
        for (int unsigned r = 0; r < 32; r++) begin
            base_valid[r] = map_valid[r]
                && !(commit_fire[0] && commit_rd_wen[0] && (commit_rd[0] == 5'(r))
                     && (map_tag[r].slot_index == commit_tag[0].slot_index))
                && !(commit_fire[1] && commit_rd_wen[1] && (commit_rd[1] == 5'(r))
                     && (map_tag[r].slot_index == commit_tag[1].slot_index));
            base_tag[r] = map_tag[r];
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            map_valid <= 32'd0;
            for (int unsigned r = 0; r < 32; r++) map_tag[r] <= '0;
        end else if (restore_valid) begin
            for (int unsigned r = 0; r < 32; r++) begin
                map_valid[r] <= (r == 0) ? 1'b0 : restore_valid_map[r];
                map_tag[r]   <= restore_tag[r];
            end
        end else begin
            for (int unsigned r = 0; r < 32; r++) begin
                map_valid[r] <= (r == 0) ? 1'b0 : base_valid[r];
                map_tag[r]   <= base_tag[r];
                if (r != 0) begin
                    if (disp_valid[0] && disp_rd_wen[0] && (disp_rd[0] == 5'(r))) begin
                        map_valid[r] <= 1'b1;
                        map_tag[r]   <= disp_tag[0];
                    end
                    if (disp_valid[1] && disp_rd_wen[1] && (disp_rd[1] == 5'(r))) begin
                        map_valid[r] <= 1'b1;
                        map_tag[r]   <= disp_tag[1];
                    end
                end
            end
        end
    end

`ifdef CONFIG_SIMULATION
    always_ff @(posedge clk) begin
        if (!rst) a_x0_invalid : assert (map_valid[0] == 1'b0);
    end
`endif
endmodule
