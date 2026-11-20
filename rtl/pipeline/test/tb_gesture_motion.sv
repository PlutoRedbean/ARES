`timescale 1ns/1ps
module tb_gesture_motion;
    bit pixel_clk, clk, pixel_rst, rst, pixel_vsync, pixel_de, cpu_valid, cpu_write;
    bit [15:0] pixel_rgb565;
    bit [4:0] cpu_offset;
    wire [31:0] cpu_rdata;
    always #5 pixel_clk = !pixel_clk;
    always #7 clk = !clk;
    pipeline_amp_motion dut (.*);

    task automatic read_word(input bit [4:0] offset, output logic [31:0] value);
        @(negedge clk);
        cpu_valid = 1; cpu_write = 0; cpu_offset = offset;
        @(negedge clk);
        cpu_valid = 0;
        @(negedge clk);
        value = cpu_rdata;
    endtask

    task automatic boundary;
        @(negedge pixel_clk);
        pixel_de = 0; pixel_vsync = 1;
        repeat (4) @(negedge pixel_clk);
        pixel_vsync = 0;
        repeat (24) @(negedge pixel_clk);
    endtask

    task automatic reset_sensor;
        @(negedge pixel_clk);
        rst = 1; pixel_rst = 1;
        repeat (12) @(negedge pixel_clk);
        rst = 0; pixel_rst = 0;
        boundary();
    endtask

    reg [15:0] frame [0:1280*720-1];
    integer images, expected, rows, width, reset, seq, valid, mean, count, cases;
    reg [143:0] mask, held_mask;
    reg [31:0] val, held_seq;
    reg [159:0] received;
    initial begin
        images = $fopen("build/gesture_motion/frames.bin", "rb");
        expected = $fopen("build/gesture_motion/expected.txt", "r");
        if (images == 0 || expected == 0) $fatal(1, "missing reference fixtures");
        reset_sensor();
        cases = 0;
        while ($fscanf(expected, "%d%d%d%d%d%d%d%h", rows, width, reset, seq,
                       valid, mean, count, mask) == 8) begin
            if (reset != 0) reset_sensor();
            if ($fread(frame, images) != 2*1280*720) $fatal(1, "short fixture");
            for (int y = 0; y < rows; y++) begin
                for (int x = 0; x < (y == 17 ? width : 1280); x++) begin
                    @(negedge pixel_clk);
                    pixel_de = 1;
                    pixel_rgb565 = frame[(y % 720)*1280 + (x % 1280)];
                end
                // Alternate last-line blanking and VSYNC directly after DE.
                if (y != rows-1 || cases%2 == 0) begin
                    @(negedge pixel_clk);
                    pixel_de = 0;
                end
            end
            boundary();
            read_word(0, val);
            if (val !== 3) $fatal(1, "frame %0d status %h", seq, val);
            if (cases != 0 && reset == 0) begin
                read_word(4, val);
                if (val !== held_seq) $fatal(1, "snapshot changed before take");
                read_word(28, val);
                if (val[15:0] !== held_mask[143:128]) $fatal(1, "torn mask");
            end
            // Simulate a slow reader: leave frame #4 unread; #5 supersedes it.
            if (cases != 3) begin
                @(negedge clk);
                cpu_offset = 0; cpu_valid = 1; cpu_write = 1;
                @(negedge clk);
                cpu_valid = 0; cpu_write = 0;
                read_word(0, val);
                if (val !== 2) $fatal(1, "fresh bit stuck");
                read_word(4, val);
                if (val !== seq) $fatal(1, "sequence expected %0d got %0d", seq, val);
                read_word(8, val);
                if (val !== {15'd0, valid[0], count[7:0], mean[7:0]})
                    $fatal(1, "frame %0d info %h expected valid=%0d count=%0d mean=%0d",
                           seq, val, valid, count, mean);
                for (int word_n = 0; word_n < 5; word_n++) begin
                    read_word(5'(12 + 4*word_n), val);
                    received[32*word_n +: 32] = val;
                end
                if (received !== {16'd0, mask})
                    $fatal(1, "frame %0d mask %h expected %h", seq, received, mask);
                held_seq = seq;
                held_mask = mask;
            end
            cases++;
        end
        if (cases != 20) $fatal(1, "reference case count %0d", cases);
        $display("PASS: %0d full raster, damaged raster, reset and snapshot cases", cases);
        $finish;
    end
endmodule
