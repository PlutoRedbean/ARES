`timescale 1ns/1ps
module tb_icache_way;
    logic clk,rst,wr_en;
    logic [5:0] rd_addr_a,rd_addr_b,wr_addr;
    logic [255:0] wr_data,rd_data_a,rd_data_b;
    logic [255:0] model[64],expect_a,expect_b;
    logic [63:0] initialized;
    bit check_a,check_b;
    int unsigned seed;
    int checks;
    initial begin clk=0; forever #5 clk=~clk; end
    icache_data_way dut(.*);
    function automatic logic [31:0] rnd();
        seed=seed*32'd1664525+32'd1013904223;
        return seed;
    endfunction
    initial begin
        seed=32'h12345678; checks=0; initialized='0; expect_b='0; check_b=1;
        rst=1; wr_en=0; rd_addr_a=0; rd_addr_b=0; wr_addr=0; wr_data=0;
        // UNISIM models hold configuration GSR for the first 100ns.
        #120;
        for(int n=0;n<5000;n++) begin
            @(negedge clk);
            rst=(n==0)||(n%997==0);
            wr_en=(n<65)||(1'(rnd()));
            wr_addr=(n<65)?6'(n-1):6'(rnd());
            rd_addr_a=(n%4==0)?wr_addr:6'(rnd());
            rd_addr_b=6'(rnd());
            for(int j=0;j<8;j++) wr_data[j*32+:32]=rnd();
            // Capture the old value before applying the modeled write.
            check_a=rst || initialized[rd_addr_a];
            expect_a=rst?'0:model[rd_addr_a];
            if(rst) begin expect_b='0; check_b=1; end
            else if(!wr_en) begin expect_b=model[rd_addr_b]; check_b=initialized[rd_addr_b]; end
            if(!rst && wr_en) begin model[wr_addr]=wr_data; initialized[wr_addr]=1; end
            @(posedge clk); #1;
            if(check_a) begin
                checks++;
                if(rd_data_a!==expect_a) $fatal(1,"ICache way port A/read-first cycle %0d",n);
            end
            if(check_b) begin
                checks++;
                if(rd_data_b!==expect_b) $fatal(1,"ICache way port B/held response cycle %0d",n);
            end
        end
        if(checks<9000) $fatal(1,"ICache way coverage too small");
        $display("ALL TESTS PASSED: ICache TDP way %0d checks, 5000 cycles, refill/read-first/B hold/reset preserves RAM",checks);
        $finish;
    end
endmodule
