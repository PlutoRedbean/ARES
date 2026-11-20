`timescale 1ns/1ps

// Passive 720p RGB565 tap. One raster line of partial 4x4 sums and one
// 320x180 luma history. Blanking and malformed rasters never stall capture.
module pipeline_amp_motion #(
    parameter [7:0] THRESHOLD = 12
) (
    input wire pixel_clk, pixel_rst, pixel_vsync, pixel_de,
    input wire [15:0] pixel_rgb565,
    input wire clk, rst, cpu_valid, cpu_write,
    input wire [4:0] cpu_offset,
    output reg [31:0] cpu_rdata
);
    reg vs_q, de_q, started, malformed, history_ready;
    reg [10:0] x, y;
    reg [6:0] tile_x, tile_y;
    reg [3:0] col, row;
    reg [15:0] sample_addr;

    wire boundary = pixel_vsync && !vs_q;
    wire active = started && pixel_de && !pixel_vsync;
    wire in_raster = active && x < 1280 && y < 720;
    // VSYNC may follow the last pixel directly, or follow horizontal blanking.
    wire complete = !malformed && ((de_q && x == 1280 && y == 719) ||
                                   (!de_q && x == 0 && y == 720));
    reg finish, valid_pair;
    reg [31:0] frame_seq;
    always @(posedge pixel_clk) begin
        vs_q <= pixel_vsync;
        de_q <= active;
        finish <= 0;
        if (pixel_rst || boundary) begin
            x <= 0;
            y <= 0;
            tile_x <= 0;
            tile_y <= 0;
            col <= 0;
            row <= 0;
            sample_addr <= 0;
            malformed <= 0;
            started <= !pixel_rst;
            history_ready <= !pixel_rst && started && complete;
            valid_pair <= !pixel_rst && complete && history_ready;
            finish <= !pixel_rst && started;
            if (pixel_rst) begin
                vs_q <= 0;
                de_q <= 0;
                frame_seq <= 0;
            end else if (started)
                frame_seq <= frame_seq + 1'b1;
        end else if (active) begin
            if (in_raster) begin
                x <= x + 1'b1;
                if (tile_x == 79) begin
                    col <= col + 1'b1;
                    tile_x <= 0;
                end else
                    tile_x <= tile_x + 1'b1;
                if (x[1:0] == 3 && y[1:0] == 3)
                    sample_addr <= sample_addr + 1'b1;
            end else
                malformed <= 1;
        end else if (de_q) begin
            if (x != 1280 || y >= 720)
                malformed <= 1;
            x <= 0;
            col <= 0;
            tile_x <= 0;
            if (y < 720)
                y <= y + 1'b1;
            if (tile_y == 79) begin
                row <= row + 1'b1;
                tile_y <= 0;
            end else
                tile_y <= tile_y + 1'b1;
        end
    end

    wire [7:0] red = {pixel_rgb565[15:11], pixel_rgb565[15:13]};
    wire [7:0] green = {pixel_rgb565[10:5], pixel_rgb565[10:9]};
    wire [7:0] blue = {pixel_rgb565[4:0], pixel_rgb565[4:2]};
    wire [15:0] weighted = 16'd77 * red + 16'd150 * green + 16'd29 * blue;
    reg [9:0] horizontal;
    wire [9:0] four = horizontal + {2'b0, weighted[15:8]};
    reg [11:0] line_sums [0:319];
    reg [11:0] above;
    wire [11:0] square = (y[1:0] == 0 ? 12'd0 : above) + {2'b0, four};

    (* syn_ramstyle = "block_ram", ram_style = "block" *)
    reg [7:0] history [0:57599];
    reg [7:0] previous, current;
    reg sample, first_in_tile, last_in_tile;
    reg [3:0] sample_col, sample_row;
    always @(posedge pixel_clk) begin
        sample <= !pixel_rst && in_raster && x[1:0] == 3 && y[1:0] == 3;
        if (in_raster) begin
            horizontal <= x[1:0] == 0 ? {2'b0, weighted[15:8]} : four;
            if (x[1:0] == 2) begin
                above <= line_sums[x[10:2]];
                if (y[1:0] == 3)
                    previous <= history[sample_addr];
            end
            if (x[1:0] == 3) begin
                if (y[1:0] != 3)
                    line_sums[x[10:2]] <= square;
                else begin
                    history[sample_addr] <= square[11:4];
                    current <= square[11:4];
                    sample_col <= col;
                    sample_row <= row;
                    first_in_tile <= tile_x == 3 && tile_y == 3;
                    last_in_tile <= tile_x == 79 && tile_y == 79;
                end
            end
        end
    end

    wire [7:0] diff = current >= previous ? current - previous : previous - current;
    reg [16:0] tile_sums [0:15];
    wire [16:0] tile_sum = (first_in_tile ? 17'd0 : tile_sums[sample_col]) + {9'd0, diff};
    // floor(sum / 400) > T iff sum >= 400 * (T + 1).
    localparam [16:0] ACTIVE_SUM = 17'd400 * ({9'd0, THRESHOLD} + 17'd1);
    // Increment the quotient whenever the running remainder crosses 57,600.
    // A sample adds at most 255, so one subtraction per sample is sufficient.
    reg [15:0] remainder_q;
    reg [7:0] mean;
    wire [15:0] remainder_next = remainder_q + {8'd0, diff};
    reg [143:0] mask;
    reg [7:0] count;
    always @(posedge pixel_clk) begin
        if (pixel_rst || finish) begin
            remainder_q <= 0;
            mean <= 0;
            mask <= 0;
            count <= 0;
        end else if (sample) begin
            tile_sums[sample_col] <= tile_sum;
            if (remainder_next >= 16'd57600) begin
                remainder_q <= remainder_next - 16'd57600;
                mean <= mean + 1'b1;
            end else
                remainder_q <= remainder_next;
            if (last_in_tile && tile_sum >= ACTIVE_SUM) begin
                mask[{sample_row, sample_col}] <= 1;
                count <= count + 1'b1;
            end
        end
    end

    // Each boundary publishes a frame number, including warm-up and damage.
    reg publish;
    reg [7:0] mean_q, count_q;
    reg valid_q;
    reg [31:0] seq_q;
    reg [143:0] mask_q;
    always @(posedge pixel_clk) begin
        publish <= finish && !pixel_rst;
        if (finish) begin
            seq_q <= frame_seq;
            valid_q <= valid_pair;
            mean_q <= valid_pair ? mean : 0;
            count_q <= valid_pair ? count : 0;
            mask_q <= valid_pair ? mask : 0;
        end
    end

    wire [192:0] latest;
    wire arrived;
    pipeline_cdc_mailbox #(.WIDTH(193)) u_summary (
        .src_clk(pixel_clk), .src_rst(pixel_rst), .src_valid(publish),
        .src_data({seq_q, valid_q, count_q, mean_q, mask_q}), .src_busy(),
        .dest_clk(clk), .dest_rst(rst), .dest_valid(arrived), .dest_data(latest)
    );

    // Reading status is non-destructive. A write snapshots the latest report
    // for all seven subsequent word reads, even if new frames arrive meanwhile.
    reg fresh;
    reg [192:0] snapshot;
    wire take = cpu_valid && cpu_write && cpu_offset == 0;
    reg [31:0] read_q;
    always @(posedge clk) begin
        if (rst)
            fresh <= 0;
        else if (take) begin
            fresh <= 0;
            snapshot <= latest;
        end else if (arrived)
            fresh <= 1;
        if (cpu_valid && !cpu_write) begin
            case (cpu_offset[4:2])
                3'd0: read_q <= {30'd0, 1'b1, fresh};
                3'd1: read_q <= snapshot[192:161];
                3'd2: read_q <= {15'd0, snapshot[160:144]};
                3'd3: read_q <= snapshot[31:0];
                3'd4: read_q <= snapshot[63:32];
                3'd5: read_q <= snapshot[95:64];
                3'd6: read_q <= snapshot[127:96];
                3'd7: read_q <= {16'd0, snapshot[143:128]};
            endcase
        end
        cpu_rdata <= read_q;
    end
endmodule
