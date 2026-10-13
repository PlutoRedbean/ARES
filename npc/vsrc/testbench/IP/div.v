`include "common_para.vh"
module div #(
    parameter LATENCY = `CONFIG_DIV_LATENCY
)(
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

    reg [63:0] data_pipe  [0:LATENCY-1];
    reg        valid_pipe [0:LATENCY-1];

    wire fire = s_axis_dividend_tvalid && s_axis_divisor_tvalid;
    wire divisor_is_zero = s_axis_divisor_tdata == 32'b0;
    wire [31:0] quotient  = s_axis_dividend_tdata / s_axis_divisor_tdata;
    wire [31:0] remainder = s_axis_dividend_tdata % s_axis_divisor_tdata;

    integer i;

    initial begin
        for (i = 0; i < LATENCY; i = i + 1) begin
            data_pipe[i]  = 64'b0;
            valid_pipe[i] = 1'b0;
        end
    end

    always @(posedge aclk) begin
        if (fire && divisor_is_zero) begin
            data_pipe[0] <= {$random, $random};
        end else begin
            data_pipe[0] <= {quotient, remainder};
        end
        valid_pipe[0] <= fire;
        for (i = 1; i < LATENCY; i = i + 1) begin
            data_pipe[i]  <= data_pipe[i - 1];
            valid_pipe[i] <= valid_pipe[i - 1];
        end
    end

    assign s_axis_dividend_tready = 1'b1;
    assign s_axis_divisor_tready  = 1'b1;
    assign m_axis_dout_tdata      = data_pipe[LATENCY - 1];
    assign m_axis_dout_tvalid     = valid_pipe[LATENCY - 1];

endmodule
