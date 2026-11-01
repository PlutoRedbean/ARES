//=============================================================================
// ARES pipeline 2-hart AMP full-accelerated CoreMark - board-level TB
//-----------------------------------------------------------------------------
// Drives the real board top (27 MHz input -> PLL -> 100/50 MHz -> reset),
// decodes the physical uart_tx pin at 115200 8N1, and stops when the CoreMark
// report prints PASS.
//
// The PLL is the behavioral pipeline_pll_sim model; the SoC is the same
// pipeline_amp_board_top used by the PDS flow.  The C++ main only loads the
// flat image into the DPI memory model and advances simulation time.
//=============================================================================
`timescale 1ns / 1ps

module tb_pipeline_amp_board (
    output logic       done,
    output wire [7:0]  led
);
    // Integer-ns delays keep the C++ time loop simple; the PLL model is
    // independent of the exact 27 MHz period.
    localparam integer BIT_NS = 8681;         // 115200 baud at 100 MHz

    logic        clk_27m = 1'b0;
    logic        rst_n   = 1'b0;
    wire         uart_tx;

    always begin
        #18 clk_27m = 1'b1;
        #19 clk_27m = 1'b0;
    end

    pipeline_amp_board_top u_dut (
        .clk_27m (clk_27m),
        .rst_n   (rst_n),
        .uart_tx (uart_tx),
        .led     (led)
    );

    //------------------------------------------------------------ UART monitor
    logic [7:0] rx;
    logic [7:0] line_buf [0:255];
    integer     line_len = 0;
    integer     chars    = 0;

    function automatic bit line_has_pass();
        integer i;
        begin
            line_has_pass = 1'b0;
            for (i = 0; i + 3 < line_len; i = i + 1) begin
                if (line_buf[i] == "P" && line_buf[i+1] == "A" &&
                    line_buf[i+2] == "S" && line_buf[i+3] == "S")
                    line_has_pass = 1'b1;
            end
        end
    endfunction

    initial begin
        done = 1'b0;
        forever begin
            @(negedge uart_tx);
            #(BIT_NS + BIT_NS/2);
            for (int b = 0; b < 8; b = b + 1) begin
                rx[b] = uart_tx;
                #(BIT_NS);
            end
            $write("%c", rx);
            $fflush();
            chars = chars + 1;

            if (rx == 8'h0a) begin
                if (line_has_pass()) begin
                    done = 1'b1;
                end
                line_len = 0;
            end else if (line_len < 255) begin
                line_buf[line_len] = rx;
                line_len = line_len + 1;
            end
        end
    end

    //------------------------------------------------------------- run control
    initial begin
        $display("[amp-board] reset held for 200 us");
        #200_000;
        rst_n = 1'b1;
        wait (done);
        #5_000_000;  // drain the final UART characters
        $display("\n[amp-board] CoreMark PASS seen: %0d chars, led=%02x", chars, led);
        $finish;
    end

    initial begin
        #200_000_000;  // 200 ms hard timeout
        $display("\n[amp-board] TIMEOUT: %0d chars, led=%02x", chars, led);
        $finish;
    end
endmodule
