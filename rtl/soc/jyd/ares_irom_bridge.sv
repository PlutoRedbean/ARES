// Read-only AXI-Lite -> registered 64-bit JYD IROM. One outstanding word.
module ares_irom_bridge (
    input logic clk, rst,
    axi_if.slave bus,
    output logic [31:0] irom_addr,
    input logic [63:0] irom_data
);
    typedef enum logic [1:0] {IDLE, ROM_WAIT, RESPONSE} state_t;
    state_t state;
    logic high_word, address_error;
    logic [31:0] data_q;
    assign bus.arready = !rst && state == IDLE;
    assign irom_addr = {bus.araddr[31:3],3'b000};
    assign bus.rvalid = !rst && state == RESPONSE;
    assign bus.rdata = data_q;
    assign bus.rresp = address_error;
    // No writes are accepted on the instruction port.
    assign bus.awready = 1'b0;
    assign bus.wready = 1'b0;
    assign bus.bvalid = 1'b0;
    assign bus.bresp = 1'b0;
    always_ff @(posedge clk) begin
        if (rst) begin state<=IDLE; high_word<=0; address_error<=0; data_q<=0; end
        else case (state)
            IDLE: if (bus.arvalid && bus.arready) begin
                high_word <= bus.araddr[2];
                address_error <= bus.araddr < 32'h8000_0000 || bus.araddr >= 32'h8000_8000 || bus.araddr[1:0] != 0;
                state <= ROM_WAIT;
            end
            ROM_WAIT: begin
                data_q <= address_error ? 32'd0 : (high_word ? irom_data[63:32] : irom_data[31:0]);
                state <= RESPONSE;
            end
            RESPONSE: if (bus.rready) state <= IDLE;
            default: state <= IDLE;
        endcase
    end
endmodule
