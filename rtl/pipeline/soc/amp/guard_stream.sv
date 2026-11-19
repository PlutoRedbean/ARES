`timescale 1ns/1ps

// Transport-independent Guard data path. Input bit 8 is a separate frame-end
// token; output bit 8 marks completion AFTER the final audit byte, with error
// in bit 9. All other tokens carry exactly one protocol byte.
module guard_stream #(parameter bit USE_NER = 1) (
    input wire clk, rst, in_valid, uart_fault,
    input wire [8:0] in_token,
    output wire consume,
    input wire out_full,
    output wire produce,
    output wire [9:0] result
);
    typedef enum logic [2:0] {RECEIVE, FLUSH, REPORT, FINISH, RESET_FRAME} state_t;
    state_t state;
    wire frame_reset = rst || state == RESET_FRAME;
    wire data_valid, frame_end, entity_busy, semantic_busy, l1_done, overflow;
    wire masked_valid, audit_valid, kw_valid, class_valid;
    wire [7:0] masked_byte;
    wire [3:0] audit_type;
    wire [2:0] keyword;
    wire [1:0] classification;

    // Reserve output storage at input acceptance: the redactor can emit up
    // to one byte per clock and has no output backpressure port.
    wire [8:0] level;
    reg [8:0] inflight;
    wire have_credit = ({1'b0, level} + inflight < 254) && inflight < 128;
    assign consume = state == RECEIVE && in_valid && !entity_busy && !semantic_busy && have_credit;
    assign data_valid = consume && !in_token[8];
    assign frame_end = consume && in_token[8];

    l1_redact_top #(.USE_NER(USE_NER)) u_redact (
        .clk(clk), .rst_n(!frame_reset), .in_valid(data_valid), .in_char(in_token[7:0]),
        .in_last(frame_end), .busy_l2b(entity_busy), .out_valid(masked_valid),
        .out_char(masked_byte), .a_valid(audit_valid), .a_type(audit_type), .a_start(), .a_len(),
        .kw_valid(kw_valid), .kw_kid(keyword), .done(l1_done), .ovf(overflow), .dropped()
    );
    l2_semantic_top u_semantic (
        .clk(clk), .rst_n(!frame_reset), .in_valid(data_valid), .in_char(in_token[7:0]),
        .in_last(frame_end), .busy(semantic_busy), .out_valid(class_valid),
        .out_class(classification), .out_start(), .out_len(), .out_s0(), .out_s1(),
        .out_s2(), .out_s3()
    );

    wire body_empty;
    wire [7:0] body_byte;
    wire take_body = !body_empty && !out_full;
    guard_fifo u_body (
        .clk(clk), .rst_n(!rst), .push(masked_valid), .din(masked_byte), .full(),
        .pop(take_body), .empty(body_empty), .dout(body_byte), .level(level)
    );

    reg done_seen, at_line_start, report_error;
    wire frame_error = overflow || uart_fault;
    reg [7:0] hits [0:10];
    reg [7:0] kw_count, kw_mask, class_count, class_mask;
    wire report_start = state == FLUSH && done_seen && !semantic_busy && body_empty;
    wire report_valid, report_finished;
    wire [7:0] report_byte;
    guard_report u_report (
        .clk(clk), .rst_n(!rst), .start(report_start), .at_line_start(at_line_start),
        .v_n(hits[0]), .v_id18(hits[1]), .v_id15(hits[2]), .v_mobile(hits[3]),
        .v_bank(hits[4]), .v_email(hits[5]), .v_ipv4(hits[6]), .v_uscc(hits[7]),
        .v_plate(hits[8]), .v_name(hits[9]), .v_addr(hits[10]), .v_kw(kw_count),
        .v_kwm(kw_mask), .v_l2(class_count), .v_l2m(class_mask), .v_err(frame_error),
        .v_mode(4'd1), .fifo_full(out_full), .byte_valid(report_valid), .byte_out(report_byte),
        .busy(), .finished(report_finished)
    );

    assign produce = !out_full && (!body_empty || report_valid || state == FINISH);
    assign result = state == FINISH ? {report_error, 1'b1, 8'd0} :
                    {2'b00, report_valid ? report_byte : body_byte};

    // The wire format uses three decimal digits with 8-bit, saturating counts.
    function automatic [7:0] increment(input [7:0] count);
        increment = count == 255 ? count : count + 1'b1;
    endfunction

    always_ff @(posedge clk) begin
        if (frame_reset) begin
            state <= RECEIVE;
            inflight <= 0;
            done_seen <= 0;
            report_error <= 0;
            at_line_start <= 1;
            for (integer i = 0; i <= 10; i++) hits[i] <= 0;
            kw_count <= 0;
            kw_mask <= 0;
            class_count <= 0;
            class_mask <= 0;
        end else begin
            case ({data_valid, masked_valid})
                2'b10: inflight <= inflight + 1'b1;
                2'b01: inflight <= inflight - 1'b1;
                default: ;
            endcase
            if (l1_done) done_seen <= 1;
            if (report_start) report_error <= frame_error;
            if (masked_valid) at_line_start <= masked_byte == 8'h0a;
            if (audit_valid) begin
                hits[0] <= increment(hits[0]);
                hits[audit_type] <= increment(hits[audit_type]);
            end
            if (kw_valid) begin
                kw_count <= increment(kw_count);
                kw_mask[keyword] <= 1;
            end
            if (class_valid && classification != 0) begin
                class_count <= increment(class_count);
                class_mask[{1'b0, classification}] <= 1;
            end
            case (state)
                RECEIVE: if (frame_end) state <= FLUSH;
                FLUSH: if (report_start) state <= REPORT;
                REPORT: if (report_finished) state <= FINISH;
                FINISH: if (!out_full) state <= RESET_FRAME;
                default: ;
            endcase
        end
    end
endmodule
