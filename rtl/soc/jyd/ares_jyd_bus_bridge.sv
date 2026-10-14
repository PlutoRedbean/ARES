// ARES 16B memory beats / MMIO -> JYD 32-bit peripheral port.
// Four accepted write beats are retained until every enabled byte is handed
// to the peripheral bridge. Reads and MMIO wait for older writes to drain.
// This is the board-specific width converter, not an LSU latency change.
module ares_jyd_bus_bridge (
    input logic clk, rst,
    input logic mem_rd_valid,
    output logic mem_rd_ready,
    input logic [31:0] mem_rd_addr,
    output logic mem_rsp_valid,
    input logic mem_rsp_ready,
    output logic [127:0] mem_rsp_data,
    input logic mem_wr_valid,
    output logic mem_wr_ready,
    input logic [31:0] mem_wr_addr,
    input logic [127:0] mem_wr_data,
    input logic [15:0] mem_wr_be,
    input logic mmio_req_valid,
    output logic mmio_req_ready,
    input logic mmio_write,
    /* verilator lint_off UNUSEDSIGNAL */ // device accesses use aligned word + byte strobes
    input logic [31:0] mmio_addr, mmio_wdata,
    /* verilator lint_on UNUSEDSIGNAL */
    input logic [3:0] mmio_wstrb,
    output logic mmio_rsp_valid,
    input logic mmio_rsp_ready,
    output logic [31:0] mmio_rsp_data,
    output logic perip_valid,
    input logic perip_ready, perip_rvalid, perip_order_idle,
    output logic perip_wen,
    output logic [31:0] perip_addr, perip_wdata,
    output logic [3:0] perip_wstrb,
    input logic [31:0] perip_rdata
);
    typedef enum logic [3:0] {
        IDLE, WRITE_WORD, READ_WORD, READ_WAIT, READ_RESP,
        MMIO_SEND, MMIO_WAIT, MMIO_ACK, MMIO_RESP
    } state_t;
    state_t state;
    logic [31:0] wr_addr [4];
    logic [127:0] wr_data [4];
    logic [15:0] wr_be [4];
    logic [1:0] head, tail, word_idx;
    logic [2:0] count;
    logic [31:0] rd_addr, device_addr, device_data;
    logic [3:0] device_be;
    logic device_write;
    wire device_active = state >= MMIO_SEND;
    wire push = mem_wr_valid && mem_wr_ready;
    wire word_done = !(|wr_be[head][word_idx*4 +: 4]) || perip_ready;
    wire pop = state == WRITE_WORD && word_idx == 2'd3 && word_done;
    wire perip_fire = perip_valid && perip_ready;

    assign mem_wr_ready = !rst && count < 3'd4 && !device_active &&
                          !mmio_req_valid && !mem_rd_valid;
    assign mmio_req_ready = !rst && state == IDLE && count == 0 &&
                            perip_order_idle;
    assign mem_rd_ready = mmio_req_ready && !mmio_req_valid;
    assign mem_rsp_valid = state == READ_RESP;
    assign mmio_rsp_valid = state == MMIO_RESP;

    always_comb begin
        perip_valid = 1'b0;
        perip_wen = 1'b0;
        perip_addr = 32'd0;
        perip_wdata = 32'd0;
        perip_wstrb = 4'd0;
        case (state)
            WRITE_WORD: begin
                perip_valid = |wr_be[head][word_idx*4 +: 4];
                perip_wen = 1'b1;
                perip_addr = wr_addr[head] + {28'd0, word_idx, 2'b00};
                perip_wdata = wr_data[head][word_idx*32 +: 32];
                perip_wstrb = wr_be[head][word_idx*4 +: 4];
            end
            READ_WORD: begin
                perip_valid = 1'b1;
                perip_addr = rd_addr + {28'd0, word_idx, 2'b00};
            end
            MMIO_SEND: begin
                perip_valid = 1'b1;
                perip_wen = device_write;
                perip_addr = device_addr;
                perip_wdata = device_data;
                perip_wstrb = device_be;
            end
            default: ;
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            head <= 0;
            tail <= 0;
            count <= 0;
            word_idx <= 0;
            rd_addr <= 0;
            device_addr <= 0;
            device_data <= 0;
            device_be <= 0;
            device_write <= 0;
            mem_rsp_data <= 0;
            mmio_rsp_data <= 0;
        end else begin
            if (push) begin
                wr_addr[tail] <= mem_wr_addr;
                wr_data[tail] <= mem_wr_data;
                wr_be[tail] <= mem_wr_be;
                tail <= tail + 1'b1;
            end
            if (pop) head <= head + 1'b1;
            case ({push, pop})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: ;
            endcase
            case (state)
                IDLE: begin
                    word_idx <= 0;
                    if (count != 0) state <= WRITE_WORD;
                    else if (mmio_req_valid && mmio_req_ready) begin
                        device_addr <= {mmio_addr[31:2], 2'b00};
                        device_data <= mmio_wdata;
                        device_be <= mmio_wstrb;
                        device_write <= mmio_write;
                        state <= MMIO_SEND;
                    end else if (mem_rd_valid && mem_rd_ready) begin
                        rd_addr <= mem_rd_addr;
                        mem_rsp_data <= 0;
                        state <= READ_WORD;
                    end
                end
                WRITE_WORD: if (word_done) begin
                    word_idx <= word_idx + 1'b1;
                    if (word_idx == 2'd3) state <= IDLE;
                end
                READ_WORD: if (perip_fire) state <= READ_WAIT;
                READ_WAIT: if (perip_rvalid) begin
                    mem_rsp_data[word_idx*32 +: 32] <= perip_rdata;
                    word_idx <= word_idx + 1'b1;
                    state <= word_idx == 2'd3 ? READ_RESP : READ_WORD;
                end
                READ_RESP: if (mem_rsp_ready) state <= IDLE;
                MMIO_SEND: if (perip_fire) state <= device_write ? MMIO_ACK : MMIO_WAIT;
                MMIO_WAIT: if (perip_rvalid) begin
                    mmio_rsp_data <= perip_rdata;
                    state <= MMIO_RESP;
                end
                MMIO_ACK: if (perip_order_idle) begin
                    mmio_rsp_data <= 0;
                    state <= MMIO_RESP;
                end
                MMIO_RESP: if (mmio_rsp_ready) state <= IDLE;
                default: state <= IDLE;
            endcase
        end
    end
`ifdef CONFIG_SIMULATION
    assert property (@(posedge clk) disable iff (rst) count <= 4);
    assert property (@(posedge clk) disable iff (rst)
        mem_wr_valid && mem_wr_ready |-> mem_wr_addr[3:0] == 0);
    assert property (@(posedge clk) disable iff (rst)
        mem_rd_valid && mem_rd_ready |-> mem_rd_addr[3:0] == 0);
    assert property (@(posedge clk) disable iff (rst)
        mem_rsp_valid && !mem_rsp_ready |=> rst ||
        (mem_rsp_valid && $stable(mem_rsp_data)));
    assert property (@(posedge clk) disable iff (rst)
        mmio_rsp_valid && !mmio_rsp_ready |=> rst ||
        (mmio_rsp_valid && $stable(mmio_rsp_data)));
    assert property (@(posedge clk) disable iff (rst)
        perip_valid && !perip_ready |=> rst ||
        (perip_valid && $stable({perip_addr, perip_wen, perip_wdata, perip_wstrb})));
`endif
endmodule
