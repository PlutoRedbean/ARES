`timescale 1ns/1ps

// One published bank is held until hart0 releases it. While that bank is
// held, the sensor may overwrite only the other bank or drop an entire frame.
module pipeline_amp_camera (
    input wire pixel_clk, pixel_rst, pixel_vsync, pixel_de,
    input wire [15:0] pixel_rgb565,
    input wire clk, rst, cpu_valid, cpu_write,
    input wire [31:0] cpu_addr,
    output reg [31:0] cpu_rdata
);
    localparam [16:0] FRAME_PIXELS = 17'd76800;
    reg [10:0] x, y;
    reg [16:0] write_index;
    reg vsync_q, de_q, frame_started, published, released;
    (* ASYNC_REG = "TRUE" *) reg [1:0] release_sync, publish_sync;
    wire pending = publish_sync[1] != released;
    wire frame_edge = pixel_vsync && !vsync_q;
    wire sample_pixel = frame_started && pixel_de && !pixel_vsync &&
                        x >= 11'd320 && x < 11'd960 && !x[0] &&
                        y >= 11'd120 && y < 11'd600 && !y[0] &&
                        write_index < FRAME_PIXELS;
    wire [7:0] red = {pixel_rgb565[15:11], pixel_rgb565[15:13]};
    wire [7:0] green = {pixel_rgb565[10:5], pixel_rgb565[10:9]};
    wire [7:0] blue = {pixel_rgb565[4:0], pixel_rgb565[4:2]};
    wire [15:0] luma = 16'd77 * red + 16'd150 * green + 16'd29 * blue;

    (* syn_ramstyle = "block_ram", ram_style = "block" *)
    reg [7:0] bank0 [0:76799];
    (* syn_ramstyle = "block_ram", ram_style = "block" *)
    reg [7:0] bank1 [0:76799];
    reg [7:0] pixel0_q, pixel1_q;
    reg read_q, status_q, pending_q, bank_q;
    wire status_sel = cpu_addr == 32'hD000_3000;
    wire read_pixel = cpu_valid && !cpu_write && !status_sel && pending;
    wire [16:0] read_index = cpu_addr[18:2];

    always @(posedge pixel_clk) begin
        if (sample_pixel && !pixel_rst) begin
            if (published)
                bank0[write_index] <= luma[15:8];
            else
                bank1[write_index] <= luma[15:8];
        end
    end

    always @(posedge pixel_clk or posedge pixel_rst) begin
        if (pixel_rst) begin
            release_sync <= 2'b0;
            vsync_q <= 1'b0;
            de_q <= 1'b0;
            frame_started <= 1'b0;
            published <= 1'b0;
            x <= 0;
            y <= 0;
            write_index <= 0;
        end else begin
            release_sync <= {release_sync[0], released};
            vsync_q <= pixel_vsync;
            de_q <= pixel_de && !pixel_vsync;
            if (frame_edge) begin
                if (write_index == FRAME_PIXELS && release_sync[1] == published)
                    published <= ~published;
                frame_started <= 1'b1;
                x <= 0;
                y <= 0;
                write_index <= 0;
            end else if (pixel_de && !pixel_vsync) begin
                x <= x + 1'b1;
                if (sample_pixel)
                    write_index <= write_index + 1'b1;
            end else if (de_q) begin
                x <= 0;
                y <= y + 1'b1;
            end
        end
    end

    always @(posedge clk) begin
        if (read_pixel && !publish_sync[1])
            pixel0_q <= bank0[read_index];
        if (read_pixel && publish_sync[1])
            pixel1_q <= bank1[read_index];
    end

    always @(posedge clk) begin
        if (rst) begin
            publish_sync <= 2'b0;
            released <= 1'b0;
            read_q <= 1'b0;
        end else begin
            publish_sync <= {publish_sync[0], published};
            if (cpu_valid && cpu_write && status_sel)
                released <= publish_sync[1];
            read_q <= cpu_valid && !cpu_write;
            if (cpu_valid && !cpu_write) begin
                status_q <= status_sel;
                pending_q <= pending;
                bank_q <= publish_sync[1];
            end
            if (read_q)
                cpu_rdata <= {24'b0, status_q ? {7'b0, pending_q} :
                              pending_q ? (bank_q ? pixel1_q : pixel0_q) : 8'b0};
        end
    end
endmodule
