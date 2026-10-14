// Real ARES Core + migrated JYD SoC. FE stimulus uses the approved IQ contract.
/* verilator lint_off PINCONNECTEMPTY */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off BLKSEQ */
/* verilator lint_off PROCASSINIT */
module tb_student_top;
    import ares_pkg::*;
    logic w_cpu_clk=0, w_clk_50Mhz=0, w_clk_rst=1;
    always #2 w_cpu_clk=~w_cpu_clk;
    always #10 w_clk_50Mhz=~w_clk_50Mhz;
    logic [1:0] iq_valid, iq_accept_count;
    iq_entry_t iq_inst [2];
    logic backend_redirect_valid, backend_redirect_actual_taken;
    logic [31:0] backend_redirect_pc;
    fe_redirect_kind_t backend_redirect_kind;
    logic [GHR_WIDTH-1:0] backend_redirect_ghr_before;
    logic [1:0] bpu_update_valid;
    bpu_update_t bpu_update [2];
    logic [31:0] virtual_led;
    logic [39:0] virtual_seg;
    logic [63:0] ifetch_data;
    int sent=0, retired=0, checks=0;
    logic [31:0] program_words [12];
    student_top dut (
        .w_cpu_clk(w_cpu_clk), .w_clk_50Mhz(w_clk_50Mhz), .w_clk_rst(w_clk_rst),
        .virtual_key(8'hA5), .virtual_sw(64'h1020304050607080),
        .uart_rx_data(8'd0), .uart_rx_ready(1'b0), .uart_tx_busy(1'b0),
        .uart_tx_data(), .uart_tx_start(), .virtual_led(virtual_led), .virtual_seg(virtual_seg),
        .ifetch_addr(32'h80000000), .ifetch_data(ifetch_data),
        .mt_wr_en(), .mt_wr_idx(), .mt_wr_data(), .mt_status_rd(), .mt_status(32'd0), .mt_result(32'd0),
        .iq_valid(iq_valid), .iq_inst(iq_inst), .iq_accept_count(iq_accept_count),
        .backend_redirect_valid(backend_redirect_valid), .backend_redirect_pc(backend_redirect_pc),
        .backend_redirect_kind(backend_redirect_kind), .backend_redirect_ghr_before(backend_redirect_ghr_before),
        .backend_redirect_actual_taken(backend_redirect_actual_taken),
        .bpu_update_credit(2'd2), .bpu_update_valid(bpu_update_valid), .bpu_update(bpu_update)
    );
    always_comb begin
        iq_valid = !w_clk_rst && sent<12 ? 2'b01 : 2'b00;
        iq_inst[0]='0; iq_inst[1]='0;
        if(sent<12) begin
            iq_inst[0].valid=1;
            iq_inst[0].pc=RESET_PC+32'(sent*4);
            iq_inst[0].inst=program_words[sent];
            iq_inst[0].pred_npc=RESET_PC+32'((sent+1)*4);
        end
    end
    always @(posedge w_cpu_clk) begin
        if (!w_clk_rst) begin
            if (iq_accept_count>1) $fatal(1,"accepted more instructions than provided");
            sent<=sent+int'(iq_accept_count);
            if (backend_redirect_valid || bpu_update_valid!=0) $fatal(1,"unexpected CFI activity");
            for(int lane=0; lane<2; lane++) begin
                if (dut.Core_cpu.retire_valid[lane]) begin
                    if(dut.Core_cpu.retire_pc[lane]!==RESET_PC+32'(retired*4)) $fatal(1,"retire order");
                    case(retired)
                        0: if(dut.Core_cpu.retire_wdata[lane]!==32'h80300000) $fatal(1,"LUI alias");
                        1,10: if(dut.Core_cpu.retire_wdata[lane]!==32'h123) $fatal(1,"data/alias/cache visibility");
                        3: if(dut.Core_cpu.retire_wdata[lane]!==32'h23) $fatal(1,"LB extraction");
                        4: if(dut.Core_cpu.retire_wdata[lane]!==32'h80200000) $fatal(1,"LUI MMIO");
                        6: if(dut.Core_cpu.retire_wdata[lane]!==32'hA5) $fatal(1,"MMIO key");
                        7: if(dut.Core_cpu.retire_wdata[lane]!==32'h80100000) $fatal(1,"LUI cacheable");
                        8: if(dut.Core_cpu.retire_wdata[lane]!==32'h123) $fatal(1,"cache miss after alias store");
                        11: if(dut.Core_cpu.retire_wdata[lane]!==32'd77) $fatal(1,"final ADDI");
                        default: ;
                    endcase
                    retired++; checks++;
                end
            end
        end
    end
    initial begin
        program_words='{32'h803000B7,32'h12300113,32'h0020A023,32'h00008183,
                        32'h80200237,32'h04222023,32'h01022283,32'h80100337,
                        32'h00032383,32'h00232823,32'h01032403,32'h04D00493};
        repeat(6) @(negedge w_cpu_clk); w_clk_rst=0;
        wait(retired==12);
        repeat(150) @(negedge w_cpu_clk);
        if(virtual_led!==32'h123) $fatal(1,"LED side effect");
        if(ifetch_data!==64'h0000001300000013) $fatal(1,"IROM timing model");
        checks+=2;
        $display("ALL TESTS PASSED: student_top %0d checks; 12 instructions retired through real ARES Core, alias/uncached/MMIO/cache",checks);
        $finish;
    end
    initial begin #200000; $fatal(1,"student_top timed out"); end
endmodule
/* verilator lint_on BLKSEQ */
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on PINCONNECTEMPTY */
/* verilator lint_on PROCASSINIT */
