module Adder(
  input  [31:0] din1,
  input  [31:0] din2,
  input         din0,
  output [31:0] sum ,
  output        dout,
  output        overflow
);

  wire [31:0] in1, in2;
  assign in1 = din1;
  assign in2 = {32{din0}} ^ din2;
  assign {dout, sum} = in1 + in2 + {31'd0, din0};
  assign overflow = (in1[31] ~^ in2[31]) & (sum[31] ^ in1[31]);

endmodule
