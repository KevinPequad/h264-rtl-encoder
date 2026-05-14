// h264_deblock_mb.v -- combinational per-macroblock H.264 in-loop deblock.
//
// This module filters the current MB after reconstruction and before reference
// writeback. It preserves the H.264 ordering (vertical edge_idxs, then horizontal
// edge_idxs). Left/top p-side patch outputs are provided for MB-boundary filtering;
// callers may tie neighbor availability low when validating single-MB frames.

module h264_deblock_mb #(
    parameter BIT_DEPTH = 8,
    parameter CHROMA_FORMAT_IDC = 1,
    parameter CHR_MB_WIDTH  = (CHROMA_FORMAT_IDC == 3) ? 16 : 8,
    parameter CHR_MB_HEIGHT = (CHROMA_FORMAT_IDC == 1) ? 8 : 16,
    parameter CHR_MB_PIXELS = CHR_MB_WIDTH * CHR_MB_HEIGHT,
    parameter CHR_BLOCK_ROWS = CHR_MB_HEIGHT / 4,
    parameter CHR_BLOCK_COLS = CHR_MB_WIDTH / 4,
    parameter CHR_BLOCKS_PER_PLANE = CHR_BLOCK_ROWS * CHR_BLOCK_COLS
) (
    input  wire deblock_enable,
    input  wire [1:0] disable_deblocking_filter_idc,
    input  wire signed [3:0] slice_alpha_c0_offset_div2,
    input  wire signed [3:0] slice_beta_offset_div2,
    input  wire mb_left_avail,
    input  wire mb_top_avail,
    input  wire cur_is_intra,
    input  wire left_is_intra,
    input  wire top_is_intra,
    input  wire cur_has_l0,
    input  wire cur_has_l1,
    input  wire [1:0] cur_ref_idx_l0,
    input  wire [1:0] cur_ref_idx_l1,
    input  wire signed [7:0] cur_mvx_l0,
    input  wire signed [7:0] cur_mvy_l0,
    input  wire signed [7:0] cur_mvx_l1,
    input  wire signed [7:0] cur_mvy_l1,
    input  wire left_has_l0,
    input  wire left_has_l1,
    input  wire [1:0] left_ref_idx_l0,
    input  wire [1:0] left_ref_idx_l1,
    input  wire signed [7:0] left_mvx_l0,
    input  wire signed [7:0] left_mvy_l0,
    input  wire signed [7:0] left_mvx_l1,
    input  wire signed [7:0] left_mvy_l1,
    input  wire top_has_l0,
    input  wire top_has_l1,
    input  wire [1:0] top_ref_idx_l0,
    input  wire [1:0] top_ref_idx_l1,
    input  wire signed [7:0] top_mvx_l0,
    input  wire signed [7:0] top_mvy_l0,
    input  wire signed [7:0] top_mvx_l1,
    input  wire signed [7:0] top_mvy_l1,
    input  wire [15:0] nz_luma_4x4,
    input  wire [3:0] left_nz_luma_4x4,
    input  wire [3:0] top_nz_luma_4x4,
    input  wire [2*CHR_BLOCKS_PER_PLANE-1:0] nz_chroma_4x4,
    input  wire [CHR_BLOCK_ROWS-1:0] left_nz_chroma_cb,
    input  wire [CHR_BLOCK_ROWS-1:0] left_nz_chroma_cr,
    input  wire [CHR_BLOCK_COLS-1:0] top_nz_chroma_cb,
    input  wire [CHR_BLOCK_COLS-1:0] top_nz_chroma_cr,
    input  wire [256*BIT_DEPTH-1:0] luma_pre,
    input  wire [CHR_MB_PIXELS*BIT_DEPTH-1:0] cb_pre,
    input  wire [CHR_MB_PIXELS*BIT_DEPTH-1:0] cr_pre,
    input  wire [64*BIT_DEPTH-1:0] left_luma_p,
    input  wire [64*BIT_DEPTH-1:0] top_luma_p,
    input  wire [4*CHR_MB_HEIGHT*BIT_DEPTH-1:0] left_cb_p,
    input  wire [4*CHR_MB_HEIGHT*BIT_DEPTH-1:0] left_cr_p,
    input  wire [4*CHR_MB_WIDTH*BIT_DEPTH-1:0] top_cb_p,
    input  wire [4*CHR_MB_WIDTH*BIT_DEPTH-1:0] top_cr_p,
    output reg  [256*BIT_DEPTH-1:0] luma_post,
    output reg  [CHR_MB_PIXELS*BIT_DEPTH-1:0] cb_post,
    output reg  [CHR_MB_PIXELS*BIT_DEPTH-1:0] cr_post,
    output reg  [48*BIT_DEPTH-1:0] left_luma_patch,
    output reg  [48*BIT_DEPTH-1:0] top_luma_patch,
    output reg  [CHR_MB_HEIGHT*BIT_DEPTH-1:0] left_cb_patch,
    output reg  [CHR_MB_HEIGHT*BIT_DEPTH-1:0] left_cr_patch,
    output reg  [CHR_MB_WIDTH*BIT_DEPTH-1:0] top_cb_patch,
    output reg  [CHR_MB_WIDTH*BIT_DEPTH-1:0] top_cr_patch,
    output reg  [15:0] changed_count,
    output reg  [15:0] filtered_edge_count
);
    localparam BD = BIT_DEPTH;

    function automatic integer abs_i;
        input integer v;
        begin abs_i = (v < 0) ? -v : v; end
    endfunction

    function automatic integer clip3_i;
        input integer v;
        input integer lo;
        input integer hi;
        begin
            if (v < lo) clip3_i = lo;
            else if (v > hi) clip3_i = hi;
            else clip3_i = v;
        end
    endfunction

    function automatic [BD-1:0] clip1;
        input integer v;
        integer maxv;
        begin
            maxv = (1 << BD) - 1;
            if (v < 0) clip1 = {BD{1'b0}};
            else if (v > maxv) clip1 = maxv[BD-1:0];
            else clip1 = v[BD-1:0];
        end
    endfunction

    function automatic [3:0] luma_blk_idx;
        input integer br;
        input integer bc;
        begin
            luma_blk_idx = {br[1], bc[1], br[0], bc[0]};
        end
    endfunction

    function automatic integer chroma_blk_idx;
        input integer br;
        input integer bc;
        begin
            chroma_blk_idx = br * CHR_BLOCK_COLS + bc;
        end
    endfunction

    function automatic [5:0] clip_qp_index;
        input integer base_qp;
        input signed [3:0] off_div2;
        integer v;
        begin
            v = base_qp + (off_div2 <<< 1);
            if (v < 0) clip_qp_index = 6'd0;
            else if (v > 51) clip_qp_index = 6'd51;
            else clip_qp_index = v[5:0];
        end
    endfunction

    wire [5:0] index_a_w = clip_qp_index(26, slice_alpha_c0_offset_div2);
    wire [5:0] index_b_w = clip_qp_index(26, slice_beta_offset_div2);
    wire [BD:0] alpha_w;
    wire [BD:0] beta_w;
    wire signed [BD:0] tc0_bs1_w;
    wire signed [BD:0] tc0_bs2_w;
    wire signed [BD:0] tc0_bs3_w;

    h264_deblock_tables #(.BIT_DEPTH(BIT_DEPTH)) u_tables_bs1 (
        .index_a(index_a_w), .index_b(index_b_w), .bs(3'd1), .chroma_edge(1'b0),
        .alpha(alpha_w), .beta(beta_w), .tc0(tc0_bs1_w)
    );
    h264_deblock_tables #(.BIT_DEPTH(BIT_DEPTH)) u_tables_bs2 (
        .index_a(index_a_w), .index_b(index_b_w), .bs(3'd2), .chroma_edge(1'b0),
        .alpha(), .beta(), .tc0(tc0_bs2_w)
    );
    h264_deblock_tables #(.BIT_DEPTH(BIT_DEPTH)) u_tables_bs3 (
        .index_a(index_a_w), .index_b(index_b_w), .bs(3'd3), .chroma_edge(1'b0),
        .alpha(), .beta(), .tc0(tc0_bs3_w)
    );

    function automatic signed [BD:0] tc0_for_bs;
        input [2:0] bs_i;
        begin
            case (bs_i)
                3'd1: tc0_for_bs = tc0_bs1_w;
                3'd2: tc0_for_bs = tc0_bs2_w;
                3'd3: tc0_for_bs = tc0_bs3_w;
                default: tc0_for_bs = {1'b0, {BD{1'b0}}};
            endcase
        end
    endfunction

    function automatic mismatch_list;
        input cur_has;
        input [1:0] cur_ref;
        input signed [7:0] cur_mvx;
        input signed [7:0] cur_mvy;
        input nbr_has;
        input [1:0] nbr_ref;
        input signed [7:0] nbr_mvx;
        input signed [7:0] nbr_mvy;
        begin
            if (cur_has != nbr_has)
                mismatch_list = 1'b1;
            else if (!cur_has)
                mismatch_list = 1'b0;
            else
                mismatch_list = (cur_ref != nbr_ref) || (cur_mvx != nbr_mvx) || (cur_mvy != nbr_mvy);
        end
    endfunction

    function automatic [2:0] bs_mb_boundary_luma;
        input nbr_is_intra;
        input [3:0] nbr_nz_4x4;
        input [3:0] cur_nz_4x4;
        input nbr_has_l0_i;
        input nbr_has_l1_i;
        input [1:0] nbr_ref_idx_l0_i;
        input [1:0] nbr_ref_idx_l1_i;
        input signed [7:0] nbr_mvx_l0_i;
        input signed [7:0] nbr_mvy_l0_i;
        input signed [7:0] nbr_mvx_l1_i;
        input signed [7:0] nbr_mvy_l1_i;
        input cur_has_l0_i;
        input cur_has_l1_i;
        input [1:0] cur_ref_idx_l0_i;
        input [1:0] cur_ref_idx_l1_i;
        input signed [7:0] cur_mvx_l0_i;
        input signed [7:0] cur_mvy_l0_i;
        input signed [7:0] cur_mvx_l1_i;
        input signed [7:0] cur_mvy_l1_i;
        begin
            if (cur_is_intra || nbr_is_intra)
                bs_mb_boundary_luma = 3'd4;
            else if ((nbr_nz_4x4 != 4'b0000) || (cur_nz_4x4 != 4'b0000))
                bs_mb_boundary_luma = 3'd2;
            else if (mismatch_list(cur_has_l0_i, cur_ref_idx_l0_i, cur_mvx_l0_i, cur_mvy_l0_i,
                                   nbr_has_l0_i, nbr_ref_idx_l0_i, nbr_mvx_l0_i, nbr_mvy_l0_i) ||
                     mismatch_list(cur_has_l1_i, cur_ref_idx_l1_i, cur_mvx_l1_i, cur_mvy_l1_i,
                                   nbr_has_l1_i, nbr_ref_idx_l1_i, nbr_mvx_l1_i, nbr_mvy_l1_i))
                bs_mb_boundary_luma = 3'd1;
            else
                bs_mb_boundary_luma = 3'd0;
        end
    endfunction

    function automatic [2:0] bs_mb_boundary_chroma;
        input nbr_is_intra;
        input nbr_has_nz;
        input cur_has_nz;
        input nbr_has_l0_i;
        input nbr_has_l1_i;
        input [1:0] nbr_ref_idx_l0_i;
        input [1:0] nbr_ref_idx_l1_i;
        input signed [7:0] nbr_mvx_l0_i;
        input signed [7:0] nbr_mvy_l0_i;
        input signed [7:0] nbr_mvx_l1_i;
        input signed [7:0] nbr_mvy_l1_i;
        input cur_has_l0_i;
        input cur_has_l1_i;
        input [1:0] cur_ref_idx_l0_i;
        input [1:0] cur_ref_idx_l1_i;
        input signed [7:0] cur_mvx_l0_i;
        input signed [7:0] cur_mvy_l0_i;
        input signed [7:0] cur_mvx_l1_i;
        input signed [7:0] cur_mvy_l1_i;
        begin
            if (cur_is_intra || nbr_is_intra)
                bs_mb_boundary_chroma = 3'd4;
            else if (nbr_has_nz || cur_has_nz)
                bs_mb_boundary_chroma = 3'd2;
            else if (mismatch_list(cur_has_l0_i, cur_ref_idx_l0_i, cur_mvx_l0_i, cur_mvy_l0_i,
                                   nbr_has_l0_i, nbr_ref_idx_l0_i, nbr_mvx_l0_i, nbr_mvy_l0_i) ||
                     mismatch_list(cur_has_l1_i, cur_ref_idx_l1_i, cur_mvx_l1_i, cur_mvy_l1_i,
                                   nbr_has_l1_i, nbr_ref_idx_l1_i, nbr_mvx_l1_i, nbr_mvy_l1_i))
                bs_mb_boundary_chroma = 3'd1;
            else
                bs_mb_boundary_chroma = 3'd0;
        end
    endfunction

    function automatic [6*BD-1:0] filter_edge_idx;
        input [2:0] bs_i;
        input chroma_i;
        input [BD-1:0] p3_i_b;
        input [BD-1:0] p2_i_b;
        input [BD-1:0] p1_i_b;
        input [BD-1:0] p0_i_b;
        input [BD-1:0] q0_i_b;
        input [BD-1:0] q1_i_b;
        input [BD-1:0] q2_i_b;
        input [BD-1:0] q3_i_b;
        integer p3_i;
        integer p2_i;
        integer p1_i;
        integer p0_i;
        integer q0_i;
        integer q1_i;
        integer q2_i;
        integer q3_i;
        integer alpha_i;
        integer beta_i;
        integer tc0_i;
        integer tc_i;
        integer delta_i;
        integer mid_i;
        reg [BD-1:0] p2_o;
        reg [BD-1:0] p1_o;
        reg [BD-1:0] p0_o;
        reg [BD-1:0] q0_o;
        reg [BD-1:0] q1_o;
        reg [BD-1:0] q2_o;
        begin
            p3_i = p3_i_b; p2_i = p2_i_b; p1_i = p1_i_b; p0_i = p0_i_b;
            q0_i = q0_i_b; q1_i = q1_i_b; q2_i = q2_i_b; q3_i = q3_i_b;
            alpha_i = alpha_w; beta_i = beta_w; tc0_i = tc0_for_bs(bs_i);
            p2_o = p2_i_b; p1_o = p1_i_b; p0_o = p0_i_b;
            q0_o = q0_i_b; q1_o = q1_i_b; q2_o = q2_i_b;
            tc_i = 0; delta_i = 0; mid_i = 0;
            if ((bs_i != 3'd0) &&
                (abs_i(p0_i - q0_i) < alpha_i) &&
                (abs_i(p1_i - p0_i) < beta_i) &&
                (abs_i(q1_i - q0_i) < beta_i)) begin
                if (bs_i >= 3'd4) begin
                    if (chroma_i) begin
                        p0_o = clip1((2*p1_i + p0_i + q1_i + 2) >>> 2);
                        q0_o = clip1((2*q1_i + q0_i + p1_i + 2) >>> 2);
                    end else if (abs_i(p0_i - q0_i) < ((alpha_i >>> 2) + 2)) begin
                        if (abs_i(p2_i - p0_i) < beta_i) begin
                            p0_o = clip1((p2_i + 2*p1_i + 2*p0_i + 2*q0_i + q1_i + 4) >>> 3);
                            p1_o = clip1((p2_i + p1_i + p0_i + q0_i + 2) >>> 2);
                            p2_o = clip1((2*p3_i + 3*p2_i + p1_i + p0_i + q0_i + 4) >>> 3);
                        end else begin
                            p0_o = clip1((2*p1_i + p0_i + q1_i + 2) >>> 2);
                        end
                        if (abs_i(q2_i - q0_i) < beta_i) begin
                            q0_o = clip1((p1_i + 2*p0_i + 2*q0_i + 2*q1_i + q2_i + 4) >>> 3);
                            q1_o = clip1((p0_i + q0_i + q1_i + q2_i + 2) >>> 2);
                            q2_o = clip1((2*q3_i + 3*q2_i + q1_i + q0_i + p0_i + 4) >>> 3);
                        end else begin
                            q0_o = clip1((2*q1_i + q0_i + p1_i + 2) >>> 2);
                        end
                    end else begin
                        p0_o = clip1((2*p1_i + p0_i + q1_i + 2) >>> 2);
                        q0_o = clip1((2*q1_i + q0_i + p1_i + 2) >>> 2);
                    end
                end else if (chroma_i) begin
                    if (tc0_i > 0) begin
                        delta_i = clip3_i((((q0_i - p0_i) * 4) + (p1_i - q1_i) + 4) >>> 3, -tc0_i, tc0_i);
                        p0_o = clip1(p0_i + delta_i);
                        q0_o = clip1(q0_i - delta_i);
                    end
                end else begin
                    tc_i = tc0_i;
                    mid_i = (p0_i + q0_i + 1) >>> 1;
                    if (abs_i(p2_i - p0_i) < beta_i) begin
                        if (tc0_i != 0)
                            p1_o = clip1(p1_i + clip3_i(((p2_i + mid_i) >>> 1) - p1_i, -tc0_i, tc0_i));
                        tc_i = tc_i + 1;
                    end
                    if (abs_i(q2_i - q0_i) < beta_i) begin
                        if (tc0_i != 0)
                            q1_o = clip1(q1_i + clip3_i(((q2_i + mid_i) >>> 1) - q1_i, -tc0_i, tc0_i));
                        tc_i = tc_i + 1;
                    end
                    delta_i = clip3_i((((q0_i - p0_i) * 4) + (p1_i - q1_i) + 4) >>> 3, -tc_i, tc_i);
                    p0_o = clip1(p0_i + delta_i);
                    q0_o = clip1(q0_i - delta_i);
                end
            end
            filter_edge_idx = {p2_o, p1_o, p0_o, q0_o, q1_o, q2_o};
        end
    endfunction

    function automatic [2:0] bs_internal_luma;
        input integer br;
        input integer bc_p;
        input integer bc_q;
        reg [3:0] idx_p;
        reg [3:0] idx_q;
        begin
            idx_p = luma_blk_idx(br, bc_p);
            idx_q = luma_blk_idx(br, bc_q);
            if (cur_is_intra)
                bs_internal_luma = 3'd3;
            else if (nz_luma_4x4[idx_p] || nz_luma_4x4[idx_q])
                bs_internal_luma = 3'd2;
            else
                bs_internal_luma = 3'd0;
        end
    endfunction

    function automatic [2:0] bs_internal_chroma;
        input integer br;
        input integer bc_p;
        input integer bc_q;
        input integer plane_off;
        integer idx_p;
        integer idx_q;
        begin
            idx_p = plane_off + chroma_blk_idx(br, bc_p);
            idx_q = plane_off + chroma_blk_idx(br, bc_q);
            if (cur_is_intra)
                bs_internal_chroma = 3'd3;
            else if (nz_chroma_4x4[idx_p] || nz_chroma_4x4[idx_q])
                bs_internal_chroma = 3'd2;
            else
                bs_internal_chroma = 3'd0;
        end
    endfunction

    reg [BD-1:0] y [0:255];
    reg [BD-1:0] cb [0:CHR_MB_PIXELS-1];
    reg [BD-1:0] cr [0:CHR_MB_PIXELS-1];
    reg [BD-1:0] ly [0:63];
    reg [BD-1:0] ty [0:63];
    reg [BD-1:0] lcb [0:4*CHR_MB_HEIGHT-1];
    reg [BD-1:0] lcr [0:4*CHR_MB_HEIGHT-1];
    reg [BD-1:0] tcb [0:4*CHR_MB_WIDTH-1];
    reg [BD-1:0] tcr [0:4*CHR_MB_WIDTH-1];
    reg [6*BD-1:0] eout;
    reg [2:0] bs_cur;
    integer i;
    integer r;
    integer c;
    integer seg;
    integer d;
    integer edge_idx;
    integer idx;
    integer changed_i;
    integer edge_idxs_i;

    always @(*) begin
        for (i = 0; i < 256; i = i + 1)
            y[i] = luma_pre[i*BD +: BD];
        for (i = 0; i < CHR_MB_PIXELS; i = i + 1) begin
            cb[i] = cb_pre[i*BD +: BD];
            cr[i] = cr_pre[i*BD +: BD];
        end
        for (i = 0; i < 64; i = i + 1) begin
            ly[i] = left_luma_p[i*BD +: BD];
            ty[i] = top_luma_p[i*BD +: BD];
        end
        for (i = 0; i < 4*CHR_MB_HEIGHT; i = i + 1) begin
            lcb[i] = left_cb_p[i*BD +: BD];
            lcr[i] = left_cr_p[i*BD +: BD];
        end
        for (i = 0; i < 4*CHR_MB_WIDTH; i = i + 1) begin
            tcb[i] = top_cb_p[i*BD +: BD];
            tcr[i] = top_cr_p[i*BD +: BD];
        end
        left_luma_patch = {(48*BD){1'b0}};
        top_luma_patch = {(48*BD){1'b0}};
        left_cb_patch = {(CHR_MB_HEIGHT*BD){1'b0}};
        left_cr_patch = {(CHR_MB_HEIGHT*BD){1'b0}};
        top_cb_patch = {(CHR_MB_WIDTH*BD){1'b0}};
        top_cr_patch = {(CHR_MB_WIDTH*BD){1'b0}};
        changed_i = 0;
        edge_idxs_i = 0;

        if (deblock_enable && (disable_deblocking_filter_idc != 2'd1)) begin
            // Vertical luma MB boundary against left neighbour.
            if (mb_left_avail) begin
                for (r = 0; r < 16; r = r + 1) begin
                    seg = r >> 2;
                    bs_cur = bs_mb_boundary_luma(
                                 left_is_intra,
                                 left_nz_luma_4x4,
                                 {3'b000, nz_luma_4x4[luma_blk_idx(seg, 0)]},
                                 left_has_l0, left_has_l1,
                                 left_ref_idx_l0, left_ref_idx_l1,
                                 left_mvx_l0, left_mvy_l0,
                                 left_mvx_l1, left_mvy_l1,
                                 cur_has_l0, cur_has_l1,
                                 cur_ref_idx_l0, cur_ref_idx_l1,
                                 cur_mvx_l0, cur_mvy_l0,
                                 cur_mvx_l1, cur_mvy_l1
                             );
                    eout = filter_edge_idx(bs_cur, 1'b0,
                                       ly[r*4 + 0], ly[r*4 + 1], ly[r*4 + 2], ly[r*4 + 3],
                                       y[r*16 + 0], y[r*16 + 1], y[r*16 + 2], y[r*16 + 3]);
                    left_luma_patch[(r*3 + 0)*BD +: BD] = eout[6*BD-1 -: BD];
                    left_luma_patch[(r*3 + 1)*BD +: BD] = eout[5*BD-1 -: BD];
                    left_luma_patch[(r*3 + 2)*BD +: BD] = eout[4*BD-1 -: BD];
                    y[r*16 + 0] = eout[3*BD-1 -: BD];
                    y[r*16 + 1] = eout[2*BD-1 -: BD];
                    y[r*16 + 2] = eout[1*BD-1 -: BD];
                    if (bs_cur != 3'd0) edge_idxs_i = edge_idxs_i + 1;
                end
            end

            // Internal vertical luma edge_idxs x=4,8,12.
            for (edge_idx = 1; edge_idx < 4; edge_idx = edge_idx + 1) begin
                c = edge_idx * 4;
                for (r = 0; r < 16; r = r + 1) begin
                    seg = r >> 2;
                    bs_cur = bs_internal_luma(seg, edge_idx-1, edge_idx);
                    eout = filter_edge_idx(bs_cur, 1'b0,
                                       y[r*16 + c - 4], y[r*16 + c - 3], y[r*16 + c - 2], y[r*16 + c - 1],
                                       y[r*16 + c], y[r*16 + c + 1], y[r*16 + c + 2], y[r*16 + c + 3]);
                    y[r*16 + c - 3] = eout[6*BD-1 -: BD];
                    y[r*16 + c - 2] = eout[5*BD-1 -: BD];
                    y[r*16 + c - 1] = eout[4*BD-1 -: BD];
                    y[r*16 + c]     = eout[3*BD-1 -: BD];
                    y[r*16 + c + 1] = eout[2*BD-1 -: BD];
                    y[r*16 + c + 2] = eout[1*BD-1 -: BD];
                    if (bs_cur != 3'd0) edge_idxs_i = edge_idxs_i + 1;
                end
            end

            // Vertical chroma edge_idxs: left boundary and internal x=4/8/12 as applicable.
            if (mb_left_avail) begin
                for (r = 0; r < CHR_MB_HEIGHT; r = r + 1) begin
                    seg = r >> 2;
                    bs_cur = bs_mb_boundary_chroma(
                                 left_is_intra,
                                 left_nz_chroma_cb[seg],
                                 nz_chroma_4x4[chroma_blk_idx(seg, 0)],
                                 left_has_l0, left_has_l1,
                                 left_ref_idx_l0, left_ref_idx_l1,
                                 left_mvx_l0, left_mvy_l0,
                                 left_mvx_l1, left_mvy_l1,
                                 cur_has_l0, cur_has_l1,
                                 cur_ref_idx_l0, cur_ref_idx_l1,
                                 cur_mvx_l0, cur_mvy_l0,
                                 cur_mvx_l1, cur_mvy_l1
                             );
                    eout = filter_edge_idx(bs_cur, (CHROMA_FORMAT_IDC != 3),
                                       lcb[r*4 + 0], lcb[r*4 + 1], lcb[r*4 + 2], lcb[r*4 + 3],
                                       cb[r*CHR_MB_WIDTH + 0], cb[r*CHR_MB_WIDTH + 1], cb[r*CHR_MB_WIDTH + 2], cb[r*CHR_MB_WIDTH + 3]);
                    left_cb_patch[r*BD +: BD] = eout[4*BD-1 -: BD];
                    cb[r*CHR_MB_WIDTH + 0] = eout[3*BD-1 -: BD];
                    cb[r*CHR_MB_WIDTH + 1] = eout[2*BD-1 -: BD];
                    cb[r*CHR_MB_WIDTH + 2] = eout[1*BD-1 -: BD];
                    bs_cur = bs_mb_boundary_chroma(
                                 left_is_intra,
                                 left_nz_chroma_cr[seg],
                                 nz_chroma_4x4[CHR_BLOCKS_PER_PLANE + chroma_blk_idx(seg, 0)],
                                 left_has_l0, left_has_l1,
                                 left_ref_idx_l0, left_ref_idx_l1,
                                 left_mvx_l0, left_mvy_l0,
                                 left_mvx_l1, left_mvy_l1,
                                 cur_has_l0, cur_has_l1,
                                 cur_ref_idx_l0, cur_ref_idx_l1,
                                 cur_mvx_l0, cur_mvy_l0,
                                 cur_mvx_l1, cur_mvy_l1
                             );
                    eout = filter_edge_idx(bs_cur, (CHROMA_FORMAT_IDC != 3),
                                       lcr[r*4 + 0], lcr[r*4 + 1], lcr[r*4 + 2], lcr[r*4 + 3],
                                       cr[r*CHR_MB_WIDTH + 0], cr[r*CHR_MB_WIDTH + 1], cr[r*CHR_MB_WIDTH + 2], cr[r*CHR_MB_WIDTH + 3]);
                    left_cr_patch[r*BD +: BD] = eout[4*BD-1 -: BD];
                    cr[r*CHR_MB_WIDTH + 0] = eout[3*BD-1 -: BD];
                    cr[r*CHR_MB_WIDTH + 1] = eout[2*BD-1 -: BD];
                    cr[r*CHR_MB_WIDTH + 2] = eout[1*BD-1 -: BD];
                end
            end
            for (edge_idx = 1; edge_idx < CHR_BLOCK_COLS; edge_idx = edge_idx + 1) begin
                c = edge_idx * 4;
                for (r = 0; r < CHR_MB_HEIGHT; r = r + 1) begin
                    seg = r >> 2;
                    bs_cur = bs_internal_chroma(seg, edge_idx-1, edge_idx, 0);
                    eout = filter_edge_idx(bs_cur, (CHROMA_FORMAT_IDC != 3),
                                       cb[r*CHR_MB_WIDTH + c - 4], cb[r*CHR_MB_WIDTH + c - 3], cb[r*CHR_MB_WIDTH + c - 2], cb[r*CHR_MB_WIDTH + c - 1],
                                       cb[r*CHR_MB_WIDTH + c], cb[r*CHR_MB_WIDTH + c + 1], cb[r*CHR_MB_WIDTH + c + 2], cb[r*CHR_MB_WIDTH + c + 3]);
                    cb[r*CHR_MB_WIDTH + c - 3] = eout[6*BD-1 -: BD];
                    cb[r*CHR_MB_WIDTH + c - 2] = eout[5*BD-1 -: BD];
                    cb[r*CHR_MB_WIDTH + c - 1] = eout[4*BD-1 -: BD];
                    cb[r*CHR_MB_WIDTH + c]     = eout[3*BD-1 -: BD];
                    cb[r*CHR_MB_WIDTH + c + 1] = eout[2*BD-1 -: BD];
                    cb[r*CHR_MB_WIDTH + c + 2] = eout[1*BD-1 -: BD];
                    bs_cur = bs_internal_chroma(seg, edge_idx-1, edge_idx, CHR_BLOCKS_PER_PLANE);
                    eout = filter_edge_idx(bs_cur, (CHROMA_FORMAT_IDC != 3),
                                       cr[r*CHR_MB_WIDTH + c - 4], cr[r*CHR_MB_WIDTH + c - 3], cr[r*CHR_MB_WIDTH + c - 2], cr[r*CHR_MB_WIDTH + c - 1],
                                       cr[r*CHR_MB_WIDTH + c], cr[r*CHR_MB_WIDTH + c + 1], cr[r*CHR_MB_WIDTH + c + 2], cr[r*CHR_MB_WIDTH + c + 3]);
                    cr[r*CHR_MB_WIDTH + c - 3] = eout[6*BD-1 -: BD];
                    cr[r*CHR_MB_WIDTH + c - 2] = eout[5*BD-1 -: BD];
                    cr[r*CHR_MB_WIDTH + c - 1] = eout[4*BD-1 -: BD];
                    cr[r*CHR_MB_WIDTH + c]     = eout[3*BD-1 -: BD];
                    cr[r*CHR_MB_WIDTH + c + 1] = eout[2*BD-1 -: BD];
                    cr[r*CHR_MB_WIDTH + c + 2] = eout[1*BD-1 -: BD];
                end
            end

            // Horizontal luma MB boundary against top neighbour.
            if (mb_top_avail) begin
                for (c = 0; c < 16; c = c + 1) begin
                    seg = c >> 2;
                    bs_cur = bs_mb_boundary_luma(
                                 top_is_intra,
                                 top_nz_luma_4x4,
                                 {3'b000, nz_luma_4x4[luma_blk_idx(0, seg)]},
                                 top_has_l0, top_has_l1,
                                 top_ref_idx_l0, top_ref_idx_l1,
                                 top_mvx_l0, top_mvy_l0,
                                 top_mvx_l1, top_mvy_l1,
                                 cur_has_l0, cur_has_l1,
                                 cur_ref_idx_l0, cur_ref_idx_l1,
                                 cur_mvx_l0, cur_mvy_l0,
                                 cur_mvx_l1, cur_mvy_l1
                             );
                    eout = filter_edge_idx(bs_cur, 1'b0,
                                       ty[0*16 + c], ty[1*16 + c], ty[2*16 + c], ty[3*16 + c],
                                       y[0*16 + c], y[1*16 + c], y[2*16 + c], y[3*16 + c]);
                    top_luma_patch[(0*16 + c)*BD +: BD] = eout[6*BD-1 -: BD];
                    top_luma_patch[(1*16 + c)*BD +: BD] = eout[5*BD-1 -: BD];
                    top_luma_patch[(2*16 + c)*BD +: BD] = eout[4*BD-1 -: BD];
                    y[0*16 + c] = eout[3*BD-1 -: BD];
                    y[1*16 + c] = eout[2*BD-1 -: BD];
                    y[2*16 + c] = eout[1*BD-1 -: BD];
                    if (bs_cur != 3'd0) edge_idxs_i = edge_idxs_i + 1;
                end
            end

            // Internal horizontal luma edge_idxs y=4,8,12.
            for (edge_idx = 1; edge_idx < 4; edge_idx = edge_idx + 1) begin
                r = edge_idx * 4;
                for (c = 0; c < 16; c = c + 1) begin
                    seg = c >> 2;
                    bs_cur = bs_internal_luma(edge_idx-1, seg, seg);
                    eout = filter_edge_idx(bs_cur, 1'b0,
                                       y[(r-4)*16 + c], y[(r-3)*16 + c], y[(r-2)*16 + c], y[(r-1)*16 + c],
                                       y[r*16 + c], y[(r+1)*16 + c], y[(r+2)*16 + c], y[(r+3)*16 + c]);
                    y[(r-3)*16 + c] = eout[6*BD-1 -: BD];
                    y[(r-2)*16 + c] = eout[5*BD-1 -: BD];
                    y[(r-1)*16 + c] = eout[4*BD-1 -: BD];
                    y[r*16 + c]     = eout[3*BD-1 -: BD];
                    y[(r+1)*16 + c] = eout[2*BD-1 -: BD];
                    y[(r+2)*16 + c] = eout[1*BD-1 -: BD];
                    if (bs_cur != 3'd0) edge_idxs_i = edge_idxs_i + 1;
                end
            end

            // Horizontal chroma edge_idxs.
            if (mb_top_avail) begin
                for (c = 0; c < CHR_MB_WIDTH; c = c + 1) begin
                    seg = c >> 2;
                    bs_cur = bs_mb_boundary_chroma(
                                 top_is_intra,
                                 top_nz_chroma_cb[seg],
                                 nz_chroma_4x4[chroma_blk_idx(0, seg)],
                                 top_has_l0, top_has_l1,
                                 top_ref_idx_l0, top_ref_idx_l1,
                                 top_mvx_l0, top_mvy_l0,
                                 top_mvx_l1, top_mvy_l1,
                                 cur_has_l0, cur_has_l1,
                                 cur_ref_idx_l0, cur_ref_idx_l1,
                                 cur_mvx_l0, cur_mvy_l0,
                                 cur_mvx_l1, cur_mvy_l1
                             );
                    eout = filter_edge_idx(bs_cur, (CHROMA_FORMAT_IDC != 3),
                                       tcb[0*CHR_MB_WIDTH + c], tcb[1*CHR_MB_WIDTH + c], tcb[2*CHR_MB_WIDTH + c], tcb[3*CHR_MB_WIDTH + c],
                                       cb[0*CHR_MB_WIDTH + c], cb[1*CHR_MB_WIDTH + c], cb[2*CHR_MB_WIDTH + c], cb[3*CHR_MB_WIDTH + c]);
                    top_cb_patch[c*BD +: BD] = eout[4*BD-1 -: BD];
                    cb[0*CHR_MB_WIDTH + c] = eout[3*BD-1 -: BD];
                    cb[1*CHR_MB_WIDTH + c] = eout[2*BD-1 -: BD];
                    cb[2*CHR_MB_WIDTH + c] = eout[1*BD-1 -: BD];
                    bs_cur = bs_mb_boundary_chroma(
                                 top_is_intra,
                                 top_nz_chroma_cr[seg],
                                 nz_chroma_4x4[CHR_BLOCKS_PER_PLANE + chroma_blk_idx(0, seg)],
                                 top_has_l0, top_has_l1,
                                 top_ref_idx_l0, top_ref_idx_l1,
                                 top_mvx_l0, top_mvy_l0,
                                 top_mvx_l1, top_mvy_l1,
                                 cur_has_l0, cur_has_l1,
                                 cur_ref_idx_l0, cur_ref_idx_l1,
                                 cur_mvx_l0, cur_mvy_l0,
                                 cur_mvx_l1, cur_mvy_l1
                             );
                    eout = filter_edge_idx(bs_cur, (CHROMA_FORMAT_IDC != 3),
                                       tcr[0*CHR_MB_WIDTH + c], tcr[1*CHR_MB_WIDTH + c], tcr[2*CHR_MB_WIDTH + c], tcr[3*CHR_MB_WIDTH + c],
                                       cr[0*CHR_MB_WIDTH + c], cr[1*CHR_MB_WIDTH + c], cr[2*CHR_MB_WIDTH + c], cr[3*CHR_MB_WIDTH + c]);
                    top_cr_patch[c*BD +: BD] = eout[4*BD-1 -: BD];
                    cr[0*CHR_MB_WIDTH + c] = eout[3*BD-1 -: BD];
                    cr[1*CHR_MB_WIDTH + c] = eout[2*BD-1 -: BD];
                    cr[2*CHR_MB_WIDTH + c] = eout[1*BD-1 -: BD];
                end
            end
            for (edge_idx = 1; edge_idx < CHR_BLOCK_ROWS; edge_idx = edge_idx + 1) begin
                r = edge_idx * 4;
                for (c = 0; c < CHR_MB_WIDTH; c = c + 1) begin
                    seg = c >> 2;
                    bs_cur = bs_internal_chroma(edge_idx-1, seg, seg, 0);
                    eout = filter_edge_idx(bs_cur, (CHROMA_FORMAT_IDC != 3),
                                       cb[(r-4)*CHR_MB_WIDTH + c], cb[(r-3)*CHR_MB_WIDTH + c], cb[(r-2)*CHR_MB_WIDTH + c], cb[(r-1)*CHR_MB_WIDTH + c],
                                       cb[r*CHR_MB_WIDTH + c], cb[(r+1)*CHR_MB_WIDTH + c], cb[(r+2)*CHR_MB_WIDTH + c], cb[(r+3)*CHR_MB_WIDTH + c]);
                    cb[(r-3)*CHR_MB_WIDTH + c] = eout[6*BD-1 -: BD];
                    cb[(r-2)*CHR_MB_WIDTH + c] = eout[5*BD-1 -: BD];
                    cb[(r-1)*CHR_MB_WIDTH + c] = eout[4*BD-1 -: BD];
                    cb[r*CHR_MB_WIDTH + c]     = eout[3*BD-1 -: BD];
                    cb[(r+1)*CHR_MB_WIDTH + c] = eout[2*BD-1 -: BD];
                    cb[(r+2)*CHR_MB_WIDTH + c] = eout[1*BD-1 -: BD];
                    bs_cur = bs_internal_chroma(edge_idx-1, seg, seg, CHR_BLOCKS_PER_PLANE);
                    eout = filter_edge_idx(bs_cur, (CHROMA_FORMAT_IDC != 3),
                                       cr[(r-4)*CHR_MB_WIDTH + c], cr[(r-3)*CHR_MB_WIDTH + c], cr[(r-2)*CHR_MB_WIDTH + c], cr[(r-1)*CHR_MB_WIDTH + c],
                                       cr[r*CHR_MB_WIDTH + c], cr[(r+1)*CHR_MB_WIDTH + c], cr[(r+2)*CHR_MB_WIDTH + c], cr[(r+3)*CHR_MB_WIDTH + c]);
                    cr[(r-3)*CHR_MB_WIDTH + c] = eout[6*BD-1 -: BD];
                    cr[(r-2)*CHR_MB_WIDTH + c] = eout[5*BD-1 -: BD];
                    cr[(r-1)*CHR_MB_WIDTH + c] = eout[4*BD-1 -: BD];
                    cr[r*CHR_MB_WIDTH + c]     = eout[3*BD-1 -: BD];
                    cr[(r+1)*CHR_MB_WIDTH + c] = eout[2*BD-1 -: BD];
                    cr[(r+2)*CHR_MB_WIDTH + c] = eout[1*BD-1 -: BD];
                end
            end
        end

        for (i = 0; i < 256; i = i + 1) begin
            luma_post[i*BD +: BD] = y[i];
            if (y[i] != luma_pre[i*BD +: BD]) changed_i = changed_i + 1;
        end
        for (i = 0; i < CHR_MB_PIXELS; i = i + 1) begin
            cb_post[i*BD +: BD] = cb[i];
            cr_post[i*BD +: BD] = cr[i];
            if (cb[i] != cb_pre[i*BD +: BD]) changed_i = changed_i + 1;
            if (cr[i] != cr_pre[i*BD +: BD]) changed_i = changed_i + 1;
        end
        changed_count = changed_i[15:0];
        filtered_edge_count = edge_idxs_i[15:0];
    end
endmodule
