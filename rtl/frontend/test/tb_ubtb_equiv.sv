// Cycle equivalence against the pre-C4 uBTB, including replacement, decay,
// multiple CFI slots, unaligned windows and simultaneous prediction/training.
/* verilator lint_off UNUSEDSIGNAL */
`timescale 1ns/1ps
module tb_ubtb_equiv;
    import fe_pkg::*;
    logic clk, rst, req_valid, update_en, actual_taken;
    logic [ADDR_WIDTH-1:0] fetch_pc, update_pc;
    btb_target_info_t update_target;
    logic resp_valid, ref_valid;
    logic [ADDR_WIDTH-1:0] resp_pc, ref_pc;
    logic [FETCH_WIDTH-1:0] pred_cfi_valid, ref_cfi_valid;
    cfi_type_t [FETCH_WIDTH-1:0] pred_cfi_type, ref_type;
    logic [FETCH_WIDTH-1:0][ADDR_WIDTH-1:0] pred_target, ref_target;
    int unsigned seed;
    int checks, hits;
    initial begin clk=0; forever #5 clk=~clk; end
    ubtb dut(.*);
    ubtb_reference reference_model (.clk(clk),.rst(rst),.req_valid(req_valid),.fetch_pc(fetch_pc),
        .resp_valid(ref_valid),.resp_pc(ref_pc),.pred_cfi_valid(ref_cfi_valid),
        .pred_cfi_type(ref_type),.pred_target(ref_target),.update_en(update_en),
        .update_pc(update_pc),.actual_taken(actual_taken),.update_target(update_target));
    function automatic int unsigned rnd(input int unsigned limit);
        seed=seed*32'd1664525+32'd1013904223;
        return (seed>>8)%limit;
    endfunction
    initial begin
        seed=32'h31415926; checks=0; hits=0;
        rst=1; req_valid=0; update_en=0; actual_taken=0;
        fetch_pc='0; update_pc='0; update_target='0;
        for(int n=0;n<30000;n++) begin
            @(negedge clk);
            rst=(n%5000)<3;
            req_valid=(rnd(4)!=0);
            update_en=(rnd(4)!=0);
            actual_taken=(rnd(4)!=0);
            fetch_pc=32'h80000000+32'(rnd(4096)*4);
            update_pc=(n%3==0) ? fetch_pc : 32'h80000000+32'(rnd(4096)*4);
            update_target.start_pc=update_pc & 32'hfffffff0;
            update_target.target_pc=32'h80000000+32'(rnd(4096)*4);
            update_target.cfi_offset=FETCH_WIDTH'(update_pc[3:2]);
            update_target.cfi_type=cfi_type_t'(1+rnd(5));
            @(posedge clk); #1;
            if(resp_valid!==ref_valid || resp_pc!==ref_pc || pred_cfi_valid!==ref_cfi_valid ||
               pred_cfi_type!==ref_type || pred_target!==ref_target)
                $fatal(1,"uBTB cycle-equivalence mismatch at cycle %0d",n);
            checks++;
            if(|pred_cfi_valid) hits++;
        end
        if(hits<100) $fatal(1,"uBTB test lacks prediction hits");
        $display("ALL TESTS PASSED: uBTB cycle equivalence %0d cycles, %0d hit windows, fixed seed 31415926",checks,hits);
        $finish;
    end
endmodule
/* verilator lint_on UNUSEDSIGNAL */
