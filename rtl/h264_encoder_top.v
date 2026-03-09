// h264_encoder_top.v — Top-Level H.264 Encoder (I + P frame support)
// Baseline profile, CAVLC, parameterized resolution, QP=26
// Frame 0 = IDR (I-frame), Frame 1+ = P-frame with motion estimation
// Processes one YUV420 frame in raster macroblock order.
// Pipeline: fetch → [ME for P-frame] → (predict → transform → quant → zigzag → cavlc →
//            inverse_quant → inverse_transform → reconstruct) per sub-block
// Then: bitstream output with SPS/PPS/slice header/trailing bits.

module h264_encoder_top #(
    parameter FRAME_WIDTH  = 320,
    parameter FRAME_HEIGHT = 176,
    parameter BIT_DEPTH    = 8,
    parameter CHROMA_FORMAT_IDC = 1,
    parameter MB_COLS      = FRAME_WIDTH / 16,
    parameter MB_ROWS      = FRAME_HEIGHT / 16
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    output reg         done,

    // Frame number (4-bit, wraps at 16 per H.264 spec)
    input  wire [3:0]  frame_num_in,
    // IDR flag (1 for IDR/I-frame, 0 for P-frame)
    input  wire        is_idr_in,

    // Raw frame memory read port (YUV420 planar)
    output wire [20:0] raw_mem_addr,
    input  wire [BIT_DEPTH-1:0]  raw_mem_data,

    // Reference frame memory (external, luma only)
    output reg  [19:0] ref_mem_rd_addr,
    input  wire [BIT_DEPTH-1:0]  ref_mem_rd_data,
    output reg         ref_mem_wr_en,
    output reg  [19:0] ref_mem_wr_addr,
    output reg  [BIT_DEPTH-1:0]  ref_mem_wr_data,

    // Chroma reference frame memory (external, Cb and Cr)
    output reg  [17:0] chr_cb_ref_rd_addr,
    input  wire [BIT_DEPTH-1:0]  chr_cb_ref_rd_data,
    output reg         chr_cb_ref_wr_en,
    output reg  [17:0] chr_cb_ref_wr_addr,
    output reg  [BIT_DEPTH-1:0]  chr_cb_ref_wr_data,
    output reg  [17:0] chr_cr_ref_rd_addr,
    input  wire [BIT_DEPTH-1:0]  chr_cr_ref_rd_data,
    output reg         chr_cr_ref_wr_en,
    output reg  [17:0] chr_cr_ref_wr_addr,
    output reg  [BIT_DEPTH-1:0]  chr_cr_ref_wr_data,

    // Bitstream memory write port
    output wire [23:0] bs_mem_addr,
    output wire [7:0]  bs_mem_data,
    output wire        bs_mem_wr,
    output wire [23:0] bs_bytes_written
);

    localparam RAW_ADDR_W = 21;
    localparam [RAW_ADDR_W-1:0] FRAME_Y_BASE  = {RAW_ADDR_W{1'b0}};
    localparam [RAW_ADDR_W-1:0] FRAME_CB_BASE = FRAME_WIDTH * FRAME_HEIGHT;
    localparam [RAW_ADDR_W-1:0] FRAME_CR_BASE = FRAME_CB_BASE
                                              + ((CHROMA_FORMAT_IDC == 2) ? (FRAME_WIDTH * FRAME_HEIGHT / 2)
                                                                          : (FRAME_WIDTH * FRAME_HEIGHT / 4));
    localparam CHR_WIDTH            = FRAME_WIDTH / 2;
    localparam CHR_HEIGHT           = (CHROMA_FORMAT_IDC == 2) ? FRAME_HEIGHT : (FRAME_HEIGHT / 2);
    localparam CHR_MB_HEIGHT        = (CHROMA_FORMAT_IDC == 2) ? 16 : 8;
    localparam CHR_MB_PIXELS        = 8 * CHR_MB_HEIGHT;
    localparam CHR_BLOCK_ROWS       = CHR_MB_HEIGHT / 4;
    localparam CHR_BLOCKS_PER_PLANE = 2 * CHR_BLOCK_ROWS;
    localparam CHR_RAW_ROWS_MAX     = (CHROMA_FORMAT_IDC == 2) ? 17 : 9;
    localparam CHR_RAW_COLS_MAX     = 9;
    localparam CHR_RAW_SAMPLES      = CHR_RAW_ROWS_MAX * CHR_RAW_COLS_MAX;
    localparam TOTAL_SUB_BLOCKS     = 16 + 2 * CHR_BLOCKS_PER_PLANE;

    // SAD threshold: if ME SAD > this, use intra instead of inter for this MB
    localparam [17:0] INTRA_SAD_THRESHOLD = 18'd8000;

    // ====================================================================
    // Top-level FSM (5-bit for >16 states)
    // ====================================================================
    localparam TS_IDLE         = 5'd0;
    localparam TS_WRITE_SPS    = 5'd1;
    localparam TS_WAIT_SPS     = 5'd2;
    localparam TS_WRITE_PPS    = 5'd3;
    localparam TS_WAIT_PPS     = 5'd4;
    localparam TS_WRITE_SLICE  = 5'd5;
    localparam TS_WAIT_SLICE   = 5'd6;
    localparam TS_FETCH_MB     = 5'd7;
    localparam TS_WAIT_FETCH   = 5'd8;
    localparam TS_ME_START     = 5'd9;   // Start motion estimation (P-frame only)
    localparam TS_WAIT_ME      = 5'd10;  // Wait for ME completion
    localparam TS_MB_HDR       = 5'd11;
    localparam TS_ENCODE_SBLK  = 5'd12;
    localparam TS_NEXT_MB      = 5'd13;
    localparam TS_REF_WR       = 5'd14;  // Write-back reconstructed luma to ref memory
    localparam TS_TRAILING     = 5'd15;
    localparam TS_DONE         = 5'd16;
    localparam TS_CHROMA       = 5'd17;  // Phased chroma processing
    localparam TS_CHR_FETCH    = 5'd18;  // Fetch inter chroma prediction from reference
    localparam TS_DEFER_MB_HDR = 5'd19;  // Emit buffered intra MB header after full MB encode

    reg [4:0]  top_state;
    reg [6:0]  mb_x;
    reg [5:0]  mb_y;
    reg [4:0]  sub_blk;
    reg [11:0] mb_count;

    // Sub-block processing stages
    localparam BS_PRED     = 3'd0;
    localparam BS_XFORM    = 3'd1;
    localparam BS_QUANT    = 3'd2;
    localparam BS_ZIGZAG   = 3'd3;
    localparam BS_CAVLC    = 3'd4;
    localparam BS_IQ       = 3'd5;
    localparam BS_IT       = 3'd6;
    localparam BS_RECON    = 3'd7;
    reg [2:0]  blk_state;
    reg        blk_started;
    reg        iq_done_latched;

    // ====================================================================
    // P-frame registers
    // ====================================================================
    reg        is_p_frame;         // 1 if current frame is P-frame
    reg        is_inter_mb_reg;    // 1 if current MB uses inter prediction
    reg [3:0]  cur_frame_num;      // Latched frame number
    reg signed [7:0] me_best_mvx;  // Best MV from ME
    reg signed [7:0] me_best_mvy;
    reg [17:0] me_best_sad;

    // Inter prediction buffer: stores the reference block from ME
    reg [256*BIT_DEPTH-1:0] inter_pred_buf;

    // Full-pel MV saved for chroma offset computation
    reg signed [7:0] me_fullpel_mvx, me_fullpel_mvy;

    // Inter chroma prediction buffers (8x8 for 4:2:0, 8x16 for 4:2:2)
    reg [CHR_MB_PIXELS*BIT_DEPTH-1:0] inter_chr_pred_cb, inter_chr_pred_cr;
    reg        inter_chr_mode;     // 1 = inter chroma prediction (vs intra DC)
    reg [7:0]  chr_fetch_cnt;      // Counter for chroma fetch (max 153 samples for 4:2:2)
    reg        chr_fetch_started;  // 1 after initial address setup
    // Chroma half-pel interpolation raw fetch buffers
    reg [CHR_RAW_SAMPLES*BD-1:0] chr_raw_cb, chr_raw_cr;
    reg [2:0]  chr_frac_x, chr_frac_y; // 1/8-pel chroma fraction (0,2,4,6)
    reg [4:0]  chr_fetch_rows; // up to 17 for 4:2:2 fractional
    reg [3:0]  chr_fetch_cols; // 9 if fractional, 8 if integer

    // Reference write-back counter
    reg [8:0]  ref_wr_idx;

    // MV storage for prediction (per-MB row above + left MB)
    reg signed [7:0] top_mvx [0:MB_COLS-1];  // Top row MV x (one per MB column)
    reg signed [7:0] top_mvy [0:MB_COLS-1];  // Top row MV y
    reg signed [7:0] left_mvx;        // Left MB MV x
    reg signed [7:0] left_mvy;        // Left MB MV y
    reg        top_is_inter [0:MB_COLS-1];   // 1 if top MB was inter (ref_idx=0)
    reg        left_is_inter;         // 1 if left MB was inter
    // Diagonal (top-left) saved before top_mvx[mb_x] is overwritten
    reg signed [7:0] diag_mvx, diag_mvy;
    reg        diag_is_inter;

    // MV predictor (median of A, B, C)
    reg signed [7:0] mvp_x, mvp_y;
    // MVD = actual MV - predicted MV (9-bit to avoid overflow: max ±128)
    wire signed [8:0] mvd_x_w = {me_best_mvx[7], me_best_mvx} - {mvp_x[7], mvp_x};
    wire signed [8:0] mvd_y_w = {me_best_mvy[7], me_best_mvy} - {mvp_y[7], mvp_y};

    // ====================================================================
    // Inter-module wires
    // ====================================================================

    // Fetch
    reg         fetch_start;
    wire        fetch_done;
    wire [256*BIT_DEPTH-1:0] fetched_luma;
    /* verilator lint_off UNUSED */
    wire [CHR_MB_PIXELS*BIT_DEPTH-1:0]  fetched_cb;
    wire [CHR_MB_PIXELS*BIT_DEPTH-1:0]  fetched_cr;
    /* verilator lint_on UNUSED */

    // Intra prediction
    reg         pred_start;
    wire        pred_done;
    reg         sb_top_avail, sb_left_avail;
    reg [4*BIT_DEPTH-1:0]  sb_top_pixels;
    reg [4*BIT_DEPTH-1:0]  sb_left_pixels;
    reg [16*BIT_DEPTH-1:0] sb_orig_pixels;
    wire [16*BIT_DEPTH-1:0]      pred_4x4_w;
    wire [16*(BIT_DEPTH+1)-1:0]  resid_4x4_w;
    wire [3:0]                   pred_mode_w;

    // Motion estimation
    reg         me_start;
    wire        me_done;
    wire signed [7:0]  me_mvx_w;
    wire signed [7:0]  me_mvy_w;
    wire [17:0]        me_sad_w;
    wire [256*BIT_DEPTH-1:0] me_ref_mb_w;
    wire [19:0]        me_ref_rd_addr;
    wire [BIT_DEPTH-1:0] me_ref_rd_data_w;

    // Transform
    reg         xform_start;
    wire        xform_done;
    wire [16*CW-1:0] xform_out_flat;

    // Quantize
    reg         quant_start;
    wire        quant_done;
    wire [255:0] quant_out_flat; // quantized levels stay 16-bit

    // Zigzag
    reg         zz_start;
    wire        zz_done;
    wire [255:0] scan_flat;
    wire [4:0]   total_coeffs;
    wire [1:0]   trailing_ones;
    wire [3:0]   last_nonzero_idx;

    // CAVLC
    reg         cavlc_start;
    wire        cavlc_done;
    wire [31:0] cavlc_bits;
    wire [5:0]  cavlc_count;
    wire        cavlc_bits_valid;

    // Inverse quant
    reg         iq_start;
    wire        iq_done;
    wire [16*CW-1:0] iq_out_flat;

    // Inverse transform
    reg         it_start;
    wire        it_done;
    wire [255:0] it_out_flat; // reconstructed residuals stay 16-bit

    // Reconstruct
    reg         recon_start;
    wire        recon_done;
    reg  [256*BIT_DEPTH-1:0] recon_buf;
    wire [256*BIT_DEPTH-1:0] recon_out_w;
    wire [16*BIT_DEPTH-1:0]  recon_top_row_w;
    wire [16*BIT_DEPTH-1:0]  recon_right_col_w;

    // Chroma reconstruction buffers (8x8 for 4:2:0, 8x16 for 4:2:2)
    reg [CHR_MB_PIXELS*BIT_DEPTH-1:0] chr_recon_cb;
    reg [CHR_MB_PIXELS*BIT_DEPTH-1:0] chr_recon_cr;

    // Chroma MB-boundary neighbor storage for 8x8 DC prediction
    // Top neighbors: bottom row (row 7) of above MB's chroma, per MB column
    reg [8*BIT_DEPTH-1:0] top_chr_cb_nb [0:MB_COLS-1];
    reg [8*BIT_DEPTH-1:0] top_chr_cr_nb [0:MB_COLS-1];
    // Left neighbors: right column (col 7) of left MB's chroma
    reg [CHR_MB_HEIGHT*BIT_DEPTH-1:0] left_chr_cb_nb;
    reg [CHR_MB_HEIGHT*BIT_DEPTH-1:0] left_chr_cr_nb;
    // Pre-computed chroma DC prediction values (one per 4x4 sub-block, per plane)
    reg [BIT_DEPTH-1:0] chr_dc_pred [0:CHR_BLOCKS_PER_PLANE-1];
    // Chroma residual override: when in chroma mode, bypass h264_intra_pred
    reg        chr_pred_mode;     // 1 = use chr_dc_pred instead of h264_intra_pred
    reg [16*(BIT_DEPTH+1)-1:0] chr_resid_4x4;   // chroma residual computed directly

    // Bitstream writer
    reg         bs_cmd_sps, bs_cmd_pps, bs_cmd_slice, bs_cmd_mb_hdr, bs_cmd_trailing, bs_cmd_flush;
    wire        bs_busy, bs_cmd_done;
    reg         mb_has_residual;
    reg         bs_hold_fifo_drain;

    // Neighbor storage
    reg [MB_COLS*16*BIT_DEPTH-1:0] top_ref_flat;
    reg [16*BIT_DEPTH-1:0] left_ref_flat;
    reg [16*BIT_DEPTH-1:0] top_pixels_flat, left_pixels_flat;
    reg          mb_top_avail, mb_left_avail;

    // Trailing/flush sequencing
    reg flush_pending, flush_accepted;

    // ====================================================================
    // Mapping and Buffer Extraction
    // ====================================================================
wire is_luma = (sub_blk < 5'd16);
    wire is_cb   = (sub_blk >= 5'd16 && sub_blk < 5'd16 + CHR_BLOCKS_PER_PLANE[4:0]);
    wire is_cr   = (sub_blk >= 5'd16 + CHR_BLOCKS_PER_PLANE[4:0]);
    wire [1:0] sb_r = is_luma ? {sub_blk[3], sub_blk[1]} : (CHROMA_FORMAT_IDC == 2) ? {sub_blk[2], sub_blk[1]} : {1'b0, sub_blk[1]};
    wire [1:0] sb_c = is_luma ? {sub_blk[2], sub_blk[0]} : {1'b0, sub_blk[0]};

    localparam BD = BIT_DEPTH;
    localparam BD1 = BIT_DEPTH + 1;
    localparam CW  = BIT_DEPTH + 8; // coefficient width for transform/quant pipeline

    reg [256*BD-1:0] pred_buf;

    // Inter residual for current 4x4 sub-block (16 pixels × (BIT_DEPTH+1) bits signed)
    reg [16*BD1-1:0] inter_resid_4x4;

    // Muxed residual: use inter residual for inter luma only, intra residual otherwise
    wire [16*BD1-1:0] resid_mux = (is_inter_mb_reg && is_luma) ? inter_resid_4x4 :
                              chr_pred_mode ? chr_resid_4x4 : resid_4x4_w;

    integer idx_ei, idx_pi, idx_ir;
    // Chroma pixel index helper: for 4:2:0 (8x8) use 6 bits, for 4:2:2 (8x16) use 7 bits
    // Layout: {block_row, pixel_row[1:0], block_col, pixel_col[1:0]}
    function automatic [6:0] chr_pix_idx;
        input [1:0] blk_r;
        input [3:0] pix;  // idx_ei or idx_pi: [3:2]=pixel_row, [1:0]=pixel_col
        input [0:0] blk_c;
        if (CHROMA_FORMAT_IDC == 2)
            chr_pix_idx = {blk_r[1:0], pix[3:2], blk_c, pix[1:0]}; // 7 bits, 128 pixels
        else
            chr_pix_idx = {1'b0, blk_r[0], pix[3:2], blk_c, pix[1:0]}; // 6 bits, 64 pixels
    endfunction

    always @(*) begin
        // Sub-block original pixels
sb_orig_pixels = {(16*BD){1'b0}};
        for (idx_ei = 0; idx_ei < 16; idx_ei = idx_ei + 1) begin
            if (is_cb)
                sb_orig_pixels[idx_ei*BD +: BD] = fetched_cb[chr_pix_idx(sb_r, idx_ei[3:0], sb_c[0])*BD +: BD];
            else if (is_cr)
                sb_orig_pixels[idx_ei*BD +: BD] = fetched_cr[chr_pix_idx(sb_r, idx_ei[3:0], sb_c[0])*BD +: BD];
            else
                sb_orig_pixels[idx_ei*BD +: BD] = fetched_luma[{sb_r, idx_ei[3:2], sb_c, idx_ei[1:0]}*BD +: BD];
        end

        // Sub-block prediction pixels for reconstruct
        // For inter MBs: use inter_pred_buf; for intra: use pred_4x4_w scattered into MB
pred_buf = {(256*BD){1'b0}};
        if (is_inter_mb_reg && is_luma) begin
            pred_buf = inter_pred_buf;
        end else begin
            for (idx_pi = 0; idx_pi < 16; idx_pi = idx_pi + 1) begin
                if (is_luma)
                    pred_buf[{sb_r, idx_pi[3:2], sb_c, idx_pi[1:0]}*BD +: BD] = pred_4x4_w[idx_pi*BD +: BD];
                else
                    pred_buf[chr_pix_idx(sb_r, idx_pi[3:0], sb_c[0])*BD +: BD] = pred_4x4_w[idx_pi*BD +: BD];
            end
        end

        // Inter residual: orig - inter_pred for current 4x4 sub-block
        inter_resid_4x4 = {(16*BD1){1'b0}};
        for (idx_ir = 0; idx_ir < 16; idx_ir = idx_ir + 1) begin : inter_resid_calc
            reg [BD-1:0] orig_pix, pred_pix;
            reg signed [BD:0] diff;
            orig_pix = fetched_luma[{sb_r, idx_ir[3:2], sb_c, idx_ir[1:0]}*BD +: BD];
            pred_pix = inter_pred_buf[{sb_r, idx_ir[3:2], sb_c, idx_ir[1:0]}*BD +: BD];
            diff = $signed({1'b0, orig_pix}) - $signed({1'b0, pred_pix});
            inter_resid_4x4[idx_ir*BD1 +: BD1] = diff;
        end

        // Neighbor routing
        if (sb_r == 2'd0) begin
            sb_top_avail  = is_luma ? mb_top_avail : 1'b0;
            sb_top_pixels = top_pixels_flat[sb_c*4*BD +: 4*BD];
        end else if (is_luma) begin
            sb_top_avail  = 1'b1;
            sb_top_pixels = recon_buf[((sb_r*4 - 1)*16 + sb_c*4)*BD +: 4*BD];
        end else begin
            // Chroma inner top: read from chroma recon buffer (8-wide)
            sb_top_avail  = 1'b1;
            if (is_cb) begin
                sb_top_pixels[0*BD +: BD] = chr_recon_cb[((sb_r*4-1)*8 + sb_c*4 + 0)*BD +: BD];
                sb_top_pixels[1*BD +: BD] = chr_recon_cb[((sb_r*4-1)*8 + sb_c*4 + 1)*BD +: BD];
                sb_top_pixels[2*BD +: BD] = chr_recon_cb[((sb_r*4-1)*8 + sb_c*4 + 2)*BD +: BD];
                sb_top_pixels[3*BD +: BD] = chr_recon_cb[((sb_r*4-1)*8 + sb_c*4 + 3)*BD +: BD];
            end else begin
                sb_top_pixels[0*BD +: BD] = chr_recon_cr[((sb_r*4-1)*8 + sb_c*4 + 0)*BD +: BD];
                sb_top_pixels[1*BD +: BD] = chr_recon_cr[((sb_r*4-1)*8 + sb_c*4 + 1)*BD +: BD];
                sb_top_pixels[2*BD +: BD] = chr_recon_cr[((sb_r*4-1)*8 + sb_c*4 + 2)*BD +: BD];
                sb_top_pixels[3*BD +: BD] = chr_recon_cr[((sb_r*4-1)*8 + sb_c*4 + 3)*BD +: BD];
            end
        end

        if (sb_c == 2'd0) begin
            sb_left_avail  = is_luma ? mb_left_avail : 1'b0;
            sb_left_pixels = left_pixels_flat[sb_r*4*BD +: 4*BD];
        end else if (is_luma) begin
            sb_left_avail  = 1'b1;
            sb_left_pixels[0*BD +: BD] = recon_buf[((sb_r*4 + 0)*16 + (sb_c*4 - 1))*BD +: BD];
            sb_left_pixels[1*BD +: BD] = recon_buf[((sb_r*4 + 1)*16 + (sb_c*4 - 1))*BD +: BD];
            sb_left_pixels[2*BD +: BD] = recon_buf[((sb_r*4 + 2)*16 + (sb_c*4 - 1))*BD +: BD];
            sb_left_pixels[3*BD +: BD] = recon_buf[((sb_r*4 + 3)*16 + (sb_c*4 - 1))*BD +: BD];
        end else begin
            // Chroma inner left: read from chroma recon buffer (8-wide)
            sb_left_avail  = 1'b1;
            if (is_cb) begin
                sb_left_pixels[0*BD +: BD] = chr_recon_cb[((sb_r*4+0)*8 + sb_c*4-1)*BD +: BD];
                sb_left_pixels[1*BD +: BD] = chr_recon_cb[((sb_r*4+1)*8 + sb_c*4-1)*BD +: BD];
                sb_left_pixels[2*BD +: BD] = chr_recon_cb[((sb_r*4+2)*8 + sb_c*4-1)*BD +: BD];
                sb_left_pixels[3*BD +: BD] = chr_recon_cb[((sb_r*4+3)*8 + sb_c*4-1)*BD +: BD];
            end else begin
                sb_left_pixels[0*BD +: BD] = chr_recon_cr[((sb_r*4+0)*8 + sb_c*4-1)*BD +: BD];
                sb_left_pixels[1*BD +: BD] = chr_recon_cr[((sb_r*4+1)*8 + sb_c*4-1)*BD +: BD];
                sb_left_pixels[2*BD +: BD] = chr_recon_cr[((sb_r*4+2)*8 + sb_c*4-1)*BD +: BD];
                sb_left_pixels[3*BD +: BD] = chr_recon_cr[((sb_r*4+3)*8 + sb_c*4-1)*BD +: BD];
            end
        end
    end

    // ====================================================================
    // Chroma MV: chroma_mv_eighth = 2 * fullpel_mv (in 1/8-pel units)
    //   chroma_int = chroma_mv >> 3 (arithmetic, in chroma pixels)
    //   chroma_frac = chroma_mv & 7 (0..7 in 1/8-pel)
    // ====================================================================
    // Chroma MV = luma MV in qpel = 4 * fullpel_mv. In chroma 1/8-pel units this equals the qpel value.
    // chr_int = (4*fullpel) >> 3 = fullpel >>> 1 (arithmetic right shift)
    // chr_frac = (4*fullpel) & 7 = fullpel[0] ? 4 : 0 (for fullpel-only ME)
    wire signed [7:0] chr_off_x = $signed(me_fullpel_mvx) >>> 1;
    wire signed [7:0] chr_off_y = $signed(me_fullpel_mvy) >>> 1;
    wire [2:0] chr_frac_x_w = me_fullpel_mvx[0] ? 3'd4 : 3'd0;
    wire [2:0] chr_frac_y_w = me_fullpel_mvy[0] ? 3'd4 : 3'd0;

    // Chroma fetch: row/col counters for 9x9 or 8x8 fetch grid
    reg [4:0] chr_f_row;
    reg [3:0] chr_f_col;
    // Next col/row (for pipelined address)
    wire [3:0] chr_fn_col_w = (chr_f_col + 4'd1 >= chr_fetch_cols) ? 4'd0 : chr_f_col + 4'd1;
    wire [4:0] chr_fn_row_w = (chr_f_col + 4'd1 >= chr_fetch_cols) ? chr_f_row + 5'd1 : chr_f_row;
    // Address computation for current row/col
    wire signed [10:0] chr_fc_x = $signed({1'b0, mb_x, 3'd0}) + $signed({{3{chr_off_x[7]}}, chr_off_x}) + $signed({7'd0, chr_f_col});
    wire signed [10:0] chr_fc_y = $signed({1'b0, mb_y} * $signed({1'b0, CHR_MB_HEIGHT[4:0]})) + $signed({{3{chr_off_y[7]}}, chr_off_y}) + $signed({6'd0, chr_f_row});
    wire [9:0] chr_fc_cx = (chr_fc_x < 0) ? 10'd0 : (chr_fc_x >= CHR_WIDTH)  ? CHR_WIDTH[9:0]  - 10'd1 : chr_fc_x[9:0];
    wire [9:0] chr_fc_cy = (chr_fc_y < 0) ? 10'd0 : (chr_fc_y >= CHR_HEIGHT) ? CHR_HEIGHT[9:0] - 10'd1 : chr_fc_y[9:0];
    wire [17:0] chr_f_addr_cur = chr_fc_cy * CHR_WIDTH[9:0] + {8'd0, chr_fc_cx};
    // Address computation for next row/col (pipelined)
    wire signed [10:0] chr_fn_x = $signed({1'b0, mb_x, 3'd0}) + $signed({{3{chr_off_x[7]}}, chr_off_x}) + $signed({7'd0, chr_fn_col_w});
    wire signed [10:0] chr_fn_y = $signed({1'b0, mb_y} * $signed({1'b0, CHR_MB_HEIGHT[4:0]})) + $signed({{3{chr_off_y[7]}}, chr_off_y}) + $signed({6'd0, chr_fn_row_w});
    wire [9:0] chr_fn_cx = (chr_fn_x < 0) ? 10'd0 : (chr_fn_x >= CHR_WIDTH)  ? CHR_WIDTH[9:0]  - 10'd1 : chr_fn_x[9:0];
    wire [9:0] chr_fn_cy = (chr_fn_y < 0) ? 10'd0 : (chr_fn_y >= CHR_HEIGHT) ? CHR_HEIGHT[9:0] - 10'd1 : chr_fn_y[9:0];
    wire [17:0] chr_f_addr_nxt = chr_fn_cy * CHR_WIDTH[9:0] + {8'd0, chr_fn_cx};

    // ====================================================================
    // Reference memory mux: ME uses ref_rd port during TS_WAIT_ME
    // During ref write-back, the top FSM drives ref_mem_wr directly
    // ====================================================================
    assign me_ref_rd_data_w = ref_mem_rd_data;

    always @(*) begin
        // Default: ME drives the read port
        ref_mem_rd_addr = me_ref_rd_addr;
    end

    // ====================================================================
    // Module instantiations
    // ====================================================================

    h264_fetch #(
        .FRAME_WIDTH(FRAME_WIDTH),
        .BIT_DEPTH(BIT_DEPTH),
        .CHROMA_FORMAT_IDC(CHROMA_FORMAT_IDC)
    ) u_fetch (
        .clk(clk), .rst_n(rst_n), .start(fetch_start), .frame_base_y(FRAME_Y_BASE),
        .frame_base_cb(FRAME_CB_BASE), .frame_base_cr(FRAME_CR_BASE), .mb_x(mb_x), .mb_y(mb_y),
        .frame_width(FRAME_WIDTH[10:0]), .raw_mem_addr(raw_mem_addr), .raw_mem_data(raw_mem_data),
        .luma_flat(fetched_luma), .cb_flat(fetched_cb), .cr_flat(fetched_cr), .done(fetch_done), .valid()
    );

    h264_me #(.BIT_DEPTH(BIT_DEPTH)) u_me (
        .clk(clk), .rst_n(rst_n), .start(me_start), .done(me_done),
        .cur_mb(fetched_luma),
        .ref_rd_addr(me_ref_rd_addr), .ref_rd_data(me_ref_rd_data_w),
        .frame_width(FRAME_WIDTH[10:0]), .frame_height(FRAME_HEIGHT[9:0]),
        .mb_x(mb_x), .mb_y(mb_y),
        .best_mvx(me_mvx_w), .best_mvy(me_mvy_w), .best_sad(me_sad_w),
        .ref_mb_out(me_ref_mb_w)
    );

    h264_intra_pred #(.BIT_DEPTH(BIT_DEPTH)) u_pred (
        .clk(clk), .rst_n(rst_n), .start(pred_start), .done(pred_done), .top_avail(sb_top_avail), .left_avail(sb_left_avail),
        .orig_4x4(sb_orig_pixels), .top_4(sb_top_pixels), .left_4(sb_left_pixels),
        .pred_4x4(pred_4x4_w), .resid_4x4(resid_4x4_w), .pred_mode(pred_mode_w)
    );

    h264_transform #(.BIT_DEPTH(BIT_DEPTH)) u_xform (.clk(clk), .rst_n(rst_n), .start(xform_start), .done(xform_done), .in_flat(resid_mux), .out_flat(xform_out_flat));
    h264_quantize #(.BIT_DEPTH(BIT_DEPTH)) u_quant (.clk(clk), .rst_n(rst_n), .start(quant_start), .done(quant_done), .in_flat(xform_out_flat), .quant_flat(quant_out_flat));
    // Chroma processing signals
    reg         chr_dc_start, chr_dc_inverse;
    wire        chr_dc_done;
    reg  signed [CW-1:0] chr_dc_in0, chr_dc_in1, chr_dc_in2, chr_dc_in3;
    wire signed [15:0] chr_dc_out0, chr_dc_out1, chr_dc_out2, chr_dc_out3;

    // Chroma processing registers
    reg [2:0]   chr_phase;    // Phase within chroma processing
    reg [2:0]   chr_blk;      // Which chroma 4x4 block within the plane
    reg         chr_is_cr;    // 0=Cb, 1=Cr
    reg [255:0] cb_quant_buf [0:CHR_BLOCKS_PER_PLANE-1];
    reg [255:0] cr_quant_buf [0:CHR_BLOCKS_PER_PLANE-1];
    reg signed [CW-1:0] chr_dc_buf [0:CHR_BLOCKS_PER_PLANE-1];
    reg signed [15:0] cb_dc_q [0:CHR_BLOCKS_PER_PLANE-1];
    reg signed [15:0] cr_dc_q [0:CHR_BLOCKS_PER_PLANE-1];
    // Inverse Hadamard DC values for reconstruction (replaces DC in IQ output)
    reg signed [15:0] cb_inv_dc [0:CHR_BLOCKS_PER_PLANE-1];
    reg signed [15:0] cr_inv_dc [0:CHR_BLOCKS_PER_PLANE-1];
    reg [2:0] chr_recon_blk;           // Block counter for chroma reconstruction phase
    // Saved Cb DC prediction values (since chr_dc_pred gets overwritten by Cr)
    reg [BD-1:0] cb_dc_pred_saved [0:CHR_BLOCKS_PER_PLANE-1];

    // Chroma DC zigzag input: pack 4 DCs into 256-bit format (positions 0-3)
    reg [255:0] chr_dc_zigzag_in;

    // Mux for zigzag input: normally quant_out_flat, during chroma DC it's chr_dc_zigzag_in
    reg         use_chr_dc_zigzag;
    wire [255:0] zigzag_in_mux = use_chr_dc_zigzag ? chr_dc_zigzag_in : quant_out_flat;

    // Chroma AC: use quantized block buffer with DC zeroed out
    reg         use_chr_ac_zigzag;
    reg [255:0] chr_ac_zigzag_in;
    wire [255:0] zigzag_in_final = use_chr_ac_zigzag ? chr_ac_zigzag_in : zigzag_in_mux;

    // CAVLC chroma mode signals
    reg         cavlc_is_chroma_dc;
    reg         cavlc_is_chroma_ac;
    reg         zz_chroma_ac_mode;
    reg         zz_chroma_dc_mode;

    // Extra chroma DC signals for 4:2:2 (8 DCs instead of 4)
    reg  signed [CW-1:0] chr_dc_in4, chr_dc_in5, chr_dc_in6, chr_dc_in7;
    wire signed [15:0] chr_dc_out4, chr_dc_out5, chr_dc_out6, chr_dc_out7;

    h264_chroma_dc #(.BIT_DEPTH(BIT_DEPTH), .CHROMA_FORMAT_IDC(CHROMA_FORMAT_IDC)) u_chroma_dc (
        .clk(clk), .rst_n(rst_n), .start(chr_dc_start), .do_inverse(chr_dc_inverse), .done(chr_dc_done),
        .dc_in_0(chr_dc_in0), .dc_in_1(chr_dc_in1), .dc_in_2(chr_dc_in2), .dc_in_3(chr_dc_in3),
        .dc_in_4(chr_dc_in4), .dc_in_5(chr_dc_in5), .dc_in_6(chr_dc_in6), .dc_in_7(chr_dc_in7),
        .dc_out_0(chr_dc_out0), .dc_out_1(chr_dc_out1), .dc_out_2(chr_dc_out2), .dc_out_3(chr_dc_out3),
        .dc_out_4(chr_dc_out4), .dc_out_5(chr_dc_out5), .dc_out_6(chr_dc_out6), .dc_out_7(chr_dc_out7)
    );

    // 4:2:2 chroma DC flag — static based on parameter, used by zigzag and CAVLC
    wire chroma_dc_422_flag = (CHROMA_FORMAT_IDC == 2) ? zz_chroma_dc_mode : 1'b0;

    h264_zigzag u_zigzag (.clk(clk), .rst_n(rst_n), .start(zz_start), .done(zz_done), .in_flat(zigzag_in_final), .chroma_ac_mode(zz_chroma_ac_mode), .chroma_dc_mode(zz_chroma_dc_mode), .chroma_dc_422(chroma_dc_422_flag), .scan_flat(scan_flat), .total_coeffs(total_coeffs), .trailing_ones(trailing_ones), .last_nonzero_idx(last_nonzero_idx));

    localparam [3:0] INTRA_MODE_VERT = 4'd0;
    localparam [3:0] INTRA_MODE_HOR  = 4'd1;
    localparam [3:0] INTRA_MODE_DC   = 4'd2;

    reg [4:0] nz_coeff [0:TOTAL_SUB_BLOCKS-1];
    reg [4:0] left_mb_nz [0:3];
    reg [4:0] top_mb_nz [0:MB_COLS*4-1];
    reg [3:0] intra_mode_cur [0:15];
    reg [3:0] left_mb_mode [0:3];
    reg [3:0] top_mb_mode [0:MB_COLS*4-1];
    reg [63:0] intra_pred_bits_mb;
    reg [6:0]  intra_pred_count_mb;
    // Chroma cross-MB nC neighbors
    reg [4:0] left_mb_nz_cb [0:CHR_BLOCK_ROWS-1];
    reg [4:0] left_mb_nz_cr [0:CHR_BLOCK_ROWS-1];
    reg [4:0] top_mb_nz_cb [0:MB_COLS*2-1];  // top MB's bottom-row Cb nz (col 0,1 per MB)
    reg [4:0] top_mb_nz_cr [0:MB_COLS*2-1];  // top MB's bottom-row Cr nz (col 0,1 per MB)

    reg [4:0] left_blk_idx, top_blk_idx;
    always @(*) begin
        case (sub_blk)
            5'd1:  left_blk_idx = 5'd0;  5'd3:  left_blk_idx = 5'd2;  5'd5:  left_blk_idx = 5'd4;
            5'd7:  left_blk_idx = 5'd6;  5'd9:  left_blk_idx = 5'd8;  5'd11: left_blk_idx = 5'd10;
            5'd13: left_blk_idx = 5'd12; 5'd15: left_blk_idx = 5'd14; 5'd4:  left_blk_idx = 5'd1;
            5'd6:  left_blk_idx = 5'd3;  5'd12: left_blk_idx = 5'd9;  5'd14: left_blk_idx = 5'd11;
            5'd17: left_blk_idx = 5'd16; 5'd19: left_blk_idx = 5'd18;
            5'd21: left_blk_idx = 5'd20; 5'd23: left_blk_idx = 5'd22;
            5'd25: left_blk_idx = 5'd24; 5'd27: left_blk_idx = 5'd26;
            5'd29: left_blk_idx = 5'd28; 5'd31: left_blk_idx = 5'd30;
            default: left_blk_idx = 5'd0;
        endcase
        case (sub_blk)
            5'd2:  top_blk_idx = 5'd0;   5'd3:  top_blk_idx = 5'd1;   5'd6:  top_blk_idx = 5'd4;
            5'd7:  top_blk_idx = 5'd5;   5'd10: top_blk_idx = 5'd8;   5'd11: top_blk_idx = 5'd9;
            5'd14: top_blk_idx = 5'd12;  5'd15: top_blk_idx = 5'd13;  5'd8:  top_blk_idx = 5'd2;
            5'd9:  top_blk_idx = 5'd3;   5'd12: top_blk_idx = 5'd6;   5'd13: top_blk_idx = 5'd7;
            5'd18: top_blk_idx = 5'd16;  5'd19: top_blk_idx = 5'd17;
            5'd20: top_blk_idx = 5'd18;  5'd21: top_blk_idx = 5'd19;  // 4:2:2 Cb row 2
            5'd22: top_blk_idx = 5'd20;  5'd23: top_blk_idx = 5'd21;
            5'd26: top_blk_idx = 5'd24;  5'd27: top_blk_idx = 5'd25;
            5'd28: top_blk_idx = 5'd26;  5'd29: top_blk_idx = 5'd27;  // 4:2:2 Cr row 2
            5'd30: top_blk_idx = 5'd28;  5'd31: top_blk_idx = 5'd29;
            default: top_blk_idx = 5'd0;
        endcase
    end

    function automatic [63:0] append_bits64;
        input [63:0] cur_bits;
        input [6:0]  cur_count;
        input [3:0]  append_count;
        input [63:0] append_payload;
        begin
            append_bits64 = cur_bits | (append_payload << (7'd64 - cur_count - append_count));
        end
    endfunction

    wire [3:0] intra_left_mode_w =
        (sb_c > 0) ? intra_mode_cur[left_blk_idx[3:0]] :
        ((mb_left_avail && !left_is_inter) ? left_mb_mode[sb_r] : INTRA_MODE_DC);
    wire [3:0] intra_top_mode_w =
        (sb_r > 0) ? intra_mode_cur[top_blk_idx[3:0]] :
        ((mb_top_avail && !top_is_inter[mb_x]) ? top_mb_mode[mb_x * 4 + sb_c] : INTRA_MODE_DC);
    wire [3:0] intra_mpm_w = (intra_left_mode_w < intra_top_mode_w) ? intra_left_mode_w : intra_top_mode_w;
    wire       intra_prev_flag_w = (pred_mode_w == intra_mpm_w);
    wire [3:0] intra_pred_minus1_w = pred_mode_w - 4'd1;
    wire [2:0] intra_rem_mode_w = (pred_mode_w < intra_mpm_w) ? pred_mode_w[2:0] : intra_pred_minus1_w[2:0];

    // Cross-MB chroma nC lookup
    wire [4:0] left_chr_nz = is_cb ? left_mb_nz_cb[sb_r] : left_mb_nz_cr[sb_r];
    wire [4:0] top_chr_nz  = is_cb ? top_mb_nz_cb[mb_x * 2 + sb_c[0]] : top_mb_nz_cr[mb_x * 2 + sb_c[0]];
    wire [4:0] nA_val = (sb_c > 0) ? nz_coeff[left_blk_idx] : (mb_left_avail ? (is_luma ? left_mb_nz[sb_r] : left_chr_nz) : 5'd0);
    wire [4:0] nB_val = (sb_r > 0) ? nz_coeff[top_blk_idx]  : (mb_top_avail  ? (is_luma ? top_mb_nz[mb_x * 4 + sb_c] : top_chr_nz) : 5'd0);
    reg [4:0] nC_val;
    wire [5:0] nC_sum = {1'b0, nA_val} + {1'b0, nB_val} + 6'd1;
    always @(*) begin
        if (((sb_c > 0) || mb_left_avail) && ((sb_r > 0) || mb_top_avail))
            nC_val = nC_sum[5:1];
        else if ((sb_c > 0) || mb_left_avail)
            nC_val = nA_val;
        else if ((sb_r > 0) || mb_top_avail)
            nC_val = nB_val;
        else
            nC_val = 5'd0;
    end

    h264_cavlc u_cavlc (.clk(clk), .rst_n(rst_n), .start(cavlc_start), .done(cavlc_done), .scan_flat(scan_flat), .total_coeffs(total_coeffs), .trailing_ones(trailing_ones), .last_nonzero_idx(last_nonzero_idx), .nC(nC_val), .is_chroma_dc(cavlc_is_chroma_dc), .chroma_dc_422(chroma_dc_422_flag), .is_chroma_ac(cavlc_is_chroma_ac), .bits_out(cavlc_bits), .bits_count(cavlc_count), .bits_valid(cavlc_bits_valid));
    // IQ input mux: normally quant_out_flat, during chroma recon uses chr_iq_input
    reg         use_chr_iq_input;
    reg [255:0] chr_iq_input;
    wire [255:0] iq_in_mux = use_chr_iq_input ? chr_iq_input : quant_out_flat;
    h264_inverse_quant #(.BIT_DEPTH(BIT_DEPTH)) u_iq (.clk(clk), .rst_n(rst_n), .start(iq_start), .done(iq_done), .quant_flat(iq_in_mux), .dequant_flat(iq_out_flat));
    // IT input mux: normally iq_out_flat, during chroma recon patches DC with inverse Hadamard value
    reg         use_chr_it_input;
    reg signed [CW-1:0] chr_it_dc_patch;  // Inverse Hadamard DC to patch into IT input
    wire [16*CW-1:0] it_in_mux = use_chr_it_input ? {iq_out_flat[16*CW-1:CW], chr_it_dc_patch} : iq_out_flat;
    h264_inverse_transform #(.BIT_DEPTH(BIT_DEPTH)) u_it (.clk(clk), .rst_n(rst_n), .start(it_start), .done(it_done), .in_flat(it_in_mux), .out_flat(it_out_flat));

    h264_reconstruct #(.BIT_DEPTH(BIT_DEPTH)) u_recon (
        .clk(clk), .rst_n(rst_n), .start(recon_start), .done(recon_done), .sub_block_idx({sb_r[1], sb_c[1], sb_r[0], sb_c[0]}),
        .pred_flat(pred_buf), .recon_resid_flat(it_out_flat), .recon_in(recon_buf), .recon_out(recon_out_w),
        .recon_top_row(recon_top_row_w), .recon_right_col(recon_right_col_w)
    );

    h264_bitstream #(
        .MB_COLS(MB_COLS),
        .MB_ROWS(MB_ROWS),
        .BIT_DEPTH(BIT_DEPTH),
        .CHROMA_FORMAT_IDC(CHROMA_FORMAT_IDC)
    ) u_bitstream (
        .clk(clk), .rst_n(rst_n), .cmd_write_sps(bs_cmd_sps), .cmd_write_pps(bs_cmd_pps), .cmd_write_slice_hdr(bs_cmd_slice),
        .cmd_write_mb_header(bs_cmd_mb_hdr), .cmd_write_trailing(bs_cmd_trailing), .cmd_flush(bs_cmd_flush),
        .cavlc_valid(cavlc_bits_valid), .cavlc_bits(cavlc_bits), .cavlc_count(cavlc_count),
        .mb_qp_delta(8'd0), .mb_has_residual(mb_has_residual),
        .is_p_slice(is_p_frame), .frame_num(cur_frame_num),
        .is_inter_mb(is_inter_mb_reg), .mvd_x(mvd_x_w), .mvd_y(mvd_y_w),
        .hold_fifo_drain(bs_hold_fifo_drain), .intra_pred_bits(intra_pred_bits_mb), .intra_pred_count(intra_pred_count_mb),
        .busy(bs_busy), .cmd_done(bs_cmd_done),
        .bs_mem_addr(bs_mem_addr), .bs_mem_data(bs_mem_data), .bs_mem_wr(bs_mem_wr), .bs_bytes_written(bs_bytes_written)
    );

    // ====================================================================
    // Main FSM
    // ====================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            top_state <= TS_IDLE; done <= 1'b0; mb_x <= 7'd0; mb_y <= 6'd0; sub_blk <= 5'd0; mb_count <= 12'd0;
            fetch_start <= 1'b0; pred_start <= 1'b0; xform_start <= 1'b0; quant_start <= 1'b0; zz_start <= 1'b0;
            cavlc_start <= 1'b0; iq_start <= 1'b0; it_start <= 1'b0; recon_start <= 1'b0; me_start <= 1'b0;
            bs_cmd_sps <= 1'b0; bs_cmd_pps <= 1'b0; bs_cmd_slice <= 1'b0; bs_cmd_mb_hdr <= 1'b0; bs_cmd_trailing <= 1'b0; bs_cmd_flush <= 1'b0;
            mb_top_avail <= 1'b0; mb_left_avail <= 1'b0; mb_has_residual <= 1'b0; bs_hold_fifo_drain <= 1'b0;
            blk_state <= BS_PRED; blk_started <= 1'b0; iq_done_latched <= 1'b0;
            recon_buf <= {(256*BD){1'b0}}; top_ref_flat <= {(MB_COLS*16*BD){1'b0}}; left_ref_flat <= {(16*BD){1'b0}};
            top_pixels_flat <= {(16*BD){1'b0}}; left_pixels_flat <= {(16*BD){1'b0}}; flush_pending <= 1'b0; flush_accepted <= 1'b0;
            is_p_frame <= 1'b0; is_inter_mb_reg <= 1'b0; cur_frame_num <= 4'd0;
            me_best_mvx <= 8'sd0; me_best_mvy <= 8'sd0; me_best_sad <= 18'd0;
            inter_pred_buf <= {(256*BD){1'b0}}; ref_wr_idx <= 9'd0;
            ref_mem_wr_en <= 1'b0; ref_mem_wr_addr <= 20'd0; ref_mem_wr_data <= {BD{1'b0}};
            mvp_x <= 8'sd0; mvp_y <= 8'sd0;
            left_mvx <= 8'sd0; left_mvy <= 8'sd0;
            left_is_inter <= 1'b0;
            diag_mvx <= 8'sd0; diag_mvy <= 8'sd0; diag_is_inter <= 1'b0;
            chr_dc_start <= 1'b0; chr_dc_inverse <= 1'b0;
            chr_phase <= 3'd0; chr_blk <= 3'd0; chr_is_cr <= 1'b0;
            use_chr_dc_zigzag <= 1'b0; use_chr_ac_zigzag <= 1'b0;
            cavlc_is_chroma_dc <= 1'b0; cavlc_is_chroma_ac <= 1'b0;
            zz_chroma_ac_mode <= 1'b0;
            zz_chroma_dc_mode <= 1'b0;
            chr_dc_in0 <= {CW{1'b0}}; chr_dc_in1 <= {CW{1'b0}};
            chr_dc_in2 <= {CW{1'b0}}; chr_dc_in3 <= {CW{1'b0}};
            chr_dc_in4 <= {CW{1'b0}}; chr_dc_in5 <= {CW{1'b0}};
            chr_dc_in6 <= {CW{1'b0}}; chr_dc_in7 <= {CW{1'b0}};
            chr_dc_zigzag_in <= 256'd0; chr_ac_zigzag_in <= 256'd0;
            chr_pred_mode <= 1'b0;
            left_chr_cb_nb <= {(CHR_MB_HEIGHT*BD){1'b0}}; left_chr_cr_nb <= {(CHR_MB_HEIGHT*BD){1'b0}};
            me_fullpel_mvx <= 8'sd0; me_fullpel_mvy <= 8'sd0;
            inter_chr_pred_cb <= {(CHR_MB_PIXELS*BD){1'b0}}; inter_chr_pred_cr <= {(CHR_MB_PIXELS*BD){1'b0}};
            inter_chr_mode <= 1'b0;
            chr_fetch_cnt <= 7'd0; chr_fetch_started <= 1'b0;
            chr_raw_cb <= {(CHR_RAW_SAMPLES*BD){1'b0}}; chr_raw_cr <= {(CHR_RAW_SAMPLES*BD){1'b0}};
            chr_frac_x <= 3'd0; chr_frac_y <= 3'd0;
            chr_fetch_rows <= CHR_MB_HEIGHT[4:0]; chr_fetch_cols <= 4'd8;
            chr_f_row <= 5'd0; chr_f_col <= 4'd0;
            chr_cb_ref_rd_addr <= 18'd0; chr_cb_ref_wr_en <= 1'b0;
            chr_cb_ref_wr_addr <= 18'd0; chr_cb_ref_wr_data <= {BD{1'b0}};
            chr_cr_ref_rd_addr <= 18'd0; chr_cr_ref_wr_en <= 1'b0;
            chr_cr_ref_wr_addr <= 18'd0; chr_cr_ref_wr_data <= {BD{1'b0}};
            use_chr_iq_input <= 1'b0; chr_iq_input <= 256'd0;
            use_chr_it_input <= 1'b0; chr_it_dc_patch <= {CW{1'b0}};
            chr_recon_blk <= 3'd0;
            intra_pred_bits_mb <= 64'd0;
            intra_pred_count_mb <= 7'd0;
        end else begin
            fetch_start <= 1'b0; pred_start <= 1'b0; xform_start <= 1'b0; quant_start <= 1'b0; zz_start <= 1'b0;
            cavlc_start <= 1'b0; iq_start <= 1'b0; it_start <= 1'b0; recon_start <= 1'b0; me_start <= 1'b0;
            bs_cmd_sps <= 1'b0; bs_cmd_pps <= 1'b0; bs_cmd_slice <= 1'b0; bs_cmd_mb_hdr <= 1'b0; bs_cmd_trailing <= 1'b0; bs_cmd_flush <= 1'b0;
            done <= 1'b0;
            ref_mem_wr_en <= 1'b0;
            chr_cb_ref_wr_en <= 1'b0; chr_cr_ref_wr_en <= 1'b0;
            chr_dc_start <= 1'b0;

            case (top_state)
                TS_IDLE: if (start) begin
                    cur_frame_num <= frame_num_in;
                    is_p_frame <= ~is_idr_in;
                    mb_x <= 7'd0; mb_y <= 6'd0; mb_count <= 12'd0;
                    if (is_idr_in)
                        top_state <= TS_WRITE_SPS;  // IDR: write SPS+PPS
                    else
                        top_state <= TS_WRITE_SLICE; // P-frame: skip SPS/PPS
                end

                TS_WRITE_SPS: begin bs_cmd_sps <= 1'b1; top_state <= TS_WAIT_SPS; end
                TS_WAIT_SPS: if (bs_cmd_done) top_state <= TS_WRITE_PPS;
                TS_WRITE_PPS: begin bs_cmd_pps <= 1'b1; top_state <= TS_WAIT_PPS; end
                TS_WAIT_PPS: if (bs_cmd_done) top_state <= TS_WRITE_SLICE;

                TS_WRITE_SLICE: begin bs_cmd_slice <= 1'b1; top_state <= TS_WAIT_SLICE; end
                TS_WAIT_SLICE: if (bs_cmd_done) top_state <= TS_FETCH_MB;

                TS_FETCH_MB: begin
                    fetch_start <= 1'b1; mb_top_avail <= (mb_y > 6'd0); mb_left_avail <= (mb_x > 7'd0);
                    top_pixels_flat <= top_ref_flat[mb_x * 16 * BD +: 16*BD]; left_pixels_flat <= left_ref_flat;
                    top_state <= TS_WAIT_FETCH;
                end
                TS_WAIT_FETCH: if (fetch_done) begin
                    if (is_p_frame)
                        top_state <= TS_ME_START;
                    else begin
                        is_inter_mb_reg <= 1'b0;
                        top_state <= TS_MB_HDR;
                    end
                end

                // Motion estimation for P-frames
                TS_ME_START: begin
                    me_start <= 1'b1;
                    top_state <= TS_WAIT_ME;
                end
                TS_WAIT_ME: if (me_done) begin
                    me_best_mvx <= me_mvx_w <<< 2;  // Convert full-pel to quarter-pel
                    me_best_mvy <= me_mvy_w <<< 2;  // Convert full-pel to quarter-pel
                    me_fullpel_mvx <= me_mvx_w;      // Save full-pel for chroma offset
                    me_fullpel_mvy <= me_mvy_w;
                    me_best_sad <= me_sad_w;
                    inter_pred_buf <= me_ref_mb_w;
                    // Mode decision: use inter if SAD is low enough
                    is_inter_mb_reg <= (me_sad_w < INTRA_SAD_THRESHOLD);
                    // Compute MV predictor per H.264 spec 8.4.1.3.1
                    // A = left, B = top, C = top-right (or D=top-left if C unavail)
                    begin : mvp_calc
                        reg signed [7:0] ax, ay, bx, by, cx, cy;
                        reg a_avail, b_avail, c_avail, d_avail;
                        reg a_inter, b_inter, c_inter;
                        reg [1:0] match_cnt;
                        reg signed [7:0] med_x, med_y;

                        a_avail = (mb_x > 7'd0);
                        b_avail = (mb_y > 6'd0);
                        c_avail = (mb_y > 6'd0) && (mb_x < MB_COLS[6:0] - 7'd1);
                        d_avail = (mb_y > 6'd0) && (mb_x > 7'd0);

                        // Get MVs and inter status for each neighbor
                        // Intra/unavailable: MV=0, ref_idx=-1 (doesn't match current ref_idx=0)
                        ax = a_avail ? left_mvx : 8'sd0;
                        ay = a_avail ? left_mvy : 8'sd0;
                        a_inter = a_avail && left_is_inter;

                        bx = b_avail ? top_mvx[mb_x] : 8'sd0;
                        by = b_avail ? top_mvy[mb_x] : 8'sd0;
                        b_inter = b_avail && top_is_inter[mb_x];

                        if (c_avail) begin
                            cx = top_mvx[mb_x + 7'd1];
                            cy = top_mvy[mb_x + 7'd1];
                            c_inter = top_is_inter[mb_x + 7'd1];
                        end else if (d_avail) begin
                            // Use saved diagonal (top-left from previous row)
                            cx = diag_mvx;
                            cy = diag_mvy;
                            c_inter = diag_is_inter;
                        end else begin
                            cx = 8'sd0;
                            cy = 8'sd0;
                            c_inter = 1'b0;
                        end

                        // H.264 spec: if B and C both not in picture, copy A to B and C
                        if (!b_avail && !c_avail && !d_avail) begin
                            bx = ax; by = ay; b_inter = a_inter;
                            cx = ax; cy = ay; c_inter = a_inter;
                        end

                        // Count how many neighbors have matching ref_idx (are inter)
                        match_cnt = {1'b0, a_inter} + {1'b0, b_inter} + {1'b0, c_inter};

                        // Median computation
                        med_x = (ax > bx && ax > cx) ? ((bx > cx) ? bx : cx) :
                                (ax < bx && ax < cx) ? ((bx < cx) ? bx : cx) : ax;
                        med_y = (ay > by && ay > cy) ? ((by > cy) ? by : cy) :
                                (ay < by && ay < cy) ? ((by < cy) ? by : cy) : ay;

                        // H.264 spec 8.4.1.3.1 step 4:
                        // If exactly one neighbor has matching ref_idx, use its MV
                        if (match_cnt == 2'd1) begin
                            if (a_inter)      begin mvp_x <= ax; mvp_y <= ay; end
                            else if (b_inter) begin mvp_x <= bx; mvp_y <= by; end
                            else              begin mvp_x <= cx; mvp_y <= cy; end
                        end else begin
                            // 0, 2, or 3 matching: use median
                            mvp_x <= med_x;
                            mvp_y <= med_y;
                        end
                        /* verilator lint_off WIDTH */
                        if (dbg_target_mb) begin
                            $display("[MVP] F%0d MB%0d mbx=%0d mby=%0d A(%0d,%0d,i=%0d) B(%0d,%0d,i=%0d) C(%0d,%0d,i=%0d) match=%0d med(%0d,%0d) sad=%0d inter=%0d",
                                dbg_frame_cnt, mb_count, mb_x, mb_y,
                                $signed(ax), $signed(ay), a_inter,
                                $signed(bx), $signed(by), b_inter,
                                $signed(cx), $signed(cy), c_inter,
                                match_cnt, $signed(med_x), $signed(med_y),
                                me_sad_w, (me_sad_w < INTRA_SAD_THRESHOLD));
                        end
                        /* verilator lint_on WIDTH */
                    end
                    top_state <= TS_MB_HDR;
                end

                TS_MB_HDR: if (!bs_busy) begin
                    mb_has_residual <= 1'b1;
                    sub_blk <= 5'd0;
                    blk_state <= is_inter_mb_reg ? BS_XFORM : BS_PRED;
                    blk_started <= 1'b0;
                    recon_buf <= {(256*BD){1'b0}};
                    chr_pred_mode <= 1'b0;
                    intra_pred_bits_mb <= 64'd0;
                    intra_pred_count_mb <= 7'd0;
                    if (is_inter_mb_reg) begin
                        bs_cmd_mb_hdr <= 1'b1;
                        bs_hold_fifo_drain <= 1'b0;
                    end else begin
                        bs_hold_fifo_drain <= 1'b1;
                    end
                    top_state <= TS_ENCODE_SBLK;
                end

                TS_ENCODE_SBLK: begin
                    case (blk_state)
                        BS_PRED: begin
                            // Intra prediction (skipped for inter MBs — they start at BS_XFORM)
                            if (!blk_started) begin pred_start <= 1'b1; blk_started <= 1'b1; end
                            else if (pred_done) begin
                                if (is_luma) begin
                                    intra_mode_cur[sub_blk[3:0]] <= pred_mode_w;
                                    if (intra_prev_flag_w) begin
                                        intra_pred_bits_mb <= append_bits64(intra_pred_bits_mb, intra_pred_count_mb, 4'd1, 64'd1);
                                        intra_pred_count_mb <= intra_pred_count_mb + 7'd1;
                                    end else begin
                                        intra_pred_bits_mb <= append_bits64(intra_pred_bits_mb, intra_pred_count_mb, 4'd4, {60'd0, 1'b0, intra_rem_mode_w});
                                        intra_pred_count_mb <= intra_pred_count_mb + 7'd4;
                                    end
                                end
                                blk_state <= BS_XFORM;
                                blk_started <= 1'b0;
                            end
                        end
                        BS_XFORM:  if (!blk_started) begin
                            xform_start <= 1'b1; blk_started <= 1'b1;
                        end else if (xform_done) begin blk_state <= BS_QUANT; blk_started <= 1'b0; end
                        BS_QUANT:  if (!blk_started) begin quant_start <= 1'b1; blk_started <= 1'b1; end else if (quant_done) begin blk_state <= BS_ZIGZAG; blk_started <= 1'b0; end
                        BS_ZIGZAG: if (!blk_started) begin zz_start <= 1'b1; iq_start <= 1'b1; blk_started <= 1'b1; iq_done_latched <= 1'b0; end
                                   else begin if (iq_done) iq_done_latched <= 1'b1; if (zz_done) begin nz_coeff[sub_blk] <= total_coeffs; blk_state <= BS_CAVLC; blk_started <= 1'b0; end end
                        BS_CAVLC:  if (!blk_started && !bs_busy) begin cavlc_start <= 1'b1; blk_started <= 1'b1; end
                                   else begin if (iq_done) iq_done_latched <= 1'b1; if (cavlc_done) begin blk_state <= BS_IQ; blk_started <= 1'b0; end end
                        BS_IQ:     if (iq_done || iq_done_latched) begin blk_state <= BS_IT; blk_started <= 1'b0; end else if (iq_done) iq_done_latched <= 1'b1;
                        BS_IT:     if (!blk_started) begin it_start <= 1'b1; blk_started <= 1'b1; end else if (it_done) begin blk_state <= BS_RECON; blk_started <= 1'b0; end
                        BS_RECON:  if (!blk_started) begin recon_start <= 1'b1; blk_started <= 1'b1; end else if (recon_done) begin
                                       recon_buf <= recon_out_w;
                                       if (sub_blk == 5'd15) begin
                                           // Luma done
                                           if (is_inter_mb_reg) begin
                                               // Inter MBs: fetch chroma prediction from reference
                                               top_state <= TS_CHR_FETCH;
                                               chr_fetch_cnt <= 7'd0;
                                               chr_fetch_started <= 1'b0;
                                               blk_started <= 1'b0;
                                               chr_recon_cb <= {(CHR_MB_PIXELS*BD){1'b0}};
                                               chr_recon_cr <= {(CHR_MB_PIXELS*BD){1'b0}};
                                               chr_raw_cb <= {(CHR_RAW_SAMPLES*BD){1'b0}};
                                               chr_raw_cr <= {(CHR_RAW_SAMPLES*BD){1'b0}};
                                               chr_f_row <= 5'd0;
                                               chr_f_col <= 4'd0;
                                               // Chroma 1/8-pel fraction from pre-computed wires
                                               chr_frac_x <= chr_frac_x_w;
                                               chr_frac_y <= chr_frac_y_w;
                                               chr_fetch_cols <= (chr_frac_x_w != 3'd0) ? 4'd9 : 4'd8;
                                               chr_fetch_rows <= (chr_frac_y_w != 3'd0) ? (CHR_MB_HEIGHT[4:0] + 5'd1) : CHR_MB_HEIGHT[4:0];
                                           end else begin
                                           // Intra: enter chroma processing with 8x8 DC prediction
                                           top_state <= TS_CHROMA;
                                           chr_phase <= 3'd0;
                                           chr_blk <= 3'd0;
                                           chr_is_cr <= 1'b0;
                                           blk_started <= 1'b0;
                                           blk_state <= BS_PRED;
                                           chr_recon_cb <= {(CHR_MB_PIXELS*BD){1'b0}};
                                           chr_recon_cr <= {(CHR_MB_PIXELS*BD){1'b0}};
                                           inter_chr_mode <= 1'b0;
                                           use_chr_dc_zigzag <= 1'b0;
                                           use_chr_ac_zigzag <= 1'b0;
                                           cavlc_is_chroma_dc <= 1'b0;
                                           cavlc_is_chroma_ac <= 1'b0;
                                           zz_chroma_ac_mode <= 1'b0;
                                           zz_chroma_dc_mode <= 1'b0;
                                           end // end else (intra chroma)
                                       end else begin
                                           sub_blk <= sub_blk + 5'd1;
                                           blk_state <= (is_inter_mb_reg && sub_blk < 5'd15) ? BS_XFORM : BS_PRED;
                                           blk_started <= 1'b0;
                                       end
                                   end
                        default:   blk_state <= BS_PRED;
                    endcase
                end

                TS_DEFER_MB_HDR: if (!bs_busy) begin
                    bs_hold_fifo_drain <= 1'b0;
                    bs_cmd_mb_hdr <= 1'b1;
                    top_state <= TS_NEXT_MB;
                end

                TS_NEXT_MB: begin
                    left_mb_nz[0] <= nz_coeff[5]; left_mb_nz[1] <= nz_coeff[7]; left_mb_nz[2] <= nz_coeff[13]; left_mb_nz[3] <= nz_coeff[15];
                    top_mb_nz[mb_x * 4 + 0] <= nz_coeff[10]; top_mb_nz[mb_x * 4 + 1] <= nz_coeff[11]; top_mb_nz[mb_x * 4 + 2] <= nz_coeff[14]; top_mb_nz[mb_x * 4 + 3] <= nz_coeff[15];
                    left_mb_mode[0] <= intra_mode_cur[5]; left_mb_mode[1] <= intra_mode_cur[7];
                    left_mb_mode[2] <= intra_mode_cur[13]; left_mb_mode[3] <= intra_mode_cur[15];
                    top_mb_mode[mb_x * 4 + 0] <= intra_mode_cur[10];
                    top_mb_mode[mb_x * 4 + 1] <= intra_mode_cur[11];
                    top_mb_mode[mb_x * 4 + 2] <= intra_mode_cur[14];
                    top_mb_mode[mb_x * 4 + 3] <= intra_mode_cur[15];
                    // Chroma nC neighbors (parameterized for 4:2:0 and 4:2:2)
                    begin : chr_nz_save
                        integer nr;
                        for (nr = 0; nr < CHR_BLOCK_ROWS; nr = nr + 1) begin
                            // Right column (c=1) of each row -> left neighbor for next MB
                            left_mb_nz_cb[nr] <= nz_coeff[16 + nr*2 + 1];
                            left_mb_nz_cr[nr] <= nz_coeff[16 + CHR_BLOCKS_PER_PLANE + nr*2 + 1];
                        end
                        // Bottom row (last row, both columns) -> top neighbor for MB below
                        top_mb_nz_cb[mb_x * 2 + 0] <= nz_coeff[16 + (CHR_BLOCK_ROWS-1)*2];
                        top_mb_nz_cb[mb_x * 2 + 1] <= nz_coeff[16 + (CHR_BLOCK_ROWS-1)*2 + 1];
                        top_mb_nz_cr[mb_x * 2 + 0] <= nz_coeff[16 + CHR_BLOCKS_PER_PLANE + (CHR_BLOCK_ROWS-1)*2];
                        top_mb_nz_cr[mb_x * 2 + 1] <= nz_coeff[16 + CHR_BLOCKS_PER_PLANE + (CHR_BLOCK_ROWS-1)*2 + 1];
                    end
                    top_ref_flat[mb_x * 16 * BD +: 16*BD] <= recon_top_row_w; left_ref_flat <= recon_right_col_w; mb_count <= mb_count + 12'd1;
                    // Save top-left diagonal before overwriting (for D neighbor)
                    diag_mvx <= top_mvx[mb_x];
                    diag_mvy <= top_mvy[mb_x];
                    diag_is_inter <= top_is_inter[mb_x];
                    // Store MV and inter status for neighbor prediction
                    if (is_inter_mb_reg) begin
                        top_mvx[mb_x] <= me_best_mvx;
                        top_mvy[mb_x] <= me_best_mvy;
                        top_is_inter[mb_x] <= 1'b1;
                        left_mvx <= me_best_mvx;
                        left_mvy <= me_best_mvy;
                        left_is_inter <= 1'b1;
                    end else begin
                        top_mvx[mb_x] <= 8'sd0;
                        top_mvy[mb_x] <= 8'sd0;
                        top_is_inter[mb_x] <= 1'b0;
                        left_mvx <= 8'sd0;
                        left_mvy <= 8'sd0;
                        left_is_inter <= 1'b0;
                    end
                    // Store chroma neighbors for next MB's 8x8 DC prediction
                    // Bottom row (row 7) → top neighbor for MB below
                    // Right column (col 7) → left neighbor for MB to the right
                    // 8x8 layout: pixel[row*8+col]
                    begin : chr_top_nb_save
                        integer nb_c;
                        for (nb_c = 0; nb_c < 8; nb_c = nb_c + 1) begin
                            top_chr_cb_nb[mb_x][nb_c*BD +: BD] <= chr_recon_cb[((CHR_MB_HEIGHT-1)*8+nb_c)*BD +: BD];
                            top_chr_cr_nb[mb_x][nb_c*BD +: BD] <= chr_recon_cr[((CHR_MB_HEIGHT-1)*8+nb_c)*BD +: BD];
                        end
                    end
                    begin : chr_nb_save
                        integer nb_r;
                        for (nb_r = 0; nb_r < CHR_MB_HEIGHT; nb_r = nb_r + 1) begin
                            left_chr_cb_nb[nb_r*BD +: BD] <= chr_recon_cb[(nb_r*8+7)*BD +: BD];
                            left_chr_cr_nb[nb_r*BD +: BD] <= chr_recon_cr[(nb_r*8+7)*BD +: BD];
                        end
                    end
                    ref_wr_idx <= 9'd0;
                    top_state <= TS_REF_WR;
                end

                // Write reconstructed luma (256 bytes) back to reference frame memory
                TS_REF_WR: begin
                    if (ref_wr_idx < 9'd256) begin
                        // Write luma (256 pixels)
                        ref_mem_wr_en <= 1'b1;
                        ref_mem_wr_addr <= ({mb_y, 4'd0} + {6'd0, ref_wr_idx[7:4]}) * FRAME_WIDTH[10:0]
                                         + {mb_x, 4'd0} + {7'd0, ref_wr_idx[3:0]};
                        ref_mem_wr_data <= recon_buf[ref_wr_idx[7:0]*BD +: BD];
                        ref_wr_idx <= ref_wr_idx + 9'd1;
                    end else if (ref_wr_idx < (9'd256 + CHR_MB_PIXELS[8:0])) begin
                        // Write chroma Cb and Cr simultaneously (CHR_MB_PIXELS each)
                        // Chroma pixel index = ref_wr_idx - 256 (0..CHR_MB_PIXELS-1)
                        // row = ci/8, col = ci%8
                        begin : chr_wr_calc
                            reg [6:0] ci;
                            reg [17:0] ca;
                            ci = ref_wr_idx[6:0]; // 0..CHR_MB_PIXELS-1
                            // Address = (mb_y*CHR_MB_HEIGHT + row) * CHR_WIDTH + mb_x*8 + col
                            ca = ({14'd0, mb_y} * CHR_MB_HEIGHT[4:0] + {11'd0, ci[6:3]}) * CHR_WIDTH[10:0]
                               + ({11'd0, mb_x} * 11'd8) + {15'd0, ci[2:0]};
                            chr_cb_ref_wr_en <= 1'b1;
                            chr_cb_ref_wr_addr <= ca;
                            chr_cb_ref_wr_data <= chr_recon_cb[ci*BD +: BD];
                            chr_cr_ref_wr_en <= 1'b1;
                            chr_cr_ref_wr_addr <= ca;
                            chr_cr_ref_wr_data <= chr_recon_cr[ci*BD +: BD];
                        end
                        ref_wr_idx <= ref_wr_idx + 9'd1;
                    end else begin
                        // Done writing this MB to reference, advance to next MB
                        if (mb_x == MB_COLS[6:0] - 7'd1) begin
                            mb_x <= 7'd0;
                            if (mb_y == MB_ROWS[5:0] - 6'd1)
                                top_state <= TS_TRAILING;
                            else begin
                                mb_y <= mb_y + 6'd1;
                                top_state <= TS_FETCH_MB;
                            end
                        end else begin
                            mb_x <= mb_x + 7'd1;
                            top_state <= TS_FETCH_MB;
                        end
                    end
                end

                // ============================================================
                // TS_CHR_FETCH: Fetch inter chroma prediction from reference
                // Reads 8×8 Cb and 8×8 Cr pixels simultaneously
                // ============================================================
                TS_CHR_FETCH: begin
                    if (!chr_fetch_started) begin
                        // Initial address setup cycle (address for pixel 0)
                        chr_cb_ref_rd_addr <= chr_f_addr_cur;
                        chr_cr_ref_rd_addr <= chr_f_addr_cur;
                        chr_fetch_started <= 1'b1;
                    end else if (chr_f_row < chr_fetch_rows) begin
                        // Store data from previous cycle's read into raw buffer
                        chr_raw_cb[chr_fetch_cnt*BD +: BD] <= chr_cb_ref_rd_data;
                        chr_raw_cr[chr_fetch_cnt*BD +: BD] <= chr_cr_ref_rd_data;
                        chr_fetch_cnt <= chr_fetch_cnt + 7'd1;
                        // Advance col/row
                        if (chr_f_col + 4'd1 >= chr_fetch_cols) begin
                            chr_f_col <= 4'd0;
                            chr_f_row <= chr_f_row + 5'd1;
                        end else begin
                            chr_f_col <= chr_f_col + 4'd1;
                        end
                        // Set address for next pixel
                        chr_cb_ref_rd_addr <= chr_f_addr_nxt;
                        chr_cr_ref_rd_addr <= chr_f_addr_nxt;
                    end else begin
                        // Raw fetch done. Apply bilinear interpolation to produce 8×8 prediction.
                        begin : chr_interp_block
                            // verilator lint_off BLKSEQ
                            // H.264 8.4.2.2.2: chroma 1/8-pel bilinear interpolation
                            // pred = ((8-dx)*(8-dy)*A + dx*(8-dy)*B + (8-dx)*dy*C + dx*dy*D + 32) >> 6
                            integer ir, ic;
                            reg [7:0] src_idx, src_r_idx, src_b_idx, src_br_idx;
                            reg [BD+8:0] interp_sum;
                            reg [3:0] stride; // 8 or 9
                            reg [6:0] wA, wB, wC, wD; // weights (max 64, need 7 bits)
                            reg [6:0] e_dx, e_dy, fx, fy;
                            stride = chr_fetch_cols;
                            // Compute weights: wA=(8-dx)(8-dy), wB=dx(8-dy), wC=(8-dx)dy, wD=dx*dy
                            fx = {4'd0, chr_frac_x};
                            fy = {4'd0, chr_frac_y};
                            e_dx = 7'd8 - fx;
                            e_dy = 7'd8 - fy;
                            wA = e_dx * e_dy;
                            wB = fx * e_dy;
                            wC = e_dx * fy;
                            wD = fx * fy;
                            for (ir = 0; ir < CHR_MB_HEIGHT; ir = ir + 1) begin
                                for (ic = 0; ic < 8; ic = ic + 1) begin
                                    src_idx = ir[4:0] * stride + ic[3:0];
                                    if (chr_frac_x == 3'd0 && chr_frac_y == 3'd0) begin
                                        // No interpolation: direct copy
                                        inter_chr_pred_cb[(ir*8+ic)*BD +: BD] <= chr_raw_cb[src_idx*BD +: BD];
                                        inter_chr_pred_cr[(ir*8+ic)*BD +: BD] <= chr_raw_cr[src_idx*BD +: BD];
                                    end else begin
                                        src_r_idx  = src_idx + 8'd1;
                                        src_b_idx  = src_idx + {4'd0, stride};
                                        src_br_idx = src_idx + {4'd0, stride} + 8'd1;
                                        // Cb
                                        interp_sum = wA * {{(BD-2){1'b0}}, chr_raw_cb[src_idx*BD +: BD]}
                                                   + wB * {{(BD-2){1'b0}}, chr_raw_cb[src_r_idx*BD +: BD]}
                                                   + wC * {{(BD-2){1'b0}}, chr_raw_cb[src_b_idx*BD +: BD]}
                                                   + wD * {{(BD-2){1'b0}}, chr_raw_cb[src_br_idx*BD +: BD]}
                                                   + {{(BD+2){1'b0}}, 7'd32};
                                        inter_chr_pred_cb[(ir*8+ic)*BD +: BD] <= interp_sum[BD+5:6];
                                        // Cr
                                        interp_sum = wA * {{(BD-2){1'b0}}, chr_raw_cr[src_idx*BD +: BD]}
                                                   + wB * {{(BD-2){1'b0}}, chr_raw_cr[src_r_idx*BD +: BD]}
                                                   + wC * {{(BD-2){1'b0}}, chr_raw_cr[src_b_idx*BD +: BD]}
                                                   + wD * {{(BD-2){1'b0}}, chr_raw_cr[src_br_idx*BD +: BD]}
                                                   + {{(BD+2){1'b0}}, 7'd32};
                                        inter_chr_pred_cr[(ir*8+ic)*BD +: BD] <= interp_sum[BD+5:6];
                                    end
                                end
                            end
                            // verilator lint_on BLKSEQ
                        end
                        // Done: enter chroma processing
                        top_state <= TS_CHROMA;
                        chr_phase <= 3'd0;
                        chr_blk <= 3'd0;
                        chr_is_cr <= 1'b0;
                        blk_started <= 1'b0;
                        blk_state <= BS_PRED;
                        inter_chr_mode <= 1'b1;
                        use_chr_dc_zigzag <= 1'b0;
                        use_chr_ac_zigzag <= 1'b0;
                        cavlc_is_chroma_dc <= 1'b0;
                        cavlc_is_chroma_ac <= 1'b0;
                        zz_chroma_ac_mode <= 1'b0;
                        zz_chroma_dc_mode <= 1'b0;
                    end
                end

                // ============================================================
                // TS_CHROMA: Chroma encoding (Cb and Cr)
                // H.264 bitstream order: Cb DC, Cr DC, Cb AC×4, Cr AC×4
                // Phases: 0=pred/xform/quant (×4 blocks), 1=fwd Hadamard DC,
                //   2=inv Hadamard DC + switch Cb→Cr or proceed,
                //   6=reconstruction (IQ+IT+recon using inv Hadamard DCs),
                //   3=CAVLC Cb DC, 4=CAVLC Cr DC, 5=CAVLC AC (Cb×4 then Cr×4)
                // ============================================================
                TS_CHROMA: begin
                    case (chr_phase)
                        // Phase 0: pred → xform (capture raw DC) → quant (save quant buf) per 4x4 block
                        3'd0: begin
                            case (blk_state)
                                BS_PRED: begin
                                    sub_blk <= chr_is_cr ? (5'd16 + CHR_BLOCKS_PER_PLANE[4:0] + {2'd0, chr_blk}) : (5'd16 + {2'd0, chr_blk});
                                    chr_pred_mode <= 1'b1;
                                    if (inter_chr_mode) begin
                                        // Inter chroma: use reference block as prediction
                                        begin : chr_inter_pred_calc
                                            // verilator lint_off BLKSEQ
                                            integer cj;
                                            reg [6:0] pidx;
                                            reg [BD-1:0] orig_pix, pred_pix;
                                            for (cj = 0; cj < 16; cj = cj + 1) begin
                                                pidx = {chr_blk[2:1], cj[3:2], chr_blk[0], cj[1:0]};
                                                if (chr_is_cr) begin
                                                    orig_pix = fetched_cr[pidx*BD +: BD];
                                                    pred_pix = inter_chr_pred_cr[pidx*BD +: BD];
                                                end else begin
                                                    orig_pix = fetched_cb[pidx*BD +: BD];
                                                    pred_pix = inter_chr_pred_cb[pidx*BD +: BD];
                                                end
                                                chr_resid_4x4[cj*BD1 +: BD1] = {1'b0, orig_pix} - {1'b0, pred_pix};
                                            end
                                            // verilator lint_on BLKSEQ
                                        end
                                    end else begin
                                        // Intra chroma: H.264 8x8 DC prediction
                                        begin : chr_dc_pred_calc
                                            // verilator lint_off BLKSEQ
                                            reg [8*BD-1:0] top_nb;
                                            reg [CHR_MB_HEIGHT*BD-1:0] left_nb_full;
                                            reg [BD+2:0] s0, s1, s2, s3, s4, s5, s6, s7;
                                            reg [BD-1:0] dc_val;
                                            reg ta, la;
                                            integer cj;

                                            top_nb = chr_is_cr ? top_chr_cr_nb[mb_x] : top_chr_cb_nb[mb_x];
                                            left_nb_full = chr_is_cr ? left_chr_cr_nb : left_chr_cb_nb;
                                            ta = mb_top_avail;
                                            la = mb_left_avail;

                                            // Top neighbor sums (columns 0-3, 4-7)
                                            s0 = {{3{1'b0}}, top_nb[0*BD +: BD]} + {{3{1'b0}}, top_nb[1*BD +: BD]} + {{3{1'b0}}, top_nb[2*BD +: BD]} + {{3{1'b0}}, top_nb[3*BD +: BD]};
                                            s1 = {{3{1'b0}}, top_nb[4*BD +: BD]} + {{3{1'b0}}, top_nb[5*BD +: BD]} + {{3{1'b0}}, top_nb[6*BD +: BD]} + {{3{1'b0}}, top_nb[7*BD +: BD]};
                                            // Left neighbor sums (rows 0-3, 4-7, 8-11, 12-15)
                                            s2 = {{3{1'b0}}, left_nb_full[0*BD +: BD]} + {{3{1'b0}}, left_nb_full[1*BD +: BD]} + {{3{1'b0}}, left_nb_full[2*BD +: BD]} + {{3{1'b0}}, left_nb_full[3*BD +: BD]};
                                            s3 = {{3{1'b0}}, left_nb_full[4*BD +: BD]} + {{3{1'b0}}, left_nb_full[5*BD +: BD]} + {{3{1'b0}}, left_nb_full[6*BD +: BD]} + {{3{1'b0}}, left_nb_full[7*BD +: BD]};
                                            if (CHROMA_FORMAT_IDC == 2) begin
                                                s4 = {{3{1'b0}}, left_nb_full[ 8*BD +: BD]} + {{3{1'b0}}, left_nb_full[ 9*BD +: BD]} + {{3{1'b0}}, left_nb_full[10*BD +: BD]} + {{3{1'b0}}, left_nb_full[11*BD +: BD]};
                                                s5 = {{3{1'b0}}, left_nb_full[12*BD +: BD]} + {{3{1'b0}}, left_nb_full[13*BD +: BD]} + {{3{1'b0}}, left_nb_full[14*BD +: BD]} + {{3{1'b0}}, left_nb_full[15*BD +: BD]};
                                            end else begin
                                                s4 = {(BD+3){1'b0}};
                                                s5 = {(BD+3){1'b0}};
                                            end

                                            case (chr_blk)
                                                3'd0: begin
                                                    if (ta && la) dc_val = (s0 + s2 + {{(BD){1'b0}}, 3'd4}) >> 3;
                                                    else if (ta)  dc_val = (s0 + {{(BD+1){1'b0}}, 2'd2}) >> 2;
                                                    else if (la)  dc_val = (s2 + {{(BD+1){1'b0}}, 2'd2}) >> 2;
                                                    else          dc_val = {1'b1, {(BD-1){1'b0}}};
                                                end
                                                3'd1: begin
                                                    if (ta)       dc_val = (s1 + {{(BD+1){1'b0}}, 2'd2}) >> 2;
                                                    else if (la)  dc_val = (s2 + {{(BD+1){1'b0}}, 2'd2}) >> 2;
                                                    else          dc_val = {1'b1, {(BD-1){1'b0}}};
                                                end
                                                3'd2: begin
                                                    if (la)       dc_val = (s3 + {{(BD+1){1'b0}}, 2'd2}) >> 2;
                                                    else if (ta)  dc_val = (s0 + {{(BD+1){1'b0}}, 2'd2}) >> 2;
                                                    else          dc_val = {1'b1, {(BD-1){1'b0}}};
                                                end
                                                3'd3: begin
                                                    if (ta && la) dc_val = (s1 + s3 + {{(BD){1'b0}}, 3'd4}) >> 3;
                                                    else if (ta)  dc_val = (s1 + {{(BD+1){1'b0}}, 2'd2}) >> 2;
                                                    else if (la)  dc_val = (s3 + {{(BD+1){1'b0}}, 2'd2}) >> 2;
                                                    else          dc_val = {1'b1, {(BD-1){1'b0}}};
                                                end
                                                3'd4: begin  // 4:2:2 only: row 8-11, col 0-3
                                                    if (la)       dc_val = (s4 + {{(BD+1){1'b0}}, 2'd2}) >> 2;
                                                    else          dc_val = {1'b1, {(BD-1){1'b0}}};
                                                end
                                                3'd5: begin  // 4:2:2 only: row 8-11, col 4-7
                                                    if (la)       dc_val = (s4 + {{(BD+1){1'b0}}, 2'd2}) >> 2;
                                                    else          dc_val = {1'b1, {(BD-1){1'b0}}};
                                                end
                                                3'd6: begin  // 4:2:2 only: row 12-15, col 0-3
                                                    if (la)       dc_val = (s5 + {{(BD+1){1'b0}}, 2'd2}) >> 2;
                                                    else          dc_val = {1'b1, {(BD-1){1'b0}}};
                                                end
                                                3'd7: begin  // 4:2:2 only: row 12-15, col 4-7
                                                    if (la)       dc_val = (s5 + {{(BD+1){1'b0}}, 2'd2}) >> 2;
                                                    else          dc_val = {1'b1, {(BD-1){1'b0}}};
                                                end
                                            endcase
                                            chr_dc_pred[chr_blk] <= dc_val;

                                            for (cj = 0; cj < 16; cj = cj + 1) begin
                                                reg [6:0] pidx;
                                                reg [BD-1:0] orig_pix;
                                                pidx = {chr_blk[2:1], cj[3:2], chr_blk[0], cj[1:0]};
                                                if (chr_is_cr)
                                                    orig_pix = fetched_cr[pidx*BD +: BD];
                                                else
                                                    orig_pix = fetched_cb[pidx*BD +: BD];
                                                chr_resid_4x4[cj*BD1 +: BD1] = {1'b0, orig_pix} - {1'b0, dc_val};
                                            end
                                            // verilator lint_on BLKSEQ
                                        end
                                    end
                                    blk_state <= BS_XFORM;
                                end
                                BS_XFORM: begin
                                    // Start transform (resid_mux picks chr_resid_4x4 via chr_pred_mode)
                                    if (!blk_started) begin
                                        xform_start <= 1'b1;
                                        blk_started <= 1'b1;
                                    end else if (xform_done) begin
                                        // Capture raw transform DC BEFORE quantization for Hadamard
                                        chr_dc_buf[chr_blk] <= $signed(xform_out_flat[CW-1:0]);
                                        blk_state <= BS_QUANT;
                                        blk_started <= 1'b0;
                                    end
                                end
                                BS_QUANT: begin
                                    if (!blk_started) begin
                                        quant_start <= 1'b1;
                                        blk_started <= 1'b1;
                                    end else if (quant_done) begin
                                        // Save quantized block (for AC coeffs in bitstream & reconstruction)
                                        if (chr_is_cr)
                                            cr_quant_buf[chr_blk] <= quant_out_flat;
                                        else
                                            cb_quant_buf[chr_blk] <= quant_out_flat;
                                        // Skip IQ/IT/reconstruct here — done after Hadamard in phase 1.5
                                        if (chr_blk == CHR_BLOCKS_PER_PLANE[2:0] - 3'd1) begin
                                            chr_phase <= 3'd1;
                                            blk_started <= 1'b0;
                                            chr_pred_mode <= 1'b0;
                                        end else begin
                                            chr_blk <= chr_blk + 3'd1;
                                            blk_state <= BS_PRED;
                                            blk_started <= 1'b0;
                                        end
                                    end
                                end
                                default: blk_state <= BS_PRED;
                            endcase
                        end

                        // Phase 1: Forward 2x2 Hadamard on 4 DCs
                        3'd1: begin
                            if (!blk_started) begin
                                chr_dc_in0 <= chr_dc_buf[0];
                                chr_dc_in1 <= chr_dc_buf[1];
                                chr_dc_in2 <= chr_dc_buf[2];
                                chr_dc_in3 <= chr_dc_buf[3];
                                chr_dc_in4 <= chr_dc_buf[4 % CHR_BLOCKS_PER_PLANE];
                                chr_dc_in5 <= chr_dc_buf[5 % CHR_BLOCKS_PER_PLANE];
                                chr_dc_in6 <= chr_dc_buf[6 % CHR_BLOCKS_PER_PLANE];
                                chr_dc_in7 <= chr_dc_buf[7 % CHR_BLOCKS_PER_PLANE];
                                chr_dc_inverse <= 1'b0;
                                chr_dc_start <= 1'b1;
                                blk_started <= 1'b1;
                            end else if (chr_dc_done) begin
                                if (chr_is_cr) begin
                                    cr_dc_q[0] <= chr_dc_out0;
                                    cr_dc_q[1] <= chr_dc_out1;
                                    cr_dc_q[2] <= chr_dc_out2;
                                    cr_dc_q[3] <= chr_dc_out3;
                                    if (CHROMA_FORMAT_IDC == 2) begin
                                        cr_dc_q[4] <= chr_dc_out4;
                                        cr_dc_q[5] <= chr_dc_out5;
                                        cr_dc_q[6] <= chr_dc_out6;
                                        cr_dc_q[7] <= chr_dc_out7;
                                    end
                                end else begin
                                    cb_dc_q[0] <= chr_dc_out0;
                                    cb_dc_q[1] <= chr_dc_out1;
                                    cb_dc_q[2] <= chr_dc_out2;
                                    cb_dc_q[3] <= chr_dc_out3;
                                    if (CHROMA_FORMAT_IDC == 2) begin
                                        cb_dc_q[4] <= chr_dc_out4;
                                        cb_dc_q[5] <= chr_dc_out5;
                                        cb_dc_q[6] <= chr_dc_out6;
                                        cb_dc_q[7] <= chr_dc_out7;
                                    end
                                end
                                // Now run inverse Hadamard for reconstruction
                                chr_dc_in0 <= chr_dc_out0;
                                chr_dc_in1 <= chr_dc_out1;
                                chr_dc_in2 <= chr_dc_out2;
                                chr_dc_in3 <= chr_dc_out3;
                                chr_dc_in4 <= chr_dc_out4;
                                chr_dc_in5 <= chr_dc_out5;
                                chr_dc_in6 <= chr_dc_out6;
                                chr_dc_in7 <= chr_dc_out7;
                                chr_dc_inverse <= 1'b1;
                                chr_dc_start <= 1'b1;
                                chr_phase <= 3'd2;
                                blk_started <= 1'b0;
                            end
                        end

                        // Phase 2: Capture inverse Hadamard DCs, switch Cb→Cr or → reconstruct
                        3'd2: begin
                            if (!blk_started) begin
                                blk_started <= 1'b1;
                            end else if (chr_dc_done) begin
                                chr_dc_inverse <= 1'b0;
                                if (chr_is_cr) begin
                                    cr_inv_dc[0] <= chr_dc_out0;
                                    cr_inv_dc[1] <= chr_dc_out1;
                                    cr_inv_dc[2] <= chr_dc_out2;
                                    cr_inv_dc[3] <= chr_dc_out3;
                                    if (CHROMA_FORMAT_IDC == 2) begin
                                        cr_inv_dc[4] <= chr_dc_out4;
                                        cr_inv_dc[5] <= chr_dc_out5;
                                        cr_inv_dc[6] <= chr_dc_out6;
                                        cr_inv_dc[7] <= chr_dc_out7;
                                    end
                                    // Both Cb and Cr done — proceed to reconstruction
                                    chr_is_cr <= 1'b0;
                                    chr_recon_blk <= 3'd0;
                                    chr_phase <= 3'd6;  // Reconstruction phase
                                    blk_state <= BS_PRED;
                                    blk_started <= 1'b0;
                                end else begin
                                    cb_inv_dc[0] <= chr_dc_out0;
                                    cb_inv_dc[1] <= chr_dc_out1;
                                    cb_inv_dc[2] <= chr_dc_out2;
                                    cb_inv_dc[3] <= chr_dc_out3;
                                    if (CHROMA_FORMAT_IDC == 2) begin
                                        cb_inv_dc[4] <= chr_dc_out4;
                                        cb_inv_dc[5] <= chr_dc_out5;
                                        cb_inv_dc[6] <= chr_dc_out6;
                                        cb_inv_dc[7] <= chr_dc_out7;
                                    end
                                    // Save Cb DC pred before Cr overwrites chr_dc_pred
                                    cb_dc_pred_saved[0] <= chr_dc_pred[0];
                                    cb_dc_pred_saved[1] <= chr_dc_pred[1];
                                    cb_dc_pred_saved[2] <= chr_dc_pred[2];
                                    cb_dc_pred_saved[3] <= chr_dc_pred[3];
                                    if (CHROMA_FORMAT_IDC == 2) begin
                                        cb_dc_pred_saved[4] <= chr_dc_pred[4];
                                        cb_dc_pred_saved[5] <= chr_dc_pred[5];
                                        cb_dc_pred_saved[6] <= chr_dc_pred[6];
                                        cb_dc_pred_saved[7] <= chr_dc_pred[7];
                                    end
                                    // Switch to Cr: repeat phases 0+1
                                    chr_is_cr <= 1'b1;
                                    chr_phase <= 3'd0;
                                    chr_blk <= 3'd0;
                                    blk_state <= BS_PRED;
                                    blk_started <= 1'b0;
                                end
                            end
                        end

                        // Phase 3: zigzag + CAVLC for Cb DC (4 coeffs, nC=-1)
                        3'd3: begin
                            case (blk_state)
                                BS_PRED: begin
                                    if (CHROMA_FORMAT_IDC == 2)
                                        chr_dc_zigzag_in <= {128'd0, cb_dc_q[7], cb_dc_q[6], cb_dc_q[5], cb_dc_q[4],
                                                             cb_dc_q[3], cb_dc_q[2], cb_dc_q[1], cb_dc_q[0]};
                                    else
                                        chr_dc_zigzag_in <= {192'd0, cb_dc_q[3], cb_dc_q[2], cb_dc_q[1], cb_dc_q[0]};
                                    use_chr_dc_zigzag <= 1'b1;
                                    use_chr_ac_zigzag <= 1'b0;
                                    zz_chroma_dc_mode <= 1'b1;
                                    zz_chroma_ac_mode <= 1'b0;
                                    cavlc_is_chroma_dc <= 1'b1;
                                    cavlc_is_chroma_ac <= 1'b0;
                                    zz_start <= 1'b1;
                                    blk_state <= BS_ZIGZAG;
                                end
                                BS_ZIGZAG: if (zz_done) begin
                                    if (!bs_busy) begin
                                        cavlc_start <= 1'b1;
                                        blk_state <= BS_CAVLC;
                                    end else
                                        blk_state <= BS_IQ;
                                end
                                BS_IQ: if (!bs_busy) begin
                                    cavlc_start <= 1'b1;
                                    blk_state <= BS_CAVLC;
                                end
                                BS_CAVLC: if (cavlc_done) begin
                                    use_chr_dc_zigzag <= 1'b0;
                                    zz_chroma_dc_mode <= 1'b0;
                                    cavlc_is_chroma_dc <= 1'b0;
                                    chr_phase <= 3'd4;
                                    blk_state <= BS_PRED;
                                end
                                default: blk_state <= BS_PRED;
                            endcase
                        end

                        // Phase 4: zigzag + CAVLC for Cr DC (nC=-1)
                        3'd4: begin
                            case (blk_state)
                                BS_PRED: begin
                                    if (CHROMA_FORMAT_IDC == 2)
                                        chr_dc_zigzag_in <= {128'd0, cr_dc_q[7], cr_dc_q[6], cr_dc_q[5], cr_dc_q[4],
                                                             cr_dc_q[3], cr_dc_q[2], cr_dc_q[1], cr_dc_q[0]};
                                    else
                                        chr_dc_zigzag_in <= {192'd0, cr_dc_q[3], cr_dc_q[2], cr_dc_q[1], cr_dc_q[0]};
                                    use_chr_dc_zigzag <= 1'b1;
                                    use_chr_ac_zigzag <= 1'b0;
                                    zz_chroma_dc_mode <= 1'b1;
                                    zz_chroma_ac_mode <= 1'b0;
                                    cavlc_is_chroma_dc <= 1'b1;
                                    cavlc_is_chroma_ac <= 1'b0;
                                    zz_start <= 1'b1;
                                    blk_state <= BS_ZIGZAG;
                                end
                                BS_ZIGZAG: if (zz_done) begin
                                    if (!bs_busy) begin
                                        cavlc_start <= 1'b1;
                                        blk_state <= BS_CAVLC;
                                    end else
                                        blk_state <= BS_IQ;
                                end
                                BS_IQ: if (!bs_busy) begin
                                    cavlc_start <= 1'b1;
                                    blk_state <= BS_CAVLC;
                                end
                                BS_CAVLC: if (cavlc_done) begin
                                    use_chr_dc_zigzag <= 1'b0;
                                    zz_chroma_dc_mode <= 1'b0;
                                    cavlc_is_chroma_dc <= 1'b0;
                                    chr_phase <= 3'd5;
                                    chr_blk <= 3'd0;
                                    chr_is_cr <= 1'b0;
                                    blk_state <= BS_PRED;
                                end
                                default: blk_state <= BS_PRED;
                            endcase
                        end

                        // Phase 5: zigzag + CAVLC chroma AC (Cb×4 then Cr×4)
                        3'd5: begin
                            sub_blk <= chr_is_cr ? (5'd16 + CHR_BLOCKS_PER_PLANE[4:0] + {2'd0, chr_blk}) : (5'd16 + {2'd0, chr_blk});
                            case (blk_state)
                                BS_PRED: begin
                                    if (chr_is_cr)
                                        chr_ac_zigzag_in <= {cr_quant_buf[chr_blk][255:16], 16'd0};
                                    else
                                        chr_ac_zigzag_in <= {cb_quant_buf[chr_blk][255:16], 16'd0};
                                    use_chr_ac_zigzag <= 1'b1;
                                    use_chr_dc_zigzag <= 1'b0;
                                    zz_chroma_dc_mode <= 1'b0;
                                    zz_chroma_ac_mode <= 1'b1;
                                    cavlc_is_chroma_dc <= 1'b0;
                                    cavlc_is_chroma_ac <= 1'b1;
                                    zz_start <= 1'b1;
                                    blk_state <= BS_ZIGZAG;
                                end
                                BS_ZIGZAG: if (zz_done) begin
                                    nz_coeff[chr_is_cr ? (5'd16 + CHR_BLOCKS_PER_PLANE[4:0] + {2'd0, chr_blk}) : (5'd16 + {2'd0, chr_blk})] <= total_coeffs;
                                    if (!bs_busy) begin
                                        cavlc_start <= 1'b1;
                                        blk_state <= BS_CAVLC;
                                    end else
                                        blk_state <= BS_IQ;
                                end
                                BS_IQ: if (!bs_busy) begin
                                    cavlc_start <= 1'b1;
                                    blk_state <= BS_CAVLC;
                                end
                                BS_CAVLC: if (cavlc_done) begin
                                    if (chr_blk == CHR_BLOCKS_PER_PLANE[2:0] - 3'd1) begin
                                        if (chr_is_cr) begin
                                            use_chr_ac_zigzag <= 1'b0;
                                            cavlc_is_chroma_ac <= 1'b0;
                                            zz_chroma_ac_mode <= 1'b0;
                                            top_state <= is_inter_mb_reg ? TS_NEXT_MB : TS_DEFER_MB_HDR;
                                            blk_started <= 1'b0;
                                        end else begin
                                            chr_is_cr <= 1'b1;
                                            chr_blk <= 3'd0;
                                            blk_state <= BS_PRED;
                                        end
                                    end else begin
                                        chr_blk <= chr_blk + 3'd1;
                                        blk_state <= BS_PRED;
                                    end
                                end
                                default: blk_state <= BS_PRED;
                            endcase
                        end

                        // Phase 6: Chroma reconstruction using inverse Hadamard DCs
                        // For each block: load quant_buf with DC=0 → IQ → replace DC with inv Hadamard → IT → reconstruct
                        // Processes Cb×4 then Cr×4
                        3'd6: begin
                            case (blk_state)
                                BS_PRED: begin
                                    // Load quantized block into IQ input with DC zeroed
                                    if (chr_is_cr)
                                        chr_iq_input <= {cr_quant_buf[chr_recon_blk][255:16], 16'd0};
                                    else
                                        chr_iq_input <= {cb_quant_buf[chr_recon_blk][255:16], 16'd0};
                                    use_chr_iq_input <= 1'b1;
                                    iq_start <= 1'b1;
                                    blk_state <= BS_ZIGZAG; // reuse as IQ wait state
                                    iq_done_latched <= 1'b0;
                                end
                                BS_ZIGZAG: begin // waiting for IQ
                                    if (iq_done || iq_done_latched) begin
                                        // Patch IT input: replace DC with inverse Hadamard value
                                        use_chr_it_input <= 1'b1;
                                        if (chr_is_cr)
                                            chr_it_dc_patch <= cr_inv_dc[chr_recon_blk];
                                        else
                                            chr_it_dc_patch <= cb_inv_dc[chr_recon_blk];
                                        blk_state <= BS_IT;
                                        blk_started <= 1'b0;
                                    end else if (iq_done)
                                        iq_done_latched <= 1'b1;
                                end
                                BS_IT: begin
                                    if (!blk_started) begin
                                        it_start <= 1'b1;
                                        blk_started <= 1'b1;
                                    end else if (it_done) begin
                                        use_chr_iq_input <= 1'b0;
                                        use_chr_it_input <= 1'b0;
                                        // Reconstruct: pred + IT_output, clamped to [0, MAX_PIX]
                                        begin : chr_recon_phase6
                                            // verilator lint_off BLKSEQ
                                            integer ci;
                                            reg [6:0] pix_idx_0;
                                            reg signed [16:0] sum_0;
                                            reg [BD-1:0] clamp_0, pred_val;
                                            for (ci = 0; ci < 16; ci = ci + 1) begin
                                                pix_idx_0 = {chr_recon_blk[2:1], ci[3:2], chr_recon_blk[0], ci[1:0]};
                                                if (inter_chr_mode) begin
                                                    if (chr_is_cr)
                                                        pred_val = inter_chr_pred_cr[pix_idx_0*BD +: BD];
                                                    else
                                                        pred_val = inter_chr_pred_cb[pix_idx_0*BD +: BD];
                                                end else begin
                                                    // Cb uses saved DC pred (chr_dc_pred was overwritten by Cr)
                                                    if (chr_is_cr)
                                                        pred_val = chr_dc_pred[chr_recon_blk];
                                                    else
                                                        pred_val = cb_dc_pred_saved[chr_recon_blk];
                                                end
                                                sum_0 = $signed({{(17-BD){1'b0}}, pred_val}) + $signed(it_out_flat[ci*16 +: 16]);
                                                clamp_0 = (sum_0 < 0) ? {BD{1'b0}} : (sum_0 > $signed({1'b0, {BD{1'b1}}})) ? {BD{1'b1}} : sum_0[BD-1:0];
                                                if (chr_is_cr)
                                                    chr_recon_cr[pix_idx_0*BD +: BD] <= clamp_0;
                                                else
                                                    chr_recon_cb[pix_idx_0*BD +: BD] <= clamp_0;
                                            end
                                            // verilator lint_on BLKSEQ
                                        end
                                        if (chr_recon_blk == CHR_BLOCKS_PER_PLANE[2:0] - 3'd1) begin
                                            if (chr_is_cr) begin
                                                // Both Cb and Cr reconstructed — proceed to CAVLC
                                                chr_phase <= 3'd3;
                                                blk_state <= BS_PRED;
                                                blk_started <= 1'b0;
                                            end else begin
                                                chr_is_cr <= 1'b1;
                                                chr_recon_blk <= 3'd0;
                                                blk_state <= BS_PRED;
                                                blk_started <= 1'b0;
                                            end
                                        end else begin
                                            chr_recon_blk <= chr_recon_blk + 3'd1;
                                            blk_state <= BS_PRED;
                                            blk_started <= 1'b0;
                                        end
                                    end
                                end
                                default: blk_state <= BS_PRED;
                            endcase
                        end

                        default: chr_phase <= 3'd0;
                    endcase
                end

                TS_TRAILING: if (!bs_busy) begin bs_cmd_trailing <= 1'b1; flush_pending <= 1'b0; flush_accepted <= 1'b0; top_state <= TS_DONE; end
                TS_DONE: if (!flush_pending) begin if (bs_cmd_done) begin bs_cmd_flush <= 1'b1; flush_pending <= 1'b1; end end
                         else if (!flush_accepted) flush_accepted <= 1'b1;
                         else if (bs_cmd_done) begin done <= 1'b1; top_state <= TS_IDLE; dbg_frame_cnt <= dbg_frame_cnt + 8'd1; end
                default: top_state <= TS_IDLE;
            endcase
        end
    end

    // Debug: frame counter and CAVLC trace
    reg [7:0] dbg_frame_cnt;
    initial dbg_frame_cnt = 8'd0;

    /* verilator lint_off UNUSED */
    wire dbg_target_mb = (dbg_frame_cnt == 8'd23);
    wire dbg_detail_mb = (dbg_frame_cnt == 8'd23) && (mb_count >= 12'd140 && mb_count <= 12'd155);
    /* verilator lint_on UNUSED */

    always @(posedge clk) begin
        // dbg_frame_cnt is reset and advanced in the main FSM block; keep this
        // debug trace block read-only to avoid multi-driver/reset lint noise.
        if (dbg_frame_cnt == 8'd0 && cavlc_start && mb_count >= 9'd40 && mb_count <= 9'd44) begin
            $display("[CAV] F%0d MB%0d sb=%0d nC=%0d tc=%0d t1=%0d chDC=%0d ch422=%0d chAC=%0d nA=%0d nB=%0d sbr=%0d sbc=%0d topidx=%0d leftidx=%0d",
                dbg_frame_cnt, mb_count, sub_blk, nC_val, total_coeffs, trailing_ones,
                cavlc_is_chroma_dc, chroma_dc_422_flag, cavlc_is_chroma_ac,
                nA_val, nB_val, sb_r, sb_c, top_blk_idx, left_blk_idx);
        end
        if (dbg_frame_cnt == 8'd0 && cavlc_bits_valid && mb_count >= 9'd40 && mb_count <= 9'd44) begin
            $display("[CVO] F%0d MB%0d sb=%0d bits=%08x count=%0d chDC=%0d",
                dbg_frame_cnt, mb_count, sub_blk, cavlc_bits, cavlc_count, cavlc_is_chroma_dc);
        end
        // Log MB header for ALL MBs in frame 23
        if (dbg_frame_cnt == 8'd23 && bs_cmd_mb_hdr) begin
            $display("[MBH] F%0d MB%0d x=%0d y=%0d inter=%0d mvx=%0d mvy=%0d mvpx=%0d mvpy=%0d mvdx=%0d mvdy=%0d bytes=%0d",
                dbg_frame_cnt, mb_count, mb_x, mb_y, is_inter_mb_reg,
                $signed(me_best_mvx), $signed(me_best_mvy),
                $signed(mvp_x), $signed(mvp_y),
                $signed(mvd_x_w), $signed(mvd_y_w),
                bs_bytes_written);
        end
        // Log left_mb_nz at MB start (sub_blk=0, first cavlc_start)
        if (dbg_detail_mb && cavlc_start && sub_blk == 5'd0) begin
            $display("[DBG] F%0d MB%0d LEFT_NZ[0]=%0d [1]=%0d [2]=%0d [3]=%0d  TOP_NZ[%0d]=%0d [%0d]=%0d [%0d]=%0d [%0d]=%0d  mb_left=%0d mb_top=%0d",
                dbg_frame_cnt, mb_count,
                left_mb_nz[0], left_mb_nz[1], left_mb_nz[2], left_mb_nz[3],
                mb_x*4+0, top_mb_nz[mb_x*4+0], mb_x*4+1, top_mb_nz[mb_x*4+1],
                mb_x*4+2, top_mb_nz[mb_x*4+2], mb_x*4+3, top_mb_nz[mb_x*4+3],
                mb_left_avail, mb_top_avail);
        end
        // Log quantized levels for target MB sub-blocks
        if (dbg_detail_mb && top_state == TS_ENCODE_SBLK && blk_state == BS_QUANT && quant_done && sub_blk <= 5'd3) begin
            $display("[DBG] F%0d MB%0d sub%0d QUANT: %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                dbg_frame_cnt, mb_count, sub_blk,
                $signed(quant_out_flat[15:0]), $signed(quant_out_flat[31:16]), $signed(quant_out_flat[47:32]), $signed(quant_out_flat[63:48]),
                $signed(quant_out_flat[79:64]), $signed(quant_out_flat[95:80]), $signed(quant_out_flat[111:96]), $signed(quant_out_flat[127:112]),
                $signed(quant_out_flat[143:128]), $signed(quant_out_flat[159:144]), $signed(quant_out_flat[175:160]), $signed(quant_out_flat[191:176]),
                $signed(quant_out_flat[207:192]), $signed(quant_out_flat[223:208]), $signed(quant_out_flat[239:224]), $signed(quant_out_flat[255:240]));
        end

        // Chroma DC debug for specific MBs
        if (top_state == TS_CHROMA && dbg_detail_mb) begin
            // Phase 1: forward Hadamard DC inputs
            if (chr_phase == 3'd1 && chr_dc_start) begin
                $display("[CHR] F%0d MB%0d %s FWD_HAD in: %0d %0d %0d %0d",
                    dbg_frame_cnt, mb_count, chr_is_cr ? "Cr" : "Cb",
                    $signed(chr_dc_buf[0]), $signed(chr_dc_buf[1]),
                    $signed(chr_dc_buf[2]), $signed(chr_dc_buf[3]));
            end
            // Phase 1: forward Hadamard done (quantized output)
            if (chr_phase == 3'd1 && chr_dc_done) begin
                $display("[CHR] F%0d MB%0d %s FWD_OUT: %0d %0d %0d %0d",
                    dbg_frame_cnt, mb_count, chr_is_cr ? "Cr" : "Cb",
                    $signed(chr_dc_out0), $signed(chr_dc_out1),
                    $signed(chr_dc_out2), $signed(chr_dc_out3));
            end
            // Phase 2: inverse Hadamard done
            if (chr_phase == 3'd2 && chr_dc_done) begin
                $display("[CHR] F%0d MB%0d %s INV_OUT: %0d %0d %0d %0d",
                    dbg_frame_cnt, mb_count, chr_is_cr ? "Cr" : "Cb",
                    $signed(chr_dc_out0), $signed(chr_dc_out1),
                    $signed(chr_dc_out2), $signed(chr_dc_out3));
            end
            // Phase 6: reconstruction DC value per block
            if (chr_phase == 3'd6 && blk_state == BS_IT && it_done) begin
                $display("[CHR] F%0d MB%0d %s RECON blk=%0d inv_dc=%0d pred=%0d it0=%0d it1=%0d it2=%0d it3=%0d",
                    dbg_frame_cnt, mb_count, chr_is_cr ? "Cr" : "Cb",
                    chr_recon_blk,
                    $signed(chr_is_cr ? cr_inv_dc[chr_recon_blk] : cb_inv_dc[chr_recon_blk]),
                    chr_is_cr ? chr_dc_pred[chr_recon_blk] : cb_dc_pred_saved[chr_recon_blk],
                    $signed(it_out_flat[15:0]), $signed(it_out_flat[31:16]),
                    $signed(it_out_flat[47:32]), $signed(it_out_flat[63:48]));
            end
            // Phase 3: Cb DC CAVLC input
            if (chr_phase == 3'd3 && blk_state == BS_PRED) begin
                $display("[CHR] F%0d MB%0d CbDC CAVLC in: %0d %0d %0d %0d",
                    dbg_frame_cnt, mb_count,
                    $signed(cb_dc_q[0]), $signed(cb_dc_q[1]),
                    $signed(cb_dc_q[2]), $signed(cb_dc_q[3]));
            end
            // Phase 4: Cr DC CAVLC input
            if (chr_phase == 3'd4 && blk_state == BS_PRED) begin
                $display("[CHR] F%0d MB%0d CrDC CAVLC in: %0d %0d %0d %0d",
                    dbg_frame_cnt, mb_count,
                    $signed(cr_dc_q[0]), $signed(cr_dc_q[1]),
                    $signed(cr_dc_q[2]), $signed(cr_dc_q[3]));
            end
        end
    end

endmodule
