// RAS commit state advances on accepted CFI events, never delayed training.
module ras (
    input logic clk, rst,
    output logic top_valid,
    output logic [fe_pkg::ADDR_WIDTH-1:0] top_addr,
    input logic spec_push, spec_pop,
    input logic [fe_pkg::ADDR_WIDTH-1:0] spec_addr,
    input logic flush,
    input logic [1:0] commit_valid,
    input fe_pkg::bpu_update_t commit_update [2]
);
    import fe_pkg::*;
    localparam int CW = $clog2(RAS_ENTRIES+1);
    logic [ADDR_WIDTH-1:0] spec_mem [RAS_ENTRIES], commit_mem [RAS_ENTRIES], commit_next [RAS_ENTRIES];
    logic [CW-1:0] sp_spec, sp_commit, sp_next;
    assign top_valid = sp_spec != 0;
    assign top_addr = spec_mem[sp_spec == 0 ? 0 : int'(sp_spec)-1];
    always_comb begin
        sp_next = sp_commit;
        for (int i=0; i<RAS_ENTRIES; i++) commit_next[i] = commit_mem[i];
        for (int l=0; l<2; l++) begin
            if (commit_valid[l]) begin
                if (commit_update[l].actual_cfi_type == CFI_CALL && int'(sp_next) < RAS_ENTRIES) begin
                    commit_next[int'(sp_next)] = commit_update[l].update_pc + 32'd4;
                    sp_next = sp_next + 1'b1;
                end else if (commit_update[l].actual_cfi_type == CFI_RETURN && sp_next != 0)
                    sp_next = sp_next - 1'b1;
            end
        end
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            sp_spec <= '0; sp_commit <= '0;
            for (int i=0; i<RAS_ENTRIES; i++) begin spec_mem[i] <= '0; commit_mem[i] <= '0; end
        end else begin
            sp_commit <= sp_next;
            for (int i=0; i<RAS_ENTRIES; i++) commit_mem[i] <= commit_next[i];
            if (flush) begin
                sp_spec <= sp_next;
                for (int i=0; i<RAS_ENTRIES; i++) spec_mem[i] <= commit_next[i];
            end else if (spec_push && int'(sp_spec) < RAS_ENTRIES) begin
                spec_mem[int'(sp_spec)] <= spec_addr; sp_spec <= sp_spec + 1'b1;
            end else if (spec_pop && sp_spec != 0) sp_spec <= sp_spec - 1'b1;
        end
    end
endmodule
