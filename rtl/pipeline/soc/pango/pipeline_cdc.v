//=============================================================================
// ARES pipeline SoC - tool-neutral clock-domain-crossing library
//-----------------------------------------------------------------------------
// The imported jyd SoC used Xilinx XPM macros (xpm_cdc_single / array_single /
// gray / handshake).  Pango PDS has no Xilinx primitive library, so this file
// implements the same CDC policies in plain Verilog-2001:
//
//   pipeline_cdc_single       1-bit level, N-stage synchronizer
//   pipeline_cdc_array_single bitwise-independent bus, N-stage synchronizer
//   pipeline_cdc_gray         monotonic multi-bit bus, gray-code synchronizer
//   pipeline_cdc_mailbox      coherent snapshot, 4-phase bundled-data handshake
//   pipeline_cdc_reset_sync   async assert / sync release reset synchronizer
//
// The mailbox data path is bundled: src_data is captured by the source domain
// and held stable for at least DEST_SYNC_FF destination cycles before the
// destination observes the request, so no per-bit synchronizer is needed on
// the payload.  Do not use it for streaming data; it is a config/status path.
//=============================================================================
`timescale 1ns / 1ps

//-----------------------------------------------------------------------------
// 1-bit level synchronizer.
//-----------------------------------------------------------------------------
module pipeline_cdc_single #(
    parameter integer DEST_SYNC_FF  = 2,
    parameter integer INIT_SYNC_FF  = 0,
    parameter integer SRC_INPUT_REG = 1
) (
    input  wire src_clk,
    input  wire src_in,
    input  wire dest_clk,
    output wire dest_out
);
    localparam integer N = (DEST_SYNC_FF < 1) ? 1 : DEST_SYNC_FF;

    reg              src_reg;
    wire             src_sig;
    reg  [N-1:0]     sync_ff;
    integer          i_init;
    integer          i_sync;

    initial begin
        src_reg = 1'b0;
        for (i_init = 0; i_init < N; i_init = i_init + 1) begin
            sync_ff[i_init] = 1'b0;
        end
    end

    generate
        if (SRC_INPUT_REG != 0) begin : g_src_reg
            always @(posedge src_clk) begin
                src_reg <= src_in;
            end
            assign src_sig = src_reg;
        end else begin : g_src_direct
            assign src_sig = src_in;
        end
    endgenerate

    always @(posedge dest_clk) begin
        sync_ff[0] <= src_sig;
        for (i_sync = 1; i_sync < N; i_sync = i_sync + 1) begin
            sync_ff[i_sync] <= sync_ff[i_sync-1];
        end
    end

    assign dest_out = sync_ff[N-1];
endmodule

//-----------------------------------------------------------------------------
// Bitwise-independent bus synchronizer.
// Each bit must be a stable level (switch/key style); the bus is not atomic.
//-----------------------------------------------------------------------------
module pipeline_cdc_array_single #(
    parameter integer WIDTH         = 1,
    parameter integer DEST_SYNC_FF  = 2,
    parameter integer INIT_SYNC_FF  = 0,
    parameter integer SRC_INPUT_REG = 1
) (
    input  wire             src_clk,
    input  wire [WIDTH-1:0] src_in,
    input  wire             dest_clk,
    output wire [WIDTH-1:0] dest_out
);
    localparam integer N = (DEST_SYNC_FF < 1) ? 1 : DEST_SYNC_FF;

    reg  [WIDTH-1:0] src_reg;
    wire [WIDTH-1:0] src_sig;
    reg  [WIDTH-1:0] sync_ff [0:N-1];
    integer          i_init;
    integer          i_sync;

    initial begin
        src_reg = {WIDTH{1'b0}};
        for (i_init = 0; i_init < N; i_init = i_init + 1) begin
            sync_ff[i_init] = {WIDTH{1'b0}};
        end
    end

    generate
        if (SRC_INPUT_REG != 0) begin : g_src_reg
            always @(posedge src_clk) begin
                src_reg <= src_in;
            end
            assign src_sig = src_reg;
        end else begin : g_src_direct
            assign src_sig = src_in;
        end
    endgenerate

    always @(posedge dest_clk) begin
        sync_ff[0] <= src_sig;
        for (i_sync = 1; i_sync < N; i_sync = i_sync + 1) begin
            sync_ff[i_sync] <= sync_ff[i_sync-1];
        end
    end

    assign dest_out = sync_ff[N-1];
endmodule

//-----------------------------------------------------------------------------
// Gray-code synchronizer for a monotonic multi-bit value.
// The source registers the gray word; the destination synchronizes it and
// converts back to binary.  Only safe when the source increments by one.
//-----------------------------------------------------------------------------
module pipeline_cdc_gray #(
    parameter integer WIDTH          = 2,
    parameter integer DEST_SYNC_FF   = 2,
    parameter integer INIT_SYNC_FF   = 0,
    parameter integer REG_OUTPUT     = 1
) (
    input  wire             src_clk,
    input  wire [WIDTH-1:0] src_in_bin,
    input  wire             dest_clk,
    output wire [WIDTH-1:0] dest_out_bin
);
    localparam integer N = (DEST_SYNC_FF < 1) ? 1 : DEST_SYNC_FF;

    reg  [WIDTH-1:0] src_gray;
    reg  [WIDTH-1:0] sync_gray [0:N-1];
    wire [WIDTH-1:0] bin_comb;
    reg  [WIDTH-1:0] bin_reg;
    integer          i_init;
    integer          i_sync;

    function [WIDTH-1:0] bin_to_gray;
        input [WIDTH-1:0] bin;
        begin
            bin_to_gray = bin ^ (bin >> 1);
        end
    endfunction

    function [WIDTH-1:0] gray_to_bin;
        input [WIDTH-1:0] gray;
        integer k;
        begin
            gray_to_bin[WIDTH-1] = gray[WIDTH-1];
            for (k = WIDTH-2; k >= 0; k = k - 1) begin
                gray_to_bin[k] = gray_to_bin[k+1] ^ gray[k];
            end
        end
    endfunction

    initial begin
        src_gray = {WIDTH{1'b0}};
        bin_reg  = {WIDTH{1'b0}};
        for (i_init = 0; i_init < N; i_init = i_init + 1) begin
            sync_gray[i_init] = {WIDTH{1'b0}};
        end
    end

    always @(posedge src_clk) begin
        src_gray <= bin_to_gray(src_in_bin);
    end

    always @(posedge dest_clk) begin
        sync_gray[0] <= src_gray;
        for (i_sync = 1; i_sync < N; i_sync = i_sync + 1) begin
            sync_gray[i_sync] <= sync_gray[i_sync-1];
        end
    end

    assign bin_comb = gray_to_bin(sync_gray[N-1]);

    generate
        if (REG_OUTPUT != 0) begin : g_reg_output
            always @(posedge dest_clk) begin
                bin_reg <= bin_comb;
            end
            assign dest_out_bin = bin_reg;
        end else begin : g_comb_output
            assign dest_out_bin = bin_comb;
        end
    endgenerate
endmodule

//-----------------------------------------------------------------------------
// Coherent multi-bit snapshot transfer.
// Four-phase bundled-data handshake; the source keeps only the latest pending
// value while a transfer is in flight.
//-----------------------------------------------------------------------------
module pipeline_cdc_mailbox #(
    parameter integer WIDTH         = 1,
    parameter integer DEST_SYNC_FF  = 2,
    parameter integer SRC_SYNC_FF   = 2,
    parameter integer INIT_SYNC_FF  = 0
) (
    input  wire             src_clk,
    input  wire             src_rst,
    input  wire [WIDTH-1:0] src_data,
    input  wire             src_valid,
    output wire             src_busy,

    input  wire             dest_clk,
    input  wire             dest_rst,
    output wire [WIDTH-1:0] dest_data,
    output wire             dest_valid
);
    localparam integer SN = (SRC_SYNC_FF  < 1) ? 1 : SRC_SYNC_FF;
    localparam integer DN = (DEST_SYNC_FF < 1) ? 1 : DEST_SYNC_FF;

    localparam [1:0] S_IDLE         = 2'd0;
    localparam [1:0] S_SEND         = 2'd1;
    localparam [1:0] S_WAIT_ACK_LOW = 2'd2;

    reg  [1:0]       state;
    reg  [WIDTH-1:0] active_data;
    reg  [WIDTH-1:0] pending_data;
    reg              pending_valid;
    reg              src_req;
    reg  [SN-1:0]    ack_sync;

    reg  [DN-1:0]    req_sync;
    reg              dest_ack;
    reg  [WIDTH-1:0] dest_data_r;
    reg              dest_valid_r;

    integer          i_src;
    integer          i_dest;

    initial begin
        state         = S_IDLE;
        active_data   = {WIDTH{1'b0}};
        pending_data  = {WIDTH{1'b0}};
        pending_valid = 1'b0;
        src_req       = 1'b0;
        ack_sync      = {SN{1'b0}};
        req_sync      = {DN{1'b0}};
        dest_ack      = 1'b0;
        dest_data_r   = {WIDTH{1'b0}};
        dest_valid_r  = 1'b0;
    end

    // Source: latch data, raise the request, hold until the synchronized
    // destination acknowledge returns, then lower the request (4-phase).
    always @(posedge src_clk) begin
        if (src_rst) begin
            state         <= S_IDLE;
            active_data   <= {WIDTH{1'b0}};
            pending_data  <= {WIDTH{1'b0}};
            pending_valid <= 1'b0;
            src_req       <= 1'b0;
            ack_sync      <= {SN{1'b0}};
        end else begin
            ack_sync[0] <= dest_ack;
            for (i_src = 1; i_src < SN; i_src = i_src + 1) begin
                ack_sync[i_src] <= ack_sync[i_src-1];
            end

            if (src_valid) begin
                pending_data  <= src_data;
                pending_valid <= 1'b1;
            end

            case (state)
                S_IDLE: begin
                    if (src_valid) begin
                        active_data   <= src_data;
                        pending_valid <= 1'b0;
                        src_req       <= 1'b1;
                        state         <= S_SEND;
                    end else if (pending_valid) begin
                        active_data   <= pending_data;
                        pending_valid <= 1'b0;
                        src_req       <= 1'b1;
                        state         <= S_SEND;
                    end
                end

                S_SEND: begin
                    if (ack_sync[SN-1]) begin
                        src_req <= 1'b0;
                        state   <= S_WAIT_ACK_LOW;
                    end
                end

                S_WAIT_ACK_LOW: begin
                    if (!ack_sync[SN-1]) begin
                        state <= S_IDLE;
                    end
                end

                default: begin
                    state   <= S_IDLE;
                    src_req <= 1'b0;
                end
            endcase
        end
    end

    assign src_busy = (state != S_IDLE) || pending_valid;

    // Destination: synchronize the request, acknowledge it while asserted,
    // and pulse dest_valid on the rising edge with the held payload.
    always @(posedge dest_clk) begin
        if (dest_rst) begin
            req_sync     <= {DN{1'b0}};
            dest_ack     <= 1'b0;
            dest_data_r  <= {WIDTH{1'b0}};
            dest_valid_r <= 1'b0;
        end else begin
            req_sync[0] <= src_req;
            for (i_dest = 1; i_dest < DN; i_dest = i_dest + 1) begin
                req_sync[i_dest] <= req_sync[i_dest-1];
            end

            dest_ack <= req_sync[DN-1];

            if (req_sync[DN-1] && !dest_ack) begin
                dest_data_r  <= active_data;
                dest_valid_r <= 1'b1;
            end else begin
                dest_valid_r <= 1'b0;
            end
        end
    end

    assign dest_data  = dest_data_r;
    assign dest_valid = dest_valid_r;
endmodule

//-----------------------------------------------------------------------------
// Async assert / synchronous release reset synchronizer.
// rst_in high asserts rst_out immediately; release takes two clocks.
//-----------------------------------------------------------------------------
module pipeline_cdc_reset_sync (
    input  wire clk,
    input  wire rst_in,
    output wire rst_out
);
    reg [1:0] sync;

    initial begin
        sync = 2'b11;
    end

    always @(posedge clk or posedge rst_in) begin
        if (rst_in) begin
            sync <= 2'b11;
        end else begin
            sync <= {sync[0], 1'b0};
        end
    end

    assign rst_out = sync[1];
endmodule
