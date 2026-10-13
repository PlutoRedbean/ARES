module Encode24(
    input  [1:0] din    ,
    output [3:0] dout
);

assign dout[0] = ~din[1] & ~din[0];
assign dout[1] = ~din[1] &  din[0];
assign dout[2] =  din[1] & ~din[0];
assign dout[3] =  din[1] &  din[0];
    
endmodule
