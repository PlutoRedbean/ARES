module ReturnAddressStack #(
    parameter ADDR_WIDTH = 32,
    parameter RAS_WIDTH  = 3
)(
    input                     clk,
    input                     rst,

    input                     spec_push,
    input                     spec_pop,
    input  [ADDR_WIDTH - 1:0] spec_addr,

    input                     commit_push,
    input                     commit_pop,
    input  [ADDR_WIDTH - 1:0] commit_addr,
    input                     restore,

    output                    top_valid,
    output [ADDR_WIDTH - 1:0] top_addr
);

    localparam ENTRIES = 1 << RAS_WIDTH;
    localparam COUNT_WIDTH = RAS_WIDTH + 1;
    localparam [COUNT_WIDTH-1:0] ENTRY_COUNT = ENTRIES;

    // stack[0] is always the top.  This avoids a dynamic-index mux on the
    // prediction path; only the update path shifts entries.
    reg [ADDR_WIDTH-1:0] spec_stack [0:ENTRIES-1];
    reg [COUNT_WIDTH-1:0] spec_count;
    reg [ADDR_WIDTH-1:0] committed_stack [0:ENTRIES-1];
    reg [COUNT_WIDTH-1:0] committed_count;

    assign top_valid = spec_count != {COUNT_WIDTH{1'b0}};
    assign top_addr = spec_stack[0];

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            spec_count <= {COUNT_WIDTH{1'b0}};
            committed_count <= {COUNT_WIDTH{1'b0}};
        end else begin
            case ({commit_push, commit_pop})
                2'b10: begin
                    for (i = ENTRIES - 1; i > 0; i = i - 1) begin
                        committed_stack[i] <= committed_stack[i - 1];
                    end
                    committed_stack[0] <= commit_addr;
                    if (committed_count != ENTRY_COUNT) begin
                        committed_count <= committed_count + 1'b1;
                    end
                end
                2'b01: begin
                    if (committed_count != {COUNT_WIDTH{1'b0}}) begin
                        for (i = 0; i < ENTRIES - 1; i = i + 1) begin
                            committed_stack[i] <= committed_stack[i + 1];
                        end
                        committed_count <= committed_count - 1'b1;
                    end
                end
                2'b11: begin
                    committed_stack[0] <= commit_addr;
                    if (committed_count == {COUNT_WIDTH{1'b0}}) begin
                        committed_count <= {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
                    end
                end
                default: begin
                    committed_count <= committed_count;
                end
            endcase

            // An architectural redirect discards all younger speculative
            // calls/returns.  Include a same-cycle committed action so the
            // redirecting call/return itself is retained in the restored RAS.
            if (restore) begin
                case ({commit_push, commit_pop})
                    2'b10: begin
                        for (i = ENTRIES - 1; i > 0; i = i - 1) begin
                            spec_stack[i] <= committed_stack[i - 1];
                        end
                        spec_stack[0] <= commit_addr;
                        spec_count <= (committed_count == ENTRY_COUNT) ?
                            committed_count : committed_count + 1'b1;
                    end
                    2'b01: begin
                        if (committed_count != {COUNT_WIDTH{1'b0}}) begin
                            for (i = 0; i < ENTRIES - 1; i = i + 1) begin
                                spec_stack[i] <= committed_stack[i + 1];
                            end
                            spec_count <= committed_count - 1'b1;
                        end else begin
                            spec_count <= {COUNT_WIDTH{1'b0}};
                        end
                    end
                    2'b11: begin
                        spec_stack[0] <= commit_addr;
                        for (i = 1; i < ENTRIES; i = i + 1) begin
                            spec_stack[i] <= committed_stack[i];
                        end
                        spec_count <= (committed_count == 0) ?
                            {{(COUNT_WIDTH-1){1'b0}}, 1'b1} : committed_count;
                    end
                    default: begin
                        for (i = 0; i < ENTRIES; i = i + 1) begin
                            spec_stack[i] <= committed_stack[i];
                        end
                        spec_count <= committed_count;
                    end
                endcase
            end else begin
                case ({spec_push, spec_pop})
                    2'b10: begin
                        for (i = ENTRIES - 1; i > 0; i = i - 1) begin
                            spec_stack[i] <= spec_stack[i - 1];
                        end
                        spec_stack[0] <= spec_addr;
                        if (spec_count != ENTRY_COUNT) begin
                            spec_count <= spec_count + 1'b1;
                        end
                    end
                    2'b01: begin
                        if (spec_count != {COUNT_WIDTH{1'b0}}) begin
                            for (i = 0; i < ENTRIES - 1; i = i + 1) begin
                                spec_stack[i] <= spec_stack[i + 1];
                            end
                            spec_count <= spec_count - 1'b1;
                        end
                    end
                    2'b11: begin
                        spec_stack[0] <= spec_addr;
                        if (spec_count == {COUNT_WIDTH{1'b0}}) begin
                            spec_count <= {{(COUNT_WIDTH-1){1'b0}}, 1'b1};
                        end
                    end
                    default: begin
                        spec_count <= spec_count;
                    end
                endcase
            end
        end
    end

endmodule
