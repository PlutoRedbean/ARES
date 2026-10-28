//=============================================================================
// ARES board top - Pangu 200Pro+ (PG2L200H-6IFBB676), 27 MHz, no PLL
//-----------------------------------------------------------------------------
// Contents
//   * 27 MHz oscillator -> reset synchroniser + power-on counter
//   * ares_2core_frontend_l2_top (two real frontends + shared 32 KiB L2)
//   * 48 KiB L2 backing memory (BRAM inferred from the $readmemh image)
//   * board console: MMIO stores to 0xA000_03F8 are buffered into a UART TX
//   * status LEDs
//
// Memory map (must match tests/abstract-machine/scripts/ares-board-linker.ld
// and scripts/build_coremark_image.py --board):
//
//   0x8000_0000  16 KiB  .boot/.text/.rodata   (both harts)
//   0x8000_4000  16 KiB  .data/.bss/stack      (hart0)
//   0x8000_8000  16 KiB  hart1 copy            (C1_DATA_OFFSET = 0x4000)
//   0x8000_c000          end of backing window (48 KiB)
//
// The image is loaded at configuration time, so boot copies nothing:
// _fsbl() only clears .bss.  Addresses outside the 48 KiB window read as zero
// and ignore writes (this image never issues them).
//
// MMIO: ares_frontend_hart acknowledges the core's mmio_* channel immediately;
// this top only observes the requests.  The UART TX FIFO (1 KiB) absorbs a
// whole CoreMark result block, so no back-pressure is needed.
//
// Pin map: fpga/pango/ares_2core.fdc (from 5-stage-baseline board_pinmap.md).
//=============================================================================
/* verilator lint_off UNUSEDSIGNAL */ // uart_rx is observed only by an LED
module ares_pango_board #(
    parameter int unsigned UART_DIV   = 234,            // 27 MHz / 115200 baud
    parameter int unsigned MEM_WORDS  = 3072,           // 48 KiB / 16 B beats
    parameter              IMAGE_FILE = "coremark_board.hex"
) (
    input  logic       clk,        // 27 MHz oscillator (D18)
    input  logic       rst_n,      // reset push button, active low (C22)
    input  logic       uart_rx,    // USB-UART bridge TX (B24)
    output logic       uart_tx,    // USB-UART bridge RX (C24)
    output logic [7:0] led,        // B17 C17 A18 A17 E18 C19 C18 A20

    //---- verification observation (simulation gate; unconnected on board) ---
    // a0 at the EBREAK of hart0/hart1 plus sticky halt flags, matching the AM
    // halt(code) convention: a0 == 0 means the payload passed.
    output logic [31:0] o_c0_a0,
    output logic [31:0] o_c1_a0,
    output logic        o_c0_done,
    output logic        o_c1_done
);
    //---------------------------------------------------------------- clock/reset
    logic [1:0]  rst_sync_q;
    logic [15:0] por_cnt;
    logic        por_done;
    logic        rst;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rst_sync_q <= 2'b00;
            por_cnt    <= 16'd0;
            por_done   <= 1'b0;
        end else begin
            rst_sync_q <= {rst_sync_q[0], 1'b1};
            if (!por_done) begin
                if (por_cnt == 16'hffff) por_done <= 1'b1;
                else                     por_cnt  <= por_cnt + 16'd1;
            end
        end
    end
    assign rst = !(rst_sync_q[1] && por_done);

    //-------------------------------------------------------------- L2 SoC
    logic         l2_mem_rd_valid, l2_mem_rd_ready;
    logic [ 31:0] l2_mem_rd_addr;
    logic         l2_mem_rsp_valid, l2_mem_rsp_ready;
    logic [127:0] l2_mem_rsp_data;
    logic         l2_mem_wr_valid, l2_mem_wr_ready;
    logic [ 31:0] l2_mem_wr_addr;
    logic [127:0] l2_mem_wr_data;
    logic [ 15:0] l2_mem_wr_be;

    logic [31:0] c0_fetch_pc, c1_fetch_pc;
    logic [ 1:0] c0_retire_valid, c1_retire_valid;
    logic [ 1:0] c0_retire_rd_wen, c1_retire_rd_wen;
    logic [ 4:0] c0_retire_rd [2];
    logic [ 4:0] c1_retire_rd [2];
    logic [31:0] c0_retire_wdata [2];
    logic [31:0] c1_retire_wdata [2];
    logic [31:0] c0_retire_pc [2];
    logic [31:0] c1_retire_pc [2];
    logic [ 1:0] c0_retire_is_ebreak, c1_retire_is_ebreak;
    logic        l2_idle;
    logic [31:0] l2_hit_count, l2_miss_count;

    // MMIO request observation (outputs of ares_frontend_hart).
    logic        c0_mmio_req_valid, c0_mmio_write;
    logic [31:0] c0_mmio_addr, c0_mmio_wdata;
    logic [ 3:0] c0_mmio_wstrb;
    logic        c1_mmio_req_valid, c1_mmio_write;
    logic [31:0] c1_mmio_addr, c1_mmio_wdata;
    logic [ 3:0] c1_mmio_wstrb;

    ares_2core_frontend_l2_top #(
        .RESET_MTVEC    (ares_pkg::RESET_PC),
        .RESET_VEC      (ares_pkg::RESET_PC),
        .L2_SETS        (128),
        .C1_DATA_OFFSET (32'h0000_4000),
        .HART1_ENABLE   (1'b1)
    ) u_soc (
        .clk(clk), .rst(rst), .hart1_en(1'b1),
        .l2_mem_rd_valid(l2_mem_rd_valid), .l2_mem_rd_ready(l2_mem_rd_ready),
        .l2_mem_rd_addr(l2_mem_rd_addr),
        .l2_mem_rsp_valid(l2_mem_rsp_valid), .l2_mem_rsp_ready(l2_mem_rsp_ready),
        .l2_mem_rsp_data(l2_mem_rsp_data),
        .l2_mem_wr_valid(l2_mem_wr_valid), .l2_mem_wr_ready(l2_mem_wr_ready),
        .l2_mem_wr_addr(l2_mem_wr_addr), .l2_mem_wr_data(l2_mem_wr_data),
        .l2_mem_wr_be(l2_mem_wr_be),
        .c0_fetch_pc(c0_fetch_pc),
        .c0_retire_valid(c0_retire_valid), .c0_retire_rd_wen(c0_retire_rd_wen),
        .c0_retire_rd(c0_retire_rd), .c0_retire_wdata(c0_retire_wdata),
        .c0_retire_pc(c0_retire_pc), .c0_retire_is_ebreak(c0_retire_is_ebreak),
        .c1_fetch_pc(c1_fetch_pc),
        .c1_retire_valid(c1_retire_valid), .c1_retire_rd_wen(c1_retire_rd_wen),
        .c1_retire_rd(c1_retire_rd), .c1_retire_wdata(c1_retire_wdata),
        .c1_retire_pc(c1_retire_pc), .c1_retire_is_ebreak(c1_retire_is_ebreak),
        .l2_idle(l2_idle), .l2_hit_count(l2_hit_count), .l2_miss_count(l2_miss_count),
        .c0_mmio_req_valid(c0_mmio_req_valid), .c0_mmio_write(c0_mmio_write),
        .c0_mmio_addr(c0_mmio_addr), .c0_mmio_wdata(c0_mmio_wdata),
        .c0_mmio_wstrb(c0_mmio_wstrb),
        .c1_mmio_req_valid(c1_mmio_req_valid), .c1_mmio_write(c1_mmio_write),
        .c1_mmio_addr(c1_mmio_addr), .c1_mmio_wdata(c1_mmio_wdata),
        .c1_mmio_wstrb(c1_mmio_wstrb)
    );

    //----------------------------------------------------------- backing memory
    logic [127:0] mem [0:MEM_WORDS-1];
    logic         mem_rsp_valid_q;
    logic [127:0] mem_rsp_data_q;
    logic [11:0]  rd_index, wr_index;
    logic         rd_hit, wr_hit;

    initial $readmemh(IMAGE_FILE, mem);

    // 48 KiB window at 0x8000_0000: addr[31:16] == 16'h8000, word < 3072.
    assign rd_index = l2_mem_rd_addr[15:4];
    assign wr_index = l2_mem_wr_addr[15:4];
    assign rd_hit = (l2_mem_rd_addr[31:16] == 16'h8000) && (rd_index < MEM_WORDS[11:0]);
    assign wr_hit = (l2_mem_wr_addr[31:16] == 16'h8000) && (wr_index < MEM_WORDS[11:0]);

    assign l2_mem_rd_ready  = 1'b1;
    assign l2_mem_wr_ready  = 1'b1;
    assign l2_mem_rsp_valid = mem_rsp_valid_q;
    assign l2_mem_rsp_data  = mem_rsp_data_q;

    // One outstanding read, exactly like the L2 testbench memory model: the
    // response is held until the L2 accepts it.
    always_ff @(posedge clk) begin
        if (rst) begin
            mem_rsp_valid_q <= 1'b0;
            mem_rsp_data_q  <= 128'h0;
        end else if (l2_mem_rd_valid && l2_mem_rd_ready && !mem_rsp_valid_q) begin
            mem_rsp_valid_q <= 1'b1;
            mem_rsp_data_q  <= rd_hit ? mem[rd_index] : 128'h0;
        end else if (mem_rsp_valid_q && l2_mem_rsp_ready) begin
            mem_rsp_valid_q <= 1'b0;
        end
    end

    always_ff @(posedge clk) begin
        if (l2_mem_wr_valid && l2_mem_wr_ready && wr_hit) begin
            for (int i = 0; i < 16; i++)
                if (l2_mem_wr_be[i])
                    mem[wr_index][8*i +: 8] <= l2_mem_wr_data[8*i +: 8];
        end
    end

    //---------------------------------------------------------------- console
    localparam logic [31:0] CONSOLE_ADDR = 32'hA000_03F8;

    logic       con_c0, con_c1, uart_push;
    logic [7:0] uart_byte;
    logic       uart_busy, uart_overflow;

    assign con_c0 = c0_mmio_req_valid && c0_mmio_write && (c0_mmio_addr == CONSOLE_ADDR);
    assign con_c1 = c1_mmio_req_valid && c1_mmio_write && (c1_mmio_addr == CONSOLE_ADDR) && !con_c0;
    assign uart_push = con_c0 || con_c1;

    always_comb begin
        uart_byte = 8'h00;
        for (int i = 0; i < 4; i++) begin
            if (con_c0 && c0_mmio_wstrb[i]) uart_byte = c0_mmio_wdata[8*i +: 8];
            if (con_c1 && c1_mmio_wstrb[i]) uart_byte = c1_mmio_wdata[8*i +: 8];
        end
    end

    ares_board_uart_tx #(
        .DIV    (UART_DIV),
        .FIFO_AW(10)                 // 1 KiB: one CoreMark result block
    ) u_uart_tx (
        .clk(clk), .rst(rst),
        .push(uart_push), .data(uart_byte),
        .tx(uart_tx), .busy(uart_busy), .overflow(uart_overflow)
    );

    //----------------------------------------------------------- status LEDs
    logic [23:0] heartbeat_q;
    logic [ 1:0] uart_rx_sync;
    logic        c0_done_q, c1_done_q, console_seen_q, rx_seen_q, l2_busy_q;
    logic [31:0] a0_0_q, a0_1_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            heartbeat_q    <= 24'd0;
            uart_rx_sync   <= 2'b11;
            c0_done_q      <= 1'b0;
            c1_done_q      <= 1'b0;
            console_seen_q <= 1'b0;
            rx_seen_q      <= 1'b0;
            l2_busy_q      <= 1'b0;
            a0_0_q         <= 32'd0;
            a0_1_q         <= 32'd0;
        end else begin
            heartbeat_q  <= heartbeat_q + 24'd1;
            uart_rx_sync <= {uart_rx_sync[0], uart_rx};
            if (c0_retire_valid != 2'b00 && c0_retire_is_ebreak != 2'b00) c0_done_q <= 1'b1;
            if (c1_retire_valid != 2'b00 && c1_retire_is_ebreak != 2'b00) c1_done_q <= 1'b1;
            if (uart_push) console_seen_q <= 1'b1;
            if (uart_rx_sync[1] == 1'b0) rx_seen_q <= 1'b1;
            if (!l2_idle) l2_busy_q <= 1'b1;
            // Last architectural write to x10 per hart (a0 for halt(code)).
            if (c0_retire_valid[0] && c0_retire_rd_wen[0] && c0_retire_rd[0] == 5'd10)
                a0_0_q <= c0_retire_wdata[0];
            if (c0_retire_valid[1] && c0_retire_rd_wen[1] && c0_retire_rd[1] == 5'd10)
                a0_0_q <= c0_retire_wdata[1];
            if (c1_retire_valid[0] && c1_retire_rd_wen[0] && c1_retire_rd[0] == 5'd10)
                a0_1_q <= c1_retire_wdata[0];
            if (c1_retire_valid[1] && c1_retire_rd_wen[1] && c1_retire_rd[1] == 5'd10)
                a0_1_q <= c1_retire_wdata[1];
        end
    end

    assign o_c0_a0   = a0_0_q;
    assign o_c1_a0   = a0_1_q;
    assign o_c0_done = c0_done_q;
    assign o_c1_done = c1_done_q;

    // led[0] heartbeat      led[1] hart0 EBREAK (a0 checked by software)
    // led[2] hart1 EBREAK   led[3] UART busy
    // led[4] console store  led[5] UART FIFO overflow (sticky fault)
    // led[6] uart_rx seen   led[7] L2 traffic after reset
    assign led = {l2_busy_q, rx_seen_q, uart_overflow, console_seen_q,
                  uart_busy, c1_done_q, c0_done_q, heartbeat_q[23]};
endmodule
