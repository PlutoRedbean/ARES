module ReturnAddressStack #(
    parameter ADDR_WIDTH = 32,
    parameter RAS_WIDTH  = 3
)(
    input                     clk,
    input                     rst,

    input                     update_push,
    input                     update_pop,
    input  [ADDR_WIDTH - 1:0] update_addr,

    output                    top_valid,
    output [ADDR_WIDTH - 1:0] top_addr
);

    localparam ENTRIES = 1 << RAS_WIDTH;
    localparam COUNT_WIDTH = RAS_WIDTH + 1;
    localparam [COUNT_WIDTH-1:0] ENTRY_COUNT = ENTRIES;

    // stack[0] is always the top.  This avoids a dynamic-index mux on the
    // prediction path; only the update path shifts entries.
    reg [ADDR_WIDTH-1:0] stack [0:ENTRIES-1];
    reg [COUNT_WIDTH-1:0] count;

    assign top_valid = count != {COUNT_WIDTH{1'b0}};
    assign top_addr = stack[0];

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            count <= {COUNT_WIDTH{1'b0}};
        end else begin
            case ({update_push, update_pop})
                2'b10: begin
                    for (i = ENTRIES - 1; i > 0; i = i - 1) begin
                        stack[i] <= stack[i - 1];
                    end
                    stack[0] <= update_addr;
                    if (count != ENTRY_COUNT) begin
                        count <= count + 1'b1;
                    end
                end
                2'b01: begin
                    if (count != {COUNT_WIDTH{1'b0}}) begin
                        for (i = 0; i < ENTRIES - 1; i = i + 1) begin
                            stack[i] <= stack[i + 1];
                        end
                        count <= count - 1'b1;
                    end
                end
                2'b11: begin
                    // RISC-V coroutine hint: pop the old link, then push the
                    // new one.  Entries below the top and a nonzero count stay.
                    stack[0] <= update_addr;
                    if (count == {COUNT_WIDTH{1'b0}}) begin
                        count <= {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
                    end
                end
                default: begin
                    count <= count;
                end
            endcase
        end
    end

endmodule
