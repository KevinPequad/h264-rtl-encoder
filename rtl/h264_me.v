// h264_me.v — Motion Estimation for P-frame (16x16 block, integer-pel)
// Diamond search within ±SEARCH_RANGE using SAD
// Outputs best motion vector and the 16x16 reference block

module h264_me (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    output reg         done,

    // Current MB luma (16x16 = 256 bytes = 2048 bits)
    input  wire [2047:0] cur_mb,

    // Reference frame read port (active during search)
    output reg  [19:0] ref_rd_addr,
    input  wire [7:0]  ref_rd_data,

    // Frame dimensions
    input  wire [10:0] frame_width,
    input  wire [9:0]  frame_height,

    // Current MB position
    input  wire [6:0]  mb_x,
    input  wire [5:0]  mb_y,

    // Outputs
    output reg  signed [7:0]  best_mvx,
    output reg  signed [7:0]  best_mvy,
    output reg  [17:0]        best_sad,
    output reg  [2047:0]      ref_mb_out    // reference block at best MV
);

    // Diamond search pattern: check center, then 4 diamond points, iterate
    // Large diamond: (0,-2),(0,+2),(-2,0),(+2,0),(-1,-1),(+1,-1),(-1,+1),(+1,+1)
    // Small diamond: (0,-1),(0,+1),(-1,0),(+1,0)

    localparam SEARCH_RANGE = 16;

    // FSM
    localparam S_IDLE       = 4'd0;
    localparam S_START_CAND = 4'd1;  // begin fetching a candidate block
    localparam S_FETCH      = 4'd2;  // fetch 256 ref pixels
    localparam S_SAD        = 4'd3;  // compute SAD
    localparam S_UPDATE     = 4'd4;  // compare and maybe update best
    localparam S_NEXT_CAND  = 4'd5;  // pick next candidate in pattern
    localparam S_REFINE     = 4'd6;  // switch to small diamond or finish
    localparam S_DONE       = 4'd7;

    reg [3:0] state;

    // Current search center
    reg signed [11:0] center_x, center_y;

    // Current candidate offset from center
    reg signed [8:0] cand_ox, cand_oy;
    // Absolute candidate position
    wire signed [11:0] abs_cx = center_x + {{3{cand_ox[8]}}, cand_ox};
    wire signed [11:0] abs_cy = center_y + {{3{cand_oy[8]}}, cand_oy};

    // MB origin (pixel coordinates)
    wire signed [11:0] mb_origin_x = {5'b0, mb_x} << 4;
    wire signed [11:0] mb_origin_y = {6'b0, mb_y} << 4;
    wire signed [11:0] sr_min_x = mb_origin_x - 12'sd16;
    wire signed [11:0] sr_max_x = mb_origin_x + 12'sd16;
    wire signed [11:0] sr_min_y = mb_origin_y - 12'sd16;
    wire signed [11:0] sr_max_y = mb_origin_y + 12'sd16;

    // Validity check: within frame AND within search range
    wire cand_in_range = (abs_cx >= 12'sd0) && (abs_cy >= 12'sd0) &&
                         (abs_cx + 12'sd16 <= $signed({1'b0, frame_width})) &&
                         (abs_cy + 12'sd16 <= $signed({1'b0, frame_height})) &&
                         (abs_cx >= sr_min_x) &&
                         (abs_cx <= sr_max_x) &&
                         (abs_cy >= sr_min_y) &&
                         (abs_cy <= sr_max_y);

    // Fetch state
    reg [8:0] fetch_idx;   // 0..255: pixel index in 16x16 block
    reg [2047:0] cand_buf;

    // SAD computation
    reg [17:0] sad_acc;
    reg [8:0]  sad_idx;

    // Diamond pattern index
    reg [3:0] diamond_idx;
    reg       use_small_diamond;

    // Best in current diamond iteration
    reg signed [11:0] iter_best_x, iter_best_y;
    reg [17:0] iter_best_sad;
    reg        iter_improved;

    // Iteration count (limit search)
    reg [4:0] iter_count;

    // Diamond offsets (large): 8 points
    // (dx, dy): (0,-2),(0,+2),(-2,0),(+2,0),(-1,-1),(+1,-1),(-1,+1),(+1,+1)
    reg signed [2:0] ldx, ldy;
    always @(*) begin
        case (diamond_idx)
            4'd0: begin ldx = 3'sd0;  ldy = -3'sd2; end
            4'd1: begin ldx = 3'sd0;  ldy = 3'sd2;  end
            4'd2: begin ldx = -3'sd2; ldy = 3'sd0;  end
            4'd3: begin ldx = 3'sd2;  ldy = 3'sd0;  end
            4'd4: begin ldx = -3'sd1; ldy = -3'sd1; end
            4'd5: begin ldx = 3'sd1;  ldy = -3'sd1; end
            4'd6: begin ldx = -3'sd1; ldy = 3'sd1;  end
            4'd7: begin ldx = 3'sd1;  ldy = 3'sd1;  end
            default: begin ldx = 3'sd0; ldy = 3'sd0; end
        endcase
    end

    // Small diamond offsets: 4 points
    reg signed [2:0] sdx, sdy;
    always @(*) begin
        case (diamond_idx)
            4'd0: begin sdx = 3'sd0;  sdy = -3'sd1; end
            4'd1: begin sdx = 3'sd0;  sdy = 3'sd1;  end
            4'd2: begin sdx = -3'sd1; sdy = 3'sd0;  end
            4'd3: begin sdx = 3'sd1;  sdy = 3'sd0;  end
            default: begin sdx = 3'sd0; sdy = 3'sd0; end
        endcase
    end

    // Pixel extraction for SAD
    wire [7:0] cur_pix = cur_mb[sad_idx[7:0]*8 +: 8];
    wire [7:0] ref_pix = cand_buf[sad_idx[7:0]*8 +: 8];
    wire [8:0] adiff   = (cur_pix >= ref_pix) ?
                         {1'b0, cur_pix} - {1'b0, ref_pix} :
                         {1'b0, ref_pix} - {1'b0, cur_pix};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            done <= 1'b0;
            best_mvx <= 8'sd0;
            best_mvy <= 8'sd0;
            best_sad <= 18'h3FFFF;
            ref_mb_out <= 2048'd0;
            ref_rd_addr <= 20'd0;
            center_x <= 12'sd0;
            center_y <= 12'sd0;
            cand_ox <= 9'sd0;
            cand_oy <= 9'sd0;
            fetch_idx <= 9'd0;
            cand_buf <= 2048'd0;
            sad_acc <= 18'd0;
            sad_idx <= 9'd0;
            diamond_idx <= 4'd0;
            use_small_diamond <= 1'b0;
            iter_best_x <= 12'sd0;
            iter_best_y <= 12'sd0;
            iter_best_sad <= 18'h3FFFF;
            iter_improved <= 1'b0;
            iter_count <= 5'd0;
        end else begin
            done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (start) begin
                        // Initialize: search center = (0,0) relative to MB
                        center_x <= {5'b0, mb_x} << 4;
                        center_y <= {6'b0, mb_y} << 4;
                        best_sad <= 18'h3FFFF;
                        use_small_diamond <= 1'b0;
                        iter_count <= 5'd0;
                        // First test: center (0,0) itself
                        cand_ox <= 9'sd0;
                        cand_oy <= 9'sd0;
                        state <= S_START_CAND;
                    end
                end

                S_START_CAND: begin
                    if (cand_in_range) begin
                        fetch_idx <= 9'd0;
                        // Set up first read address
                        ref_rd_addr <= abs_cy[10:0] * frame_width + abs_cx[10:0];
                        state <= S_FETCH;
                    end else begin
                        state <= S_NEXT_CAND;
                    end
                end

                S_FETCH: begin
                    // Store pixel
                    cand_buf[fetch_idx[7:0]*8 +: 8] <= ref_rd_data;
                    fetch_idx <= fetch_idx + 9'd1;

                    if (fetch_idx == 9'd255) begin
                        state <= S_SAD;
                        sad_acc <= 18'd0;
                        sad_idx <= 9'd0;
                    end else begin
                        // Next address: row = (fetch_idx+1)/16, col = (fetch_idx+1)%16
                        if (fetch_idx[3:0] == 4'd15) begin
                            // End of row, jump to start of next row
                            ref_rd_addr <= (abs_cy[10:0] + {7'd0, fetch_idx[7:4]} + 11'd1) * frame_width + abs_cx[10:0];
                        end else begin
                            ref_rd_addr <= ref_rd_addr + 20'd1;
                        end
                    end
                end

                S_SAD: begin
                    sad_acc <= sad_acc + {9'd0, adiff};
                    if (sad_idx == 9'd255) begin
                        state <= S_UPDATE;
                    end else begin
                        sad_idx <= sad_idx + 9'd1;
                    end
                end

                S_UPDATE: begin
                    if (sad_acc < iter_best_sad) begin
                        iter_best_sad <= sad_acc;
                        iter_best_x <= abs_cx;
                        iter_best_y <= abs_cy;
                        iter_improved <= 1'b1;
                        // Save this block as current best ref
                        if (sad_acc < best_sad) begin
                            best_sad <= sad_acc;
                            best_mvx <= abs_cx - ({5'b0, mb_x} << 4);
                            best_mvy <= abs_cy - ({6'b0, mb_y} << 4);
                            ref_mb_out <= cand_buf;
                        end
                    end
                    state <= S_NEXT_CAND;
                end

                S_NEXT_CAND: begin
                    if (!use_small_diamond) begin
                        // Large diamond: 8 points
                        if (diamond_idx < 4'd8) begin
                            cand_ox <= {{6{ldx[2]}}, ldx};
                            cand_oy <= {{6{ldy[2]}}, ldy};
                            diamond_idx <= diamond_idx + 4'd1;
                            state <= S_START_CAND;
                        end else begin
                            state <= S_REFINE;
                        end
                    end else begin
                        // Small diamond: 4 points
                        if (diamond_idx < 4'd4) begin
                            cand_ox <= {{6{sdx[2]}}, sdx};
                            cand_oy <= {{6{sdy[2]}}, sdy};
                            diamond_idx <= diamond_idx + 4'd1;
                            state <= S_START_CAND;
                        end else begin
                            state <= S_DONE;
                        end
                    end
                end

                S_REFINE: begin
                    if (iter_improved && iter_count < 5'd16) begin
                        // Move center to best position and repeat large diamond
                        center_x <= iter_best_x;
                        center_y <= iter_best_y;
                        iter_improved <= 1'b0;
                        iter_best_sad <= 18'h3FFFF;
                        diamond_idx <= 4'd0;
                        iter_count <= iter_count + 5'd1;
                        // Test center first
                        cand_ox <= 9'sd0;
                        cand_oy <= 9'sd0;
                        state <= S_START_CAND;
                    end else begin
                        // Switch to small diamond around best
                        center_x <= iter_best_x;
                        center_y <= iter_best_y;
                        use_small_diamond <= 1'b1;
                        iter_best_sad <= best_sad;
                        diamond_idx <= 4'd0;
                        state <= S_NEXT_CAND;
                    end
                end

                S_DONE: begin
                    done <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
