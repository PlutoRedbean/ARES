`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// CDC helper library for Vivado XPM, no asynchronous FIFO.
//
// Use cases:
//   - cdc_single_xpm       : 1-bit level signal, 2-FF synchronizer through XPM.
//   - cdc_array_single_xpm : bitwise-independent multi-bit level signals.
//   - cdc_mailbox_xpm      : coherent multi-bit snapshot/config transfer.
//
// Notes:
//   1. xpm_cdc_array_single is only for buses whose bits are independent.
//      It does NOT guarantee that all bits are sampled from the same source cycle.
//   2. cdc_mailbox_xpm uses xpm_cdc_handshake and is intended for register/config
//      snapshots such as LED/SEG settings. If source writes again while a transfer
//      is busy, only the latest pending value is kept.
//////////////////////////////////////////////////////////////////////////////////

module cdc_single_xpm #(
    parameter integer DEST_SYNC_FF = 2,
    parameter integer INIT_SYNC_FF = 0
) (
    input  logic src_clk,
    input  logic src_in,
    input  logic dest_clk,
    output logic dest_out
);
    xpm_cdc_single #(
        .DEST_SYNC_FF   (DEST_SYNC_FF),
        .INIT_SYNC_FF   (INIT_SYNC_FF),
        .SIM_ASSERT_CHK (0),
        .SRC_INPUT_REG  (1)
    ) u_xpm_cdc_single (
        .src_clk  (src_clk),
        .src_in   (src_in),
        .dest_clk (dest_clk),
        .dest_out (dest_out)
    );
endmodule

module cdc_array_single_xpm #(
    parameter integer WIDTH        = 1,
    parameter integer DEST_SYNC_FF = 2,
    parameter integer INIT_SYNC_FF = 0
) (
    input  logic             src_clk,
    input  logic [WIDTH-1:0] src_in,
    input  logic             dest_clk,
    output logic [WIDTH-1:0] dest_out
);
    xpm_cdc_array_single #(
        .DEST_SYNC_FF   (DEST_SYNC_FF),
        .INIT_SYNC_FF   (INIT_SYNC_FF),
        .SIM_ASSERT_CHK (0),
        .SRC_INPUT_REG  (1),
        .WIDTH          (WIDTH)
    ) u_xpm_cdc_array_single (
        .src_clk  (src_clk),
        .src_in   (src_in),
        .dest_clk (dest_clk),
        .dest_out (dest_out)
    );
endmodule

module cdc_mailbox_xpm #(
    parameter integer WIDTH        = 1,
    parameter integer DEST_SYNC_FF = 2,
    parameter integer SRC_SYNC_FF  = 2,
    parameter integer INIT_SYNC_FF = 0
) (
    input  logic             src_clk,
    input  logic             src_rst,
    input  logic [WIDTH-1:0] src_data,
    input  logic             src_valid,
    output logic             src_busy,

    input  logic             dest_clk,
    input  logic             dest_rst,
    output logic [WIDTH-1:0] dest_data,
    output logic             dest_valid
);
    typedef enum logic [1:0] {
        S_IDLE,
        S_ASSERT_SEND,
        S_WAIT_RCV
    } src_state_t;

    src_state_t       src_state;
    logic [WIDTH-1:0] active_data;
    logic [WIDTH-1:0] pending_data;
    logic             pending_valid;
    logic             src_send;
    logic             src_rcv;

    logic [WIDTH-1:0] xpm_dest_out;
    logic             dest_req;
    logic             dest_req_d;
    logic             dest_ack;

    // Source-side policy:
    //   - Transfer one coherent snapshot at a time.
    //   - If new source values arrive while busy, retain only the latest pending
    //     value. This is correct for memory-mapped config/status mirrors.
    always_ff @(posedge src_clk) begin
        if (src_rst) begin
            src_state     <= S_IDLE;
            active_data   <= '0;
            pending_data  <= '0;
            pending_valid <= 1'b0;
            src_send      <= 1'b0;
        end else begin
            case (src_state)
                S_IDLE: begin
                    src_send <= 1'b0;

                    // Prefer a new same-cycle source update over an older
                    // pending update. This avoids losing the latest CPU write
                    // when the mailbox becomes idle.
                    if (src_valid) begin
                        active_data   <= src_data;
                        pending_valid <= 1'b0;
                        src_state     <= S_ASSERT_SEND;
                    end else if (pending_valid) begin
                        active_data   <= pending_data;
                        pending_valid <= 1'b0;
                        src_state     <= S_ASSERT_SEND;
                    end
                end

                // Give active_data one full src_clk cycle to settle before
                // xpm_cdc_handshake samples src_send as asserted.
                S_ASSERT_SEND: begin
                    if (src_valid) begin
                        pending_data  <= src_data;
                        pending_valid <= 1'b1;
                    end
                    src_send  <= 1'b1;
                    src_state <= S_WAIT_RCV;
                end

                S_WAIT_RCV: begin
                    if (src_valid) begin
                        pending_data  <= src_data;
                        pending_valid <= 1'b1;
                    end

                    // src_send also records which half of the four-phase
                    // handshake is active. Keep this state after dropping
                    // src_send until src_rcv has returned low; S_IDLE then
                    // launches the latest pending value normally.
                    if (src_send) begin
                        if (src_rcv) begin
                            src_send <= 1'b0;
                        end
                    end else if (!src_rcv) begin
                        src_state <= S_IDLE;
                    end
                end

                default: begin
                    src_send      <= 1'b0;
                    pending_valid <= 1'b0;
                    src_state     <= S_IDLE;
                end
            endcase
        end
    end

    assign src_busy = (src_state != S_IDLE) | pending_valid;

    xpm_cdc_handshake #(
        .DEST_EXT_HSK   (1),
        .DEST_SYNC_FF   (DEST_SYNC_FF),
        .INIT_SYNC_FF   (INIT_SYNC_FF),
        .SIM_ASSERT_CHK (0),
        .SRC_SYNC_FF    (SRC_SYNC_FF),
        .WIDTH          (WIDTH)
    ) u_xpm_cdc_handshake (
        .src_clk   (src_clk),
        .src_in    (active_data),
        .src_send  (src_send),
        .src_rcv   (src_rcv),
        .dest_clk  (dest_clk),
        .dest_out  (xpm_dest_out),
        .dest_req  (dest_req),
        .dest_ack  (dest_ack)
    );

    // Destination-side policy:
    //   - Capture the transferred snapshot on the rising observation of dest_req.
    //   - Keep dest_ack asserted while dest_req remains asserted.
    //   - dest_valid is a one-cycle pulse; dest_data remains registered.
    always_ff @(posedge dest_clk) begin
        if (dest_rst) begin
            dest_data  <= '0;
            dest_valid <= 1'b0;
            dest_req_d <= 1'b0;
            dest_ack   <= 1'b0;
        end else begin
            dest_req_d <= dest_req;
            dest_valid <= 1'b0;
            dest_ack   <= dest_req;

            if (dest_req && !dest_req_d) begin
                dest_data  <= xpm_dest_out;
                dest_valid <= 1'b1;
            end
        end
    end
endmodule
