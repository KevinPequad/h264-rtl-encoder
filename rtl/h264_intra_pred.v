// h264_intra_pred.v - Intra Prediction (vertical, horizontal, DC, horizontal-up for 4x4)
// Chooses the best supported mode by minimum SAD against the original block.
// Outputs the selected prediction block, residual, and H.264 intra4x4 mode.

module h264_intra_pred #(
    parameter BIT_DEPTH = 8
) (
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      start,
    output reg                       done,
    input  wire                      top_avail,
    input  wire                      left_avail,
    input  wire [16*BIT_DEPTH-1:0]   orig_4x4,
    input  wire [4*BIT_DEPTH-1:0]    top_4,
    input  wire [4*BIT_DEPTH-1:0]    left_4,
    output reg  [16*BIT_DEPTH-1:0]   pred_4x4,
    output reg  [16*(BIT_DEPTH+1)-1:0] resid_4x4,
    output reg  [3:0]                pred_mode
);

    localparam BD  = BIT_DEPTH;
    localparam BD1 = BIT_DEPTH + 1;
    localparam SAD_W = BIT_DEPTH + 5;

    localparam [3:0] MODE_VERT = 4'd0;
    localparam [3:0] MODE_HOR  = 4'd1;
    localparam [3:0] MODE_DC   = 4'd2;
    localparam [3:0] MODE_HU   = 4'd8;

    localparam [BD-1:0] DC_DEFAULT = {1'b1, {(BD-1){1'b0}}};

    wire [BD-1:0] top_pix  [0:3];
    wire [BD-1:0] left_pix [0:3];

    reg [BD+2:0] sum_top_c;
    reg [BD+2:0] sum_left_c;
    reg [BD-1:0] dc_value_c;

    reg [16*BD-1:0] pred_v_c;
    reg [16*BD-1:0] pred_h_c;
    reg [16*BD-1:0] pred_d_c;
    reg [16*BD-1:0] pred_hu_c;
    reg [16*BD1-1:0] resid_v_c;
    reg [16*BD1-1:0] resid_h_c;
    reg [16*BD1-1:0] resid_d_c;
    reg [16*BD1-1:0] resid_hu_c;
    reg [16*BD-1:0] best_pred_c;
    reg [16*BD1-1:0] best_resid_c;

    reg [SAD_W-1:0] sad_v_c;
    reg [SAD_W-1:0] sad_h_c;
    reg [SAD_W-1:0] sad_d_c;
    reg [SAD_W-1:0] sad_hu_c;
    reg [SAD_W-1:0] best_sad_c;
    reg [3:0] best_mode_c;

    integer idx;
    integer row_idx;
    integer col_idx;
    integer flat_idx;

    reg [BD-1:0] orig_pix_c;
    reg [BD-1:0] pred_pix_c;
    reg [BD:0] abs_diff_c;
    reg [2:0] hu_z_c;
    reg [2:0] hu_idx_c;

    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : unpack_neighbors
            assign top_pix[gi]  = top_4[gi*BD +: BD];
            assign left_pix[gi] = left_4[gi*BD +: BD];
        end
    endgenerate

    always @(*) begin
        sum_top_c = {(BD+3){1'b0}};
        sum_left_c = {(BD+3){1'b0}};
        for (idx = 0; idx < 4; idx = idx + 1) begin
            if (top_avail)
                sum_top_c = sum_top_c + {{3{1'b0}}, top_pix[idx]};
            if (left_avail)
                sum_left_c = sum_left_c + {{3{1'b0}}, left_pix[idx]};
        end

        if (top_avail && left_avail)
            dc_value_c = (sum_top_c + sum_left_c + {{(BD+1){1'b0}}, 3'd4}) >> 3;
        else if (top_avail)
            dc_value_c = (sum_top_c + {{(BD+1){1'b0}}, 2'd2}) >> 2;
        else if (left_avail)
            dc_value_c = (sum_left_c + {{(BD+1){1'b0}}, 2'd2}) >> 2;
        else
            dc_value_c = DC_DEFAULT;

        pred_v_c = {(16*BD){1'b0}};
        pred_h_c = {(16*BD){1'b0}};
        pred_d_c = {(16*BD){1'b0}};
        pred_hu_c = {(16*BD){1'b0}};
        resid_v_c = {(16*BD1){1'b0}};
        resid_h_c = {(16*BD1){1'b0}};
        resid_d_c = {(16*BD1){1'b0}};
        resid_hu_c = {(16*BD1){1'b0}};

        sad_v_c = {SAD_W{1'b1}};
        sad_h_c = {SAD_W{1'b1}};
        sad_d_c = {SAD_W{1'b0}};
        sad_hu_c = {SAD_W{1'b1}};

        for (row_idx = 0; row_idx < 4; row_idx = row_idx + 1) begin
            for (col_idx = 0; col_idx < 4; col_idx = col_idx + 1) begin
                flat_idx = row_idx * 4 + col_idx;
                orig_pix_c = orig_4x4[flat_idx*BD +: BD];

                pred_pix_c = top_avail ? top_pix[col_idx] : {BD{1'b0}};
                pred_v_c[flat_idx*BD +: BD] = pred_pix_c;
                resid_v_c[flat_idx*BD1 +: BD1] = {1'b0, orig_pix_c} - {1'b0, pred_pix_c};
                if (orig_pix_c >= pred_pix_c)
                    abs_diff_c = {1'b0, orig_pix_c} - {1'b0, pred_pix_c};
                else
                    abs_diff_c = {1'b0, pred_pix_c} - {1'b0, orig_pix_c};
                if (top_avail)
                    sad_v_c = sad_v_c + abs_diff_c[SAD_W-1:0];

                pred_pix_c = left_avail ? left_pix[row_idx] : {BD{1'b0}};
                pred_h_c[flat_idx*BD +: BD] = pred_pix_c;
                resid_h_c[flat_idx*BD1 +: BD1] = {1'b0, orig_pix_c} - {1'b0, pred_pix_c};
                if (orig_pix_c >= pred_pix_c)
                    abs_diff_c = {1'b0, orig_pix_c} - {1'b0, pred_pix_c};
                else
                    abs_diff_c = {1'b0, pred_pix_c} - {1'b0, orig_pix_c};
                if (left_avail)
                    sad_h_c = sad_h_c + abs_diff_c[SAD_W-1:0];

                pred_pix_c = dc_value_c;
                pred_d_c[flat_idx*BD +: BD] = pred_pix_c;
                resid_d_c[flat_idx*BD1 +: BD1] = {1'b0, orig_pix_c} - {1'b0, pred_pix_c};
                if (orig_pix_c >= pred_pix_c)
                    abs_diff_c = {1'b0, orig_pix_c} - {1'b0, pred_pix_c};
                else
                    abs_diff_c = {1'b0, pred_pix_c} - {1'b0, orig_pix_c};
                sad_d_c = sad_d_c + abs_diff_c[SAD_W-1:0];

                hu_z_c = col_idx[2:0] + {row_idx[1:0], 1'b0};
                hu_idx_c = row_idx[2:0] + {2'b00, col_idx[0]};
                if (hu_z_c == 3'd0 || hu_z_c == 3'd2 || hu_z_c == 3'd4)
                    pred_pix_c = (left_pix[hu_idx_c] + left_pix[hu_idx_c + 3'd1] + 1'b1) >> 1;
                else if (hu_z_c == 3'd1 || hu_z_c == 3'd3)
                    pred_pix_c = (left_pix[hu_idx_c] + (left_pix[hu_idx_c + 3'd1] << 1) + left_pix[hu_idx_c + 3'd2] + 2'd2) >> 2;
                else if (hu_z_c == 3'd5)
                    pred_pix_c = (left_pix[3'd2] + (left_pix[3'd3] * 2'd3) + 2'd2) >> 2;
                else
                    pred_pix_c = left_pix[3'd3];
                pred_hu_c[flat_idx*BD +: BD] = pred_pix_c;
                resid_hu_c[flat_idx*BD1 +: BD1] = {1'b0, orig_pix_c} - {1'b0, pred_pix_c};
                if (orig_pix_c >= pred_pix_c)
                    abs_diff_c = {1'b0, orig_pix_c} - {1'b0, pred_pix_c};
                else
                    abs_diff_c = {1'b0, pred_pix_c} - {1'b0, orig_pix_c};
                if (left_avail)
                    sad_hu_c = sad_hu_c + abs_diff_c[SAD_W-1:0];
            end
        end

        best_mode_c = MODE_DC;
        best_sad_c = sad_d_c;
        best_pred_c = pred_d_c;
        best_resid_c = resid_d_c;

        if (top_avail && (sad_v_c < best_sad_c)) begin
            best_mode_c = MODE_VERT;
            best_sad_c = sad_v_c;
            best_pred_c = pred_v_c;
            best_resid_c = resid_v_c;
        end

        if (left_avail && (sad_h_c < best_sad_c)) begin
            best_mode_c = MODE_HOR;
            best_sad_c = sad_h_c;
            best_pred_c = pred_h_c;
            best_resid_c = resid_h_c;
        end

        if (left_avail && (sad_hu_c < best_sad_c)) begin
            best_mode_c = MODE_HU;
            best_sad_c = sad_hu_c;
            best_pred_c = pred_hu_c;
            best_resid_c = resid_hu_c;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done <= 1'b0;
            pred_4x4 <= {(16*BD){1'b0}};
            resid_4x4 <= {(16*BD1){1'b0}};
            pred_mode <= MODE_DC;
        end else begin
            done <= 1'b0;
            if (start) begin
                pred_4x4 <= best_pred_c;
                resid_4x4 <= best_resid_c;
                pred_mode <= best_mode_c;
                done <= 1'b1;
            end
        end
    end

endmodule
