// Commit acceptance and table-training transport are independent of recovery.
module bpu_commit_queue (
    input logic clk, rst,
    input logic train_ready,
    input logic [1:0] update_valid,
    input fe_pkg::bpu_update_t update [2],
    output logic [1:0] credit,
    output logic train_valid,
    output fe_pkg::bpu_update_t train,
    output logic [fe_pkg::GHR_WIDTH-1:0] ghr_commit_next
);
    import fe_pkg::*;
    bpu_update_t fifo [8];
    logic [2:0] rd_ptr, wr_ptr;
    logic [3:0] occupancy;
    logic [1:0] incoming;
    wire pop = train_valid && train_ready;
    logic [GHR_WIDTH-1:0] ghr_commit;
    assign credit = occupancy <= 4'd6 ? 2'd2 : (occupancy == 4'd7 ? 2'd1 : 2'd0);
    assign incoming = {1'b0, update_valid[0]} + {1'b0, update_valid[1]};
    assign train_valid = !rst && occupancy != 0;
    assign train = fifo[rd_ptr];
    always_comb begin
        ghr_commit_next = ghr_commit;
        for (int l=0; l<2; l++)
            if (update_valid[l])
                ghr_commit_next = (ghr_commit_next << 1) | GHR_WIDTH'(update[l].actual_taken);
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            rd_ptr <= '0; wr_ptr <= '0; occupancy <= '0; ghr_commit <= '0;
        end else begin
            ghr_commit <= ghr_commit_next;
            if (update_valid[0]) fifo[wr_ptr] <= update[0];
            if (update_valid[1]) fifo[wr_ptr + 3'(update_valid[0])] <= update[1];
            wr_ptr <= wr_ptr + 3'(incoming);
            if (pop) rd_ptr <= rd_ptr + 1'b1;
            occupancy <= occupancy + 4'(incoming) - 4'(pop);
`ifdef CONFIG_SIMULATION
            assert (incoming <= credit) else $fatal(1,"BPU commit credit exceeded");
            assert (occupancy <= 8);
`endif
        end
    end
endmodule
