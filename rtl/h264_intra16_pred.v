module h264_intra16_pred #(
    parameter BIT_DEPTH = 8
) (
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      start,
    output reg                       done,
    input  wire                      top_avail,
    input  wire                      left_avail,
    input  wire                      top_left_avail,
    input  wire [BIT_DEPTH-1:0]      top_left,
    input  wire [256*BIT_DEPTH-1:0]  orig_16x16,
    input  wire [16*BIT_DEPTH-1:0]   top_16,
    input  wire [16*BIT_DEPTH-1:0]   left_16,
    output reg  [256*BIT_DEPTH-1:0]  pred_16x16,
    output reg  [1:0]                pred_mode,
    output reg  [BIT_DEPTH+8:0]      best_sad
);

    localparam BD = BIT_DEPTH;
    localparam SAD_W = BIT_DEPTH + 9;
    localparam signed [BD+12:0] MAX_PIX = {1'b0, {BD{1'b1}}, {(13-BD){1'b0}}};

    localparam [1:0] MODE_VERT  = 2'd0;
    localparam [1:0] MODE_HOR   = 2'd1;
    localparam [1:0] MODE_DC    = 2'd2;
    localparam [1:0] MODE_PLANE = 2'd3;

    wire [BD-1:0] orig_pix [0:255];
    wire [BD-1:0] top_pix [0:15];
    wire [BD-1:0] left_pix [0:15];

    reg [256*BD-1:0] pred_vert_c;
    reg [256*BD-1:0] pred_hor_c;
    reg [256*BD-1:0] pred_dc_c;
    reg [256*BD-1:0] pred_plane_c;
    reg [256*BD-1:0] best_pred_c;

    reg [SAD_W-1:0] sad_vert_c;
    reg [SAD_W-1:0] sad_hor_c;
    reg [SAD_W-1:0] sad_dc_c;
    reg [SAD_W-1:0] sad_plane_c;
    reg [SAD_W-1:0] best_sad_c;
    reg [1:0]       best_mode_c;

    reg [BD+4:0] sum_top_c;
    reg [BD+4:0] sum_left_c;
    reg [BD-1:0] dc_val_c;

    reg signed [BD+10:0] h_grad_c;
    reg signed [BD+10:0] v_grad_c;
    reg signed [BD+7:0]  b_c;
    reg signed [BD+7:0]  c_c;
    reg signed [BD+6:0]  a_c;
    reg signed [BD+13:0] plane_sum_c;

    reg [BD-1:0] pred_pix_c;
    reg [BD-1:0] orig_pix_c;
    reg [BD:0]   abs_diff_c;
    reg signed [BD+12:0] clipped_plane_c;

    integer idx;
    integer row_idx;
    integer col_idx;
    integer flat_idx;
    integer grad_idx;

    genvar gi;
    generate
        for (gi = 0; gi < 256; gi = gi + 1) begin : unpack_orig
            assign orig_pix[gi] = orig_16x16[gi*BD +: BD];
        end
        for (gi = 0; gi < 16; gi = gi + 1) begin : unpack_neighbors
            assign top_pix[gi] = top_16[gi*BD +: BD];
            assign left_pix[gi] = left_16[gi*BD +: BD];
        end
    endgenerate

    always @(*) begin
        sum_top_c = {(BD+5){1'b0}};
        sum_left_c = {(BD+5){1'b0}};
        for (idx = 0; idx < 16; idx = idx + 1) begin
            if (top_avail)
                sum_top_c = sum_top_c + {{5{1'b0}}, top_pix[idx]};
            if (left_avail)
                sum_left_c = sum_left_c + {{5{1'b0}}, left_pix[idx]};
        end

        if (top_avail && left_avail)
            dc_val_c = (sum_top_c + sum_left_c + {{(BD+1){1'b0}}, 5'd16}) >> 5;
        else if (top_avail)
            dc_val_c = (sum_top_c + {{(BD+2){1'b0}}, 4'd8}) >> 4;
        else if (left_avail)
            dc_val_c = (sum_left_c + {{(BD+2){1'b0}}, 4'd8}) >> 4;
        else
            dc_val_c = {1'b1, {(BD-1){1'b0}}};

        h_grad_c = {(BD+11){1'b0}};
        v_grad_c = {(BD+11){1'b0}};
        for (grad_idx = 0; grad_idx < 8; grad_idx = grad_idx + 1) begin
            if (top_avail)
                h_grad_c = h_grad_c + $signed({1'b0, (grad_idx + 1), {(BD+2){1'b0}}}) *
                           ($signed({1'b0, top_pix[8 + grad_idx]}) - $signed({1'b0, top_pix[6 - grad_idx]}));
            if (left_avail)
                v_grad_c = v_grad_c + $signed({1'b0, (grad_idx + 1), {(BD+2){1'b0}}}) *
                           ($signed({1'b0, left_pix[8 + grad_idx]}) - $signed({1'b0, left_pix[6 - grad_idx]}));
        end

        a_c = $signed({1'b0, left_pix[15]}) + $signed({1'b0, top_pix[15]});
        a_c = a_c <<< 4;
        b_c = ((h_grad_c * 5) + $signed(11'sd32)) >>> 6;
        c_c = ((v_grad_c * 5) + $signed(11'sd32)) >>> 6;

        pred_vert_c = {(256*BD){1'b0}};
        pred_hor_c = {(256*BD){1'b0}};
        pred_dc_c = {(256*BD){1'b0}};
        pred_plane_c = {(256*BD){1'b0}};

        sad_vert_c = {SAD_W{1'b1}};
        sad_hor_c = {SAD_W{1'b1}};
        sad_dc_c = {SAD_W{1'b0}};
        sad_plane_c = {SAD_W{1'b1}};

        for (row_idx = 0; row_idx < 16; row_idx = row_idx + 1) begin
            for (col_idx = 0; col_idx < 16; col_idx = col_idx + 1) begin
                flat_idx = row_idx * 16 + col_idx;
                orig_pix_c = orig_pix[flat_idx];

                pred_pix_c = top_avail ? top_pix[col_idx] : {BD{1'b0}};
                pred_vert_c[flat_idx*BD +: BD] = pred_pix_c;
                if (orig_pix_c >= pred_pix_c)
                    abs_diff_c = {1'b0, orig_pix_c} - {1'b0, pred_pix_c};
                else
                    abs_diff_c = {1'b0, pred_pix_c} - {1'b0, orig_pix_c};
                if (top_avail)
                    sad_vert_c = sad_vert_c + abs_diff_c[SAD_W-1:0];

                pred_pix_c = left_avail ? left_pix[row_idx] : {BD{1'b0}};
                pred_hor_c[flat_idx*BD +: BD] = pred_pix_c;
                if (orig_pix_c >= pred_pix_c)
                    abs_diff_c = {1'b0, orig_pix_c} - {1'b0, pred_pix_c};
                else
                    abs_diff_c = {1'b0, pred_pix_c} - {1'b0, orig_pix_c};
                if (left_avail)
                    sad_hor_c = sad_hor_c + abs_diff_c[SAD_W-1:0];

                pred_pix_c = dc_val_c;
                pred_dc_c[flat_idx*BD +: BD] = pred_pix_c;
                if (orig_pix_c >= pred_pix_c)
                    abs_diff_c = {1'b0, orig_pix_c} - {1'b0, pred_pix_c};
                else
                    abs_diff_c = {1'b0, pred_pix_c} - {1'b0, orig_pix_c};
                sad_dc_c = sad_dc_c + abs_diff_c[SAD_W-1:0];

                plane_sum_c = a_c + b_c * $signed(col_idx - 7) + c_c * $signed(row_idx - 7) + $signed(14'sd16);
                clipped_plane_c = plane_sum_c >>> 5;
                if (clipped_plane_c < 0)
                    pred_pix_c = {BD{1'b0}};
                else if (clipped_plane_c > $signed({1'b0, {BD{1'b1}}}))
                    pred_pix_c = {BD{1'b1}};
                else
                    pred_pix_c = clipped_plane_c[BD-1:0];
                pred_plane_c[flat_idx*BD +: BD] = pred_pix_c;
                if (orig_pix_c >= pred_pix_c)
                    abs_diff_c = {1'b0, orig_pix_c} - {1'b0, pred_pix_c};
                else
                    abs_diff_c = {1'b0, pred_pix_c} - {1'b0, orig_pix_c};
                if (top_avail && left_avail && top_left_avail)
                    sad_plane_c = sad_plane_c + abs_diff_c[SAD_W-1:0];
            end
        end

        best_mode_c = MODE_DC;
        best_sad_c = sad_dc_c;
        best_pred_c = pred_dc_c;

        if (top_avail && (sad_vert_c < best_sad_c)) begin
            best_mode_c = MODE_VERT;
            best_sad_c = sad_vert_c;
            best_pred_c = pred_vert_c;
        end

        if (left_avail && (sad_hor_c < best_sad_c)) begin
            best_mode_c = MODE_HOR;
            best_sad_c = sad_hor_c;
            best_pred_c = pred_hor_c;
        end

        if (top_avail && left_avail && top_left_avail && (sad_plane_c < best_sad_c)) begin
            best_mode_c = MODE_PLANE;
            best_sad_c = sad_plane_c;
            best_pred_c = pred_plane_c;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done <= 1'b0;
            pred_16x16 <= {(256*BD){1'b0}};
            pred_mode <= MODE_DC;
            best_sad <= {SAD_W{1'b0}};
        end else begin
            done <= 1'b0;
            if (start) begin
                pred_16x16 <= best_pred_c;
                pred_mode <= best_mode_c;
                best_sad <= best_sad_c;
                done <= 1'b1;
            end
        end
    end

endmodule
