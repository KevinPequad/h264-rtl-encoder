// h264_fetch.v — Macroblock Fetch Unit
// Reads 16x16 luma + 2x 8x8 chroma blocks from flat byte-addressed memory
// One byte per clock cycle via memory read port

module h264_fetch #(
    parameter FRAME_WIDTH = 320,
    parameter BIT_DEPTH   = 8,
    parameter CHROMA_FORMAT_IDC = 1,
    parameter CHROMA_MB_WIDTH  = (CHROMA_FORMAT_IDC == 3) ? 16 : 8,
    parameter CHROMA_MB_HEIGHT = (CHROMA_FORMAT_IDC == 1) ? 8 : 16,
    parameter CHROMA_MB_PIXELS = CHROMA_MB_WIDTH * CHROMA_MB_HEIGHT
) (
    input  wire        clk,
    input  wire        rst_n,

    // Control
    input  wire        start,
    input  wire [20:0] frame_base_y,
    input  wire [20:0] frame_base_cb,
    input  wire [20:0] frame_base_cr,
    input  wire [6:0]  mb_x,
    input  wire [5:0]  mb_y,
    input  wire [10:0] frame_width,

    // Memory read port
    output reg  [20:0] raw_mem_addr,
    input  wire [BIT_DEPTH-1:0]  raw_mem_data,

    // Output: flattened pixel arrays (active after done)
    output reg  [256*BIT_DEPTH-1:0] luma_flat,   // 16x16 pixels
    output reg  [CHROMA_MB_PIXELS*BIT_DEPTH-1:0]  cb_flat,
    output reg  [CHROMA_MB_PIXELS*BIT_DEPTH-1:0]  cr_flat,

    output reg         done,
    output reg         valid
);

    localparam S_IDLE      = 3'd0;
    localparam S_ADDR      = 3'd1;
    localparam S_READ      = 3'd2;
    localparam S_DONE      = 3'd3;

    reg [2:0]  state;
    reg [1:0]  plane;       // 0=luma, 1=Cb, 2=Cr
    reg [3:0]  row;
    reg [3:0]  col;
    localparam RAW_ADDR_W = 21;

    reg [RAW_ADDR_W-1:0] row_base;
    reg [10:0] plane_width; // current plane width
    reg [3:0]  max_row;
    reg [3:0]  max_col;

    wire [RAW_ADDR_W-1:0] y_origin  = frame_base_y  + ({15'd0, mb_y} * 21'd16) * {10'd0, frame_width} + ({14'd0, mb_x} * 21'd16);
    wire [10:0] ch_width  = (CHROMA_FORMAT_IDC == 3) ? frame_width : (frame_width >> 1);
    wire [RAW_ADDR_W-1:0] cb_origin = frame_base_cb + ({15'd0, mb_y} * CHROMA_MB_HEIGHT) * {10'd0, ch_width} + ({14'd0, mb_x} * CHROMA_MB_WIDTH);
    wire [RAW_ADDR_W-1:0] cr_origin = frame_base_cr + ({15'd0, mb_y} * CHROMA_MB_HEIGHT) * {10'd0, ch_width} + ({14'd0, mb_x} * CHROMA_MB_WIDTH);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            raw_mem_addr<= {RAW_ADDR_W{1'b0}};
            done        <= 1'b0;
            valid       <= 1'b0;
            luma_flat   <= {(256*BIT_DEPTH){1'b0}};
            cb_flat     <= {(CHROMA_MB_PIXELS*BIT_DEPTH){1'b0}};
            cr_flat     <= {(CHROMA_MB_PIXELS*BIT_DEPTH){1'b0}};
            plane       <= 2'd0;
            row         <= 4'd0;
            col         <= 4'd0;
            row_base    <= {RAW_ADDR_W{1'b0}};
            plane_width <= 11'd0;
            max_row     <= 4'd0;
            max_col     <= 4'd0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: begin
                    valid <= 1'b0;
                    if (start) begin
                        plane       <= 2'd0;
                        row         <= 4'd0;
                        col         <= 4'd0;
                        row_base    <= y_origin;
                        plane_width <= frame_width;
                        max_row     <= 4'd15;
                        max_col     <= 4'd15;
                        state       <= S_ADDR;
                    end
                end

                S_ADDR: begin
                    raw_mem_addr <= row_base + {{(RAW_ADDR_W-4){1'b0}}, col};
                    state        <= S_READ;
                end

                S_READ: begin
                    // Store the read pixel into the appropriate flattened array
                    if (plane == 2'd0) begin
                        luma_flat[({row, col} * BIT_DEPTH) +: BIT_DEPTH] <= raw_mem_data;
                    end else if (plane == 2'd1) begin
                        cb_flat[((row * CHROMA_MB_WIDTH + col) * BIT_DEPTH) +: BIT_DEPTH] <= raw_mem_data;
                    end else begin
                        cr_flat[((row * CHROMA_MB_WIDTH + col) * BIT_DEPTH) +: BIT_DEPTH] <= raw_mem_data;
                    end

                    if (col == max_col) begin
                        col <= 4'd0;
                        if (row == max_row) begin
                            // Plane done, move to next plane or finish
                            if (plane == 2'd0) begin
                                plane       <= 2'd1;
                                row         <= 4'd0;
                                row_base    <= cb_origin;
                                plane_width <= ch_width;
                                max_row     <= CHROMA_MB_HEIGHT - 1;
                                max_col     <= CHROMA_MB_WIDTH - 1;
                                state       <= S_ADDR;
                            end else if (plane == 2'd1) begin
                                plane       <= 2'd2;
                                row         <= 4'd0;
                                row_base    <= cr_origin;
                                state       <= S_ADDR;
                            end else begin
                                state <= S_DONE;
                            end
                        end else begin
                            row      <= row + 4'd1;
                            row_base <= row_base + {9'd0, plane_width};
                            state    <= S_ADDR;
                        end
                    end else begin
                        col   <= col + 4'd1;
                        state <= S_ADDR;
                    end
                end

                S_DONE: begin
                    done  <= 1'b1;
                    valid <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
