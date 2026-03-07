// h264_reconstruct.v — Pixel Reconstruction
// Adds reconstructed residual to prediction, clips to [0,255]
// Processes one 4x4 sub-block at a time (call 16 times per MB)
// Stores reconstructed pixels and extracts top row / right column for neighbors

module h264_reconstruct (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    output reg         done,

    // Which 4x4 sub-block (0..15) in raster order within 16x16 MB
    input  wire [3:0]  sub_block_idx,

    // Predicted block (full 16x16, 2048 bits)
    input  wire [2047:0] pred_flat,

    // Reconstructed residual (one 4x4 = 16 * 16-bit signed = 256 bits)
    input  wire [255:0] recon_resid_flat,

    // Reconstructed pixels (full 16x16, 2048 bits) — read-modify-write
    input  wire [2047:0] recon_in,
    output reg  [2047:0] recon_out,

    // Bottom row (16 pixels) for top-neighbor of row below
    output reg  [127:0]  recon_top_row,
    // Rightmost column (16 pixels) for left-neighbor of next MB
    output reg  [127:0]  recon_right_col
);

    reg [2:0] state;
    localparam S_IDLE  = 3'd0;
    localparam S_RECON = 3'd1;
    localparam S_DONE  = 3'd2;

    reg [3:0] idx; // 0..15 within sub-block

    // Sub-block position
    wire [1:0] sb_row = {sub_block_idx[3], sub_block_idx[1]};
    wire [1:0] sb_col = {sub_block_idx[2], sub_block_idx[0]};

    reg [3:0] pix_r, pix_c;
    reg [7:0] mb_flat_idx;
    reg signed [15:0] resid_val;
    reg [7:0]  pred_val;
    reg signed [15:0] sum;
    reg [7:0]  clipped;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            done          <= 1'b0;
            idx           <= 4'd0;
            recon_out     <= 2048'd0;
            recon_top_row <= 128'd0;
            recon_right_col <= 128'd0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (start) begin
                        state     <= S_RECON;
                        idx       <= 4'd0;
                        recon_out <= recon_in; // copy current state
                    end
                end

                // verilator lint_off BLKSEQ
                S_RECON: begin
                    pix_r = {sb_row, idx[3:2]};
                    pix_c = {sb_col, idx[1:0]};
                    mb_flat_idx = {pix_r, pix_c}; // raster: row*16+col

                    resid_val = $signed(recon_resid_flat[idx*16 +: 16]);
                    pred_val  = pred_flat[mb_flat_idx*8 +: 8];
                    sum       = $signed({1'b0, 7'd0, pred_val}) + resid_val;

                    if (sum < 16'sd0)
                        clipped = 8'd0;
                    else if (sum > 16'sd255)
                        clipped = 8'd255;
                    else
                        clipped = sum[7:0];

                // verilator lint_on BLKSEQ

                    recon_out[mb_flat_idx*8 +: 8] <= clipped;

                    // Track bottom row (row 15) for top-neighbor
                    if (pix_r == 4'd15)
                        recon_top_row[pix_c*8 +: 8] <= clipped;

                    // Track right column (col 15) for left-neighbor
                    if (pix_c == 4'd15)
                        recon_right_col[pix_r*8 +: 8] <= clipped;

                    if (idx == 4'd15)
                        state <= S_DONE;
                    else
                        idx <= idx + 4'd1;
                end

                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
