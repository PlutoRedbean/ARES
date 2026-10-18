/* verilator lint_off PROCASSINIT */
/* verilator lint_off BLKSEQ */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off PINCONNECTEMPTY */
`timescale 1ns/1ps
module tb_irom_bridge;
    logic clk=0,rst=1;
    always #5 clk=~clk;
    axi_if bus();
    logic [31:0] addr;
    logic [63:0] data;
    int checks=0;
    ares_irom_bridge dut(.clk(clk),.rst(rst),.bus(bus),.irom_addr(addr),.irom_data(data));
    function automatic logic [31:0] contents(input logic [31:0] a);
        return a ^ 32'h35abcda5;
    endfunction
    always_ff @(posedge clk) data <= {contents(addr+4),contents(addr)};
    task automatic read_word(input logic [31:0] a, input bit error_expected);
        @(negedge clk); bus.arvalid=1; bus.araddr=a;
        do @(posedge clk); while(!bus.arready);
        @(negedge clk); bus.arvalid=0; bus.araddr=32'h800000f8;
        wait(bus.rvalid);
        for(int i=0;i<4;i++) begin
            @(negedge clk);
            if(!bus.rvalid || bus.arready || bus.rresp!=error_expected ||
               bus.rdata !== (error_expected ? 32'd0 : contents(a))) $fatal(1,"IROM response / hold / word selection");
            checks++;
        end
        bus.rready=1; @(negedge clk); bus.rready=0;
    endtask
    initial begin
        bus.arvalid=0; bus.araddr=0; bus.rready=0; bus.awvalid=0; bus.awaddr=0;
        bus.wvalid=0; bus.wdata=0; bus.wstrb=0; bus.bready=0;
        repeat(3) @(negedge clk); rst=0;
        read_word(32'h80000000,0); read_word(32'h80000004,0);
        read_word(32'h8000001c,0); read_word(32'h80000020,0);
        read_word(32'h80007ff8,0); read_word(32'h80007ffc,0);
        read_word(32'h80008000,1); read_word(32'h80100000,1); read_word(32'h80000002,1);
        @(negedge clk); bus.arvalid=1; bus.araddr=32'h80000004;
        @(negedge clk); bus.arvalid=0; rst=1;
        @(negedge clk); rst=0;
        repeat(3) @(negedge clk);
        if(bus.rvalid || !bus.arready) $fatal(1,"reset leaked old transaction");
        $display("ALL TESTS PASSED: IROM bridge %0d checks, registered ROM, word select, stalls, boundaries, reset",checks);
        $finish;
    end
    initial begin #10000; $fatal(1,"timeout"); end
endmodule

/* verilator lint_on PINCONNECTEMPTY */
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on BLKSEQ */
/* verilator lint_on PROCASSINIT */
