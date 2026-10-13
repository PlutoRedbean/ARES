module Divider(
    input         aclk                  ,
    input  [31:0] s_axis_dividend_tdata ,
    output        s_axis_dividend_tready,
    input         s_axis_dividend_tvalid,
    input  [31:0] s_axis_divisor_tdata  ,
    output        s_axis_divisor_tready ,
    input         s_axis_divisor_tvalid ,
    output [63:0] m_axis_dout_tdata     ,
    output        m_axis_dout_tvalid
);

    div div(
        .aclk                   	( aclk                    ),
        .s_axis_dividend_tdata  	( s_axis_dividend_tdata   ),
        .s_axis_dividend_tready 	( s_axis_dividend_tready  ),
        .s_axis_dividend_tvalid 	( s_axis_dividend_tvalid  ),
        .s_axis_divisor_tdata   	( s_axis_divisor_tdata    ),
        .s_axis_divisor_tready  	( s_axis_divisor_tready   ),
        .s_axis_divisor_tvalid  	( s_axis_divisor_tvalid   ),
        .m_axis_dout_tdata      	( m_axis_dout_tdata       ),
        .m_axis_dout_tvalid     	( m_axis_dout_tvalid      )
    );

endmodule
