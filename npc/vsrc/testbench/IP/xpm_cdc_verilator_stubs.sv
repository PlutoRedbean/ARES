`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
//
// Purpose:
//   Vivado can compile XPM modules from its built-in libraries, but Verilator
//   usually cannot find xpm_cdc_single / xpm_cdc_array_single / xpm_cdc_gray /
//   xpm_cdc_handshake unless the Xilinx simulation library is added manually.
//
// Usage:
//   1. Add this file to the Verilator file list.
//   2. Also safe to add to Vivado sources, because all module definitions are
//      guarded by `ifdef __VERILATOR__ and will be empty in Vivado.
//
// These models are for RTL simulation only. Vivado synthesis/implementation
// should still use the real XPM modules from cdc_xpm_nofifo_lib.sv / counter.sv.
//////////////////////////////////////////////////////////////////////////////////

`ifdef __VERILATOR__
/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off UNUSEDSIGNAL */

module xpm_cdc_single #(
    parameter integer DEST_SYNC_FF   = 2,
    parameter integer INIT_SYNC_FF   = 0,
    parameter integer SIM_ASSERT_CHK = 0,
    parameter integer SRC_INPUT_REG  = 1
) (
    input  logic src_clk,
    input  logic src_in,
    input  logic dest_clk,
    output logic dest_out
);
    localparam integer N = (DEST_SYNC_FF < 1) ? 1 : DEST_SYNC_FF;

    logic src_reg;
    logic src_sig;
    logic [N-1:0] sync_ff;

    initial begin
        src_reg  = 1'b0;
        sync_ff  = '0;
        dest_out = 1'b0;
    end

    generate
        if (SRC_INPUT_REG != 0) begin : g_src_reg
            always_ff @(posedge src_clk) begin
                src_reg <= src_in;
            end
            assign src_sig = src_reg;
        end else begin : g_no_src_reg
            assign src_sig = src_in;
        end
    endgenerate

    always_ff @(posedge dest_clk) begin
        if (N == 1) begin
            sync_ff[0] <= src_sig;
        end else begin
            sync_ff <= {sync_ff[N-2:0], src_sig};
        end
        dest_out <= sync_ff[N-1];
    end
endmodule

module xpm_cdc_array_single #(
    parameter integer DEST_SYNC_FF   = 2,
    parameter integer INIT_SYNC_FF   = 0,
    parameter integer SIM_ASSERT_CHK = 0,
    parameter integer SRC_INPUT_REG  = 1,
    parameter integer WIDTH          = 1
) (
    input  logic             src_clk,
    input  logic [WIDTH-1:0] src_in,
    input  logic             dest_clk,
    output logic [WIDTH-1:0] dest_out
);
    localparam integer N = (DEST_SYNC_FF < 1) ? 1 : DEST_SYNC_FF;

    logic [WIDTH-1:0] src_reg;
    logic [WIDTH-1:0] src_sig;
    logic [WIDTH-1:0] sync_ff [N-1:0];

    integer i;
    initial begin
        src_reg  = '0;
        dest_out = '0;
        for (i = 0; i < N; i = i + 1) begin
            sync_ff[i] = '0;
        end
    end

    generate
        if (SRC_INPUT_REG != 0) begin : g_src_reg
            always_ff @(posedge src_clk) begin
                src_reg <= src_in;
            end
            assign src_sig = src_reg;
        end else begin : g_no_src_reg
            assign src_sig = src_in;
        end
    endgenerate

    always_ff @(posedge dest_clk) begin
        sync_ff[0] <= src_sig;
        for (int j = 1; j < N; j = j + 1) begin
            sync_ff[j] <= sync_ff[j-1];
        end
        dest_out <= sync_ff[N-1];
    end
endmodule

module xpm_cdc_gray #(
    parameter integer DEST_SYNC_FF          = 2,
    parameter integer INIT_SYNC_FF          = 0,
    parameter integer REG_OUTPUT            = 1,
    parameter integer SIM_ASSERT_CHK        = 0,
    parameter integer SIM_LOSSLESS_GRAY_CHK = 0,
    parameter integer WIDTH                 = 2
) (
    input  logic             src_clk,
    input  logic [WIDTH-1:0] src_in_bin,
    input  logic             dest_clk,
    output logic [WIDTH-1:0] dest_out_bin
);
    localparam integer N = (DEST_SYNC_FF < 1) ? 1 : DEST_SYNC_FF;

    logic [WIDTH-1:0] src_gray;
    logic [WIDTH-1:0] sync_gray [N-1:0];
    logic [WIDTH-1:0] bin_comb;

    function automatic logic [WIDTH-1:0] bin_to_gray(input logic [WIDTH-1:0] bin);
        bin_to_gray = bin ^ (bin >> 1);
    endfunction

    function automatic logic [WIDTH-1:0] gray_to_bin(input logic [WIDTH-1:0] gray);
        logic [WIDTH-1:0] bin;
        bin[WIDTH-1] = gray[WIDTH-1];
        for (int k = WIDTH-2; k >= 0; k = k - 1) begin
            bin[k] = bin[k+1] ^ gray[k];
        end
        return bin;
    endfunction

    integer i;
    initial begin
        src_gray     = '0;
        dest_out_bin = '0;
        for (i = 0; i < N; i = i + 1) begin
            sync_gray[i] = '0;
        end
    end

    always_ff @(posedge src_clk) begin
        src_gray <= bin_to_gray(src_in_bin);
    end

    always_ff @(posedge dest_clk) begin
        sync_gray[0] <= src_gray;
        for (int j = 1; j < N; j = j + 1) begin
            sync_gray[j] <= sync_gray[j-1];
        end
    end

    always_comb begin
        bin_comb = gray_to_bin(sync_gray[N-1]);
    end

    generate
        if (REG_OUTPUT != 0) begin : g_reg_output
            always_ff @(posedge dest_clk) begin
                dest_out_bin <= bin_comb;
            end
        end else begin : g_comb_output
            always_comb begin
                dest_out_bin = bin_comb;
            end
        end
    endgenerate
endmodule

module xpm_cdc_handshake #(
    parameter integer DEST_EXT_HSK   = 1,
    parameter integer DEST_SYNC_FF   = 2,
    parameter integer INIT_SYNC_FF   = 0,
    parameter integer SIM_ASSERT_CHK = 0,
    parameter integer SRC_SYNC_FF    = 2,
    parameter integer WIDTH          = 1
) (
    input  logic             src_clk,
    input  logic [WIDTH-1:0] src_in,
    input  logic             src_send,
    output logic             src_rcv,

    input  logic             dest_clk,
    output logic [WIDTH-1:0] dest_out,
    output logic             dest_req,
    input  logic             dest_ack
);
    localparam integer DN = (DEST_SYNC_FF < 1) ? 1 : DEST_SYNC_FF;
    localparam integer SN = (SRC_SYNC_FF  < 1) ? 1 : SRC_SYNC_FF;

    logic [WIDTH-1:0] src_hold;
    logic             req_toggle;
    logic             src_active;
    logic [DN-1:0]    req_sync;
    logic             req_seen;
    logic             ack_toggle;
    logic [SN-1:0]    ack_sync;

    initial begin
        src_hold   = '0;
        req_toggle = 1'b0;
        src_active = 1'b0;
        req_sync   = '0;
        req_seen   = 1'b0;
        ack_toggle = 1'b0;
        ack_sync   = '0;
        src_rcv    = 1'b0;
        dest_out   = '0;
        dest_req   = 1'b0;
    end

    // Acknowledge toggle synchronizer back to the source domain.
    always_ff @(posedge src_clk) begin
        if (SN == 1) begin
            ack_sync[0] <= ack_toggle;
        end else begin
            ack_sync <= {ack_sync[SN-2:0], ack_toggle};
        end

        if (!src_active) begin
            src_rcv <= 1'b0;
            if (src_send) begin
                src_hold   <= src_in;
                req_toggle <= ~req_toggle;
                src_active <= 1'b1;
            end
        end else begin
            if (ack_sync[SN-1] == req_toggle) begin
                src_rcv <= 1'b1;
                if (!src_send) begin
                    src_active <= 1'b0;
                    src_rcv    <= 1'b0;
                end
            end else begin
                src_rcv <= 1'b0;
            end
        end
    end

    // Request toggle synchronizer into the destination domain.
    always_ff @(posedge dest_clk) begin
        if (DN == 1) begin
            req_sync[0] <= req_toggle;
        end else begin
            req_sync <= {req_sync[DN-2:0], req_toggle};
        end

        if (!dest_req) begin
            if (req_sync[DN-1] != req_seen) begin
                dest_out <= src_hold;
                dest_req <= 1'b1;
            end
        end else begin
            if ((DEST_EXT_HSK == 0) || dest_ack) begin
                dest_req   <= 1'b0;
                req_seen   <= req_sync[DN-1];
                ack_toggle <= req_sync[DN-1];
            end
        end
    end
endmodule

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on DECLFILENAME */
`endif
