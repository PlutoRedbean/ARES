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
    initial begin
        foreach (memory[i]) memory[i] = 0;
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
    // A pair of RV32 NOPs; used only for student_top elaboration/smoke tests.
    always_ff @(posedge clka) douta <= {32'h00000013, 32'h00000013} ^ {52'd0, addra};
endmodule
