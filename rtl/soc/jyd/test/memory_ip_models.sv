// Unit-test IP timing models. Never imported by the Vivado project generator.
module BRAM (
    input logic clka, clkb,
    input logic [15:0] addra, addrb,
    input logic [3:0] wea,
    input logic [31:0] dina,
    output logic [31:0] doutb
);
    logic [31:0] memory [65536];
    logic [31:0] read_q;
    string image;
    initial begin
        foreach (memory[i]) memory[i] = 0;
        if ($value$plusargs("DRAM_HEX=%s",image)) $readmemh(image,memory);
        read_q = 0;
        doutb = 0;
    end
    always_ff @(posedge clka)
        for (int b=0; b<4; b++)
            if (wea[b]) memory[addra][b*8 +: 8] <= dina[b*8 +: 8];
    always_ff @(posedge clkb) begin
        read_q <= memory[addrb];
        doutb <= read_q;
    end
endmodule
module IROM_BMEM (
    input logic clka,
    input logic [11:0] addra,
    output logic [63:0] douta
);
    logic [63:0] memory [4096];
    string image;
    initial begin
        foreach (memory[i]) memory[i] = 64'h0000001300000013;
        if ($value$plusargs("IROM_HEX=%s",image)) $readmemh(image,memory);
    end
    always_ff @(posedge clka) douta <= memory[addra];
endmodule
