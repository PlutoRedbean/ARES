module Multiplier(
    input         CLK   ,
    input         CE    ,
    input  [32:0] A     ,
    input  [32:0] B     ,
    output [63:0] P
);

    mult u_mult(
        .CLK 	( CLK  ),
        .CE  	( CE   ),
        .A   	( A    ),
        .B   	( B    ),
        .P   	( P    )
    );

endmodule
