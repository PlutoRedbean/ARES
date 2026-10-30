//=============================================================================
// ARES pipeline SoC - shared MMIO block for 2/4 harts
//-----------------------------------------------------------------------------
// One request port per hart, round-robin arbitration, one outstanding MMIO
// operation.  The block owns the devices that are naturally shared:
//
//   0xA000_0FF0  RO  hart id of the requesting hart
//   0xA000_0FF4  RO  configured hart count
//   0xA000_0050  RO  cycle counter [31:0]
//   0xA000_0054  RO  cycle counter [63:32]
//   0xA000_03F8  WO  UART TX byte
//   0xA000_03FC  RO  UART status, bit0 = tx_busy
//   0x8020_0060  WO  jyd-compatible UART TX alias
//   0x8020_0064  RO  jyd-compatible UART status alias
//   0x8020_0040  RW  LED register
//
// The request is latched before decode.  Reads return through a registered
// response phase; writes use a one-cycle commit phase so mmio_idle stays low
// until the side effect has been issued.  There is no wide combinational path
// from the hart ports to the UART or the cycle counter.
//=============================================================================
module pipeline_mmio #(
    parameter integer CORES      = 2,
    parameter integer HART_ID    = 0,
    parameter integer CORE_COUNT = 2,
    parameter integer CLK_HZ     = 100_000_000,
    parameter integer UART_BAUD  = 115_200
) (
    input  wire                     clk,
    input  wire                     rst,

    input  wire [CORES-1:0]         req_valid,
    output wire [CORES-1:0]         req_ready,
    input  wire [CORES-1:0]         req_write,
    input  wire [CORES-1:0][31:0]   req_addr,
    input  wire [CORES-1:0][31:0]   req_wdata,
    input  wire [CORES-1:0][ 3:0]   req_wstrb,

    output wire [CORES-1:0]         rsp_valid,
    input  wire [CORES-1:0]         rsp_ready,
    output wire [CORES-1:0][31:0]   rsp_data,

    output wire                     mmio_idle,
    output wire                     uart_tx,
    output wire [31:0]              led
);
    localparam integer CORE_W   = (CORES > 1) ? $clog2(CORES) : 1;
    localparam integer CORE_MSK = CORES - 1;
    localparam [31:0]   HART_ID_C = HART_ID;
    localparam [31:0]   CORE_CNT_C = CORE_COUNT;

    localparam [31:0] HART_ID_ADDR   = 32'hA000_0FF0;
    localparam [31:0] HART_CNT_ADDR  = 32'hA000_0FF4;
    localparam [31:0] CYCLE_LO_ADDR  = 32'hA000_0050;
    localparam [31:0] CYCLE_HI_ADDR  = 32'hA000_0054;
    localparam [31:0] UART_TX_ADDR   = 32'hA000_03F8;
    localparam [31:0] UART_ST_ADDR   = 32'hA000_03FC;
    localparam [31:0] JYD_UART_TX    = 32'h8020_0060;
    localparam [31:0] JYD_UART_ST    = 32'h8020_0064;
    localparam [31:0] LED_ADDR       = 32'h8020_0040;

    typedef enum logic [1:0] {
        S_IDLE,
        S_WRITE,
        S_RSP1,
        S_RSP
    } state_t;

    state_t state_q;

    reg [CORE_W-1:0] rr_ptr;

    function automatic [CORES-1:0] onehot(input [CORE_W-1:0] idx);
        integer j;
        begin
            onehot = {CORES{1'b0}};
            for (j = 0; j < CORES; j = j + 1) begin
                if (idx == j[CORE_W-1:0]) onehot[j] = 1'b1;
            end
        end
    endfunction

    // ---- arbitration ------------------------------------------------------
    logic [CORE_W-1:0] sel_core;
    logic              sel_write;
    logic              req_any;
    logic              uart_busy_blk;
    logic              accept;
    integer            a;

    // UART can only accept a new byte when idle.  The comparison is a small
    // 32-bit equality on the selected request, not a data path through UART.
    wire sel_uart_write =
        (req_addr[sel_core] == UART_TX_ADDR) ||
        (req_addr[sel_core] == JYD_UART_TX);

    always @(*) begin
        req_any   = 1'b0;
        sel_core  = {CORE_W{1'b0}};
        sel_write = 1'b0;
        for (a = 0; a < CORES; a = a + 1) begin
            if (!req_any) begin
                if (req_valid[CORE_W'((rr_ptr + a) & CORE_MSK)]) begin
                    req_any   = 1'b1;
                    sel_core  = CORE_W'((rr_ptr + a) & CORE_MSK);
                    sel_write = req_write[CORE_W'((rr_ptr + a) & CORE_MSK)];
                end
            end
        end
    end

    assign accept = (state_q == S_IDLE) && req_any &&
                    !(sel_write && sel_uart_write && uart_busy_blk);

    assign req_ready = accept ? onehot(sel_core) : {CORES{1'b0}};

    // ---- latched request --------------------------------------------------
    reg [31:0]       req_addr_q;
    reg [31:0]       req_wdata_q;

    // ---- cycle counter / UART / LED --------------------------------------
    reg [63:0] cycle_count;
    reg [31:0] led_q;
    reg        tx_start_q;
    reg [ 7:0] tx_data_q;
    wire       tx_busy;
    wire [ 7:0] rx_data_unused;
    wire       rx_ready_unused;

    assign uart_busy_blk = tx_busy;

    uart #(
        .CLK_FREQ (CLK_HZ),
        .BAUD_RATE(UART_BAUD)
    ) u_uart (
        .clk      (clk),
        .rst_n    (~rst),
        .rx       (1'b1),
        .rx_data  (rx_data_unused),
        .rx_ready (rx_ready_unused),
        .tx       (uart_tx),
        .tx_data  (tx_data_q),
        .tx_start (tx_start_q),
        .tx_busy  (tx_busy)
    );

    // ---- response source --------------------------------------------------
    function automatic [31:0] read_data(input [31:0] addr,
                                        input [31:0] led_value,
                                        input        busy,
                                        input [63:0] cycles);
        begin
            if (addr == HART_ID_ADDR) begin
                read_data = HART_ID_C;
            end else if (addr == HART_CNT_ADDR) begin
                read_data = CORE_CNT_C;
            end else if (addr == CYCLE_LO_ADDR) begin
                read_data = cycles[31:0];
            end else if (addr == CYCLE_HI_ADDR) begin
                read_data = cycles[63:32];
            end else if ((addr == UART_ST_ADDR) || (addr == JYD_UART_ST)) begin
                read_data = {31'd0, busy};
            end else if (addr == LED_ADDR) begin
                read_data = led_value;
            end else begin
                read_data = 32'd0;
            end
        end
    endfunction

    reg              rsp_valid_q;
    reg [CORE_W-1:0] rsp_core_q;
    reg [31:0]       rsp_data_q;

    assign rsp_valid = rsp_valid_q ? onehot(rsp_core_q) : {CORES{1'b0}};
    genvar g;
    generate
        for (g = 0; g < CORES; g = g + 1) begin : g_rsp_data
            assign rsp_data[g] = rsp_data_q;
        end
    endgenerate

    wire selected_rsp_ready = rsp_ready[rsp_core_q];
    // Idle means this block has finished its current operation.  It is a
    // per-block completion signal, not "no hart is requesting": a hart that
    // is spinning on a UART busy flag must not hold another hart's FENCE
    // hostage (that would be a cross-hart livelock).
    assign mmio_idle = (state_q == S_IDLE);

    always @(posedge clk) begin
        if (rst) begin
            state_q     <= S_IDLE;
            rr_ptr      <= {CORE_W{1'b0}};
            req_addr_q  <= 32'd0;
            req_wdata_q <= 32'd0;
            cycle_count <= 64'd0;
            led_q       <= 32'd0;
            tx_start_q  <= 1'b0;
            tx_data_q   <= 8'd0;
            rsp_valid_q <= 1'b0;
            rsp_core_q  <= {CORE_W{1'b0}};
            rsp_data_q  <= 32'd0;
        end else begin
            cycle_count <= cycle_count + 64'd1;
            tx_start_q  <= 1'b0;

            case (state_q)
                S_IDLE: begin
                    if (accept) begin
                        req_addr_q  <= req_addr[sel_core];
                        req_wdata_q <= req_wdata[sel_core];
                        rr_ptr      <= CORE_W'((sel_core + 1'b1) & CORE_MSK);

                        if (sel_write) begin
                            state_q <= S_WRITE;
                        end else begin
                            // The pipeline core's perip timing assumes a
                            // response two cycles after the request handshake
                            // (the single-hart bridge has one BRAM output
                            // register).  S_RSP1 provides that extra stage.
                            rsp_core_q  <= sel_core;
                            rsp_data_q  <= read_data(req_addr[sel_core],
                                                     led_q, tx_busy,
                                                     cycle_count);
                            state_q     <= S_RSP1;
                        end
                    end
                end

                S_WRITE: begin
                    // Commit the latched write exactly once.  The UART start
                    // pulse is issued here, one cycle after the CPU handshake.
                    if ((req_addr_q == UART_TX_ADDR) ||
                        (req_addr_q == JYD_UART_TX)) begin
                        tx_data_q  <= req_wdata_q[7:0];
                        tx_start_q <= 1'b1;
`ifdef __VERILATOR__
                        $write("%c", req_wdata_q[7:0]);
`endif
                    end else if (req_addr_q == LED_ADDR) begin
                        led_q <= req_wdata_q;
                    end
                    state_q <= S_IDLE;
                end

                S_RSP1: begin
                    rsp_valid_q <= 1'b1;
                    state_q     <= S_RSP;
                end

                S_RSP: begin
                    if (rsp_valid_q && selected_rsp_ready) begin
                        rsp_valid_q <= 1'b0;
                        state_q     <= S_IDLE;
                    end
                end

                default: state_q <= S_IDLE;
            endcase
        end
    end

    assign led = led_q;

endmodule
