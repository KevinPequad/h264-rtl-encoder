// h264_encoder_top.v — Top-Level H.264 Encoder (IDR + P + limited B support)
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
    parameter MB_ROWS      = FRAME_HEIGHT / 16,
    parameter ENABLE_IDR_IPCM = 0,
    parameter IPCM_SAD_THRESHOLD = 18000,
    parameter ENABLE_P_IPCM = 0,
    parameter INTER_SAD_THRESHOLD = 8000,
    parameter ENABLE_CABAC_PSKIP = 0,
    parameter ENABLE_CABAC_P16X16 = 0,
    parameter ENABLE_CABAC_P16X16_FULLPEL_ONLY = 0,
    parameter WEIGHTED_PRED_ENABLE = 0,
    parameter LUMA_LOG2_WEIGHT_DENOM = 0,
    parameter integer LUMA_WEIGHT = 1,
    parameter integer LUMA_OFFSET = 0,
    parameter CHROMA_LOG2_WEIGHT_DENOM = 0,
    parameter integer CHROMA_WEIGHT_CB = 1,
    parameter integer CHROMA_OFFSET_CB = 0,
    parameter integer CHROMA_WEIGHT_CR = 1,
    parameter integer CHROMA_OFFSET_CR = 0,
    parameter DEBLOCK_ENABLE = 1,
    parameter DISABLE_DEBLOCKING_FILTER_IDC = 0
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    output reg         done,

    // Frame number (8-bit, supports longer GOP intervals before wrap)
    input  wire [7:0]  frame_num_in,
    // pic_order_cnt_lsb is carried independently so reordered B-picture GOPs
    // do not have to fake display order through frame_num.
    input  wire [8:0]  pic_order_cnt_lsb_in,
    // IDR flag (1 for IDR/I-frame, 0 for non-IDR slice types)
    input  wire        is_idr_in,
    // B-slice flag for non-IDR pictures. Current RTL support is limited to
    // intra/I_PCM coding on this path, so inter B tools remain future work.
    input  wire        is_b_in,
    // Reference-B flag for non-IDR B pictures. The current RTL path supports a
    // limited single-list BREF mode that can be inserted into the ref bank.
    input  wire        is_bref_in,
    // Stream-level GOP contract used while writing the first SPS/PPS. Future B
    // pictures are not visible on the IDR cycle, so the testbench/control lane
    // supplies this when a run can emit B/BREF pictures later in the stream.
    input  wire        stream_has_b_slices_in,
    // Validation override: force eligible reordered B inter MBs onto the
    // current B_BI_16x16 path.
    input  wire        force_b_bi_in,
    // Validation override: force eligible reordered B inter MBs onto the
    // current B_L0_16x16 path, preserving the selected past reference index.
    input  wire        force_b_l0_in,
    // Validation override: force eligible reordered B inter MBs onto the
    // current B_L1_16x16 path.
    input  wire        force_b_l1_in,
    // Validation override: force eligible reordered B inter MBs onto the
    // current B_DIRECT_16x16 path.
    input  wire        force_b_direct_in,
    // Validation override: switch direct-mode derivation to the current
    // limited temporal-direct path for the whole B slice.
    input  wire        force_b_direct_temporal_in,
    // Validation override: force the encoder to signal and use High-profile
    // 8x8 transform mode on supported 4:2:0 8-bit validation runs.
    input  wire        force_transform_8x8_in,

    // Raw frame memory read port (YUV420 planar)
    output wire [20:0] raw_mem_addr,
    input  wire [BIT_DEPTH-1:0]  raw_mem_data,

    // Reference frame memory (external, luma only)
    output reg  [2:0]  ref_rd_bank_sel,
    output reg  [19:0] ref_mem_rd_addr,
    input  wire [BIT_DEPTH-1:0]  ref_mem_rd_data,
    output reg  [2:0]  ref_wr_bank_sel,
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
                                              + ((CHROMA_FORMAT_IDC == 3) ? (FRAME_WIDTH * FRAME_HEIGHT)
                                                                          : (CHROMA_FORMAT_IDC == 2) ? (FRAME_WIDTH * FRAME_HEIGHT / 2)
                                                                                                      : (FRAME_WIDTH * FRAME_HEIGHT / 4));
    localparam CHR_WIDTH            = (CHROMA_FORMAT_IDC == 3) ? FRAME_WIDTH : (FRAME_WIDTH / 2);
    localparam CHR_HEIGHT           = (CHROMA_FORMAT_IDC == 1) ? (FRAME_HEIGHT / 2) : FRAME_HEIGHT;
    localparam CHR_MB_WIDTH         = (CHROMA_FORMAT_IDC == 3) ? 16 : 8;
    localparam CHR_MB_HEIGHT        = (CHROMA_FORMAT_IDC == 1) ? 8 : 16;
    localparam CHR_MB_PIXELS        = CHR_MB_WIDTH * CHR_MB_HEIGHT;
    localparam CHR_BLOCK_ROWS       = CHR_MB_HEIGHT / 4;
    localparam CHR_BLOCK_COLS       = CHR_MB_WIDTH / 4;
    localparam CHR_BLOCKS_PER_PLANE = CHR_BLOCK_COLS * CHR_BLOCK_ROWS;
    // Storage-sized to the largest chroma plane this RTL supports (4:4:4 => 16
    // 4x4 blocks) so parameter-gated 4:2:2 DC paths do not leave static
    // out-of-range selects when linting the default 4:2:0 configuration.
    localparam CHR_BLOCKS_STORAGE   = 16;
    localparam CHR_RAW_ROWS_MAX     = (CHROMA_FORMAT_IDC == 1) ? 9 : 17;
    localparam CHR_RAW_COLS_MAX     = (CHROMA_FORMAT_IDC == 3) ? 17 : 9;
    localparam CHR_RAW_SAMPLES      = CHR_RAW_ROWS_MAX * CHR_RAW_COLS_MAX;
    localparam LUMA_RAW_ROWS        = 21;
    localparam LUMA_RAW_COLS        = 21;
    localparam LUMA_RAW_SAMPLES     = LUMA_RAW_ROWS * LUMA_RAW_COLS;
    localparam TOTAL_MBS            = MB_COLS * MB_ROWS;
    localparam TOTAL_SUB_BLOCKS     = 16 + 2 * CHR_BLOCKS_PER_PLANE;
    localparam integer SUB_BLK_W    = (TOTAL_SUB_BLOCKS <= 1) ? 1 : $clog2(TOTAL_SUB_BLOCKS);
    localparam integer CHR_BLK_W    = (CHR_BLOCKS_PER_PLANE <= 1) ? 1 : $clog2(CHR_BLOCKS_PER_PLANE);
    localparam integer CHR_TOP_NZ_COUNT = MB_COLS * CHR_BLOCK_COLS;
    localparam integer CHR_FETCH_W  = $clog2(CHR_RAW_SAMPLES + 1);
    localparam integer CHR_FETCH_COL_W = $clog2(CHR_RAW_COLS_MAX + 1);
    localparam integer DEFAULT_LUMA_WEIGHT = (1 << LUMA_LOG2_WEIGHT_DENOM);
    localparam integer DEFAULT_CHROMA_WEIGHT = (1 << CHROMA_LOG2_WEIGHT_DENOM);

    // SAD threshold: if ME SAD > this, use intra instead of inter for this MB
    localparam        ENABLE_IDR_INTRA16 = 1'b1;
    wire allow_idr_intra16_w = ENABLE_IDR_INTRA16 && (CHROMA_FORMAT_IDC != 3);

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
    localparam TS_I16_PRED     = 5'd20;  // Run Intra_16x16 prediction once per intra MB
    localparam TS_LUMA16       = 5'd21;  // I_16x16 luma DC/AC coding and reconstruction
    localparam TS_LUMA_FETCH   = 5'd22;  // Fetch luma window for quarter-pel refinement
    localparam TS_SKIP_MB_HDR   = 5'd23; // Emit skip-run syntax after early probe
    localparam TS_SKIP_CLR_FIFO = 5'd24; // Drop deferred residual syntax before emitting P_SKIP
    localparam TS_DEFER_DRAIN   = 5'd25; // Drain deferred residual FIFO after buffered MB header
    localparam TS_DEBLOCK_MB    = 5'd26; // Read current-picture neighbour samples for deblock boundary filtering
    localparam TS_LUMA8         = 5'd27; // High-profile 8x8 luma transform path

    reg [4:0]  top_state;
    reg [6:0]  mb_x;
    reg [5:0]  mb_y;
    reg [SUB_BLK_W-1:0] sub_blk;
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
    reg        is_b_frame;         // 1 if current frame is any B-slice
    reg        is_b_ref_frame;     // 1 if current frame is a reference B-slice
    reg        is_inter_mb_reg;    // 1 if current MB uses inter prediction
    reg        is_skip_mb_reg;     // 1 if current MB is emitted as P_SKIP
    reg        is_b_l1_mb_reg;     // 1 if current B inter MB uses List1 instead of List0
    reg        is_b_bi_mb_reg;     // 1 if current B inter MB uses bidirectional prediction
    reg        is_b_direct_mb_reg; // 1 if current B inter MB uses B_DIRECT_16x16 syntax
    reg        is_b_direct_from_l1_reg;
    reg        use_intra16_mb_reg; // 1 if current intra MB uses Intra_16x16
    reg        use_ipcm_mb_reg;    // 1 if current intra MB uses I_PCM
    reg [7:0]  cur_frame_num;      // Latched frame number
    reg [8:0]  cur_pic_order_cnt_lsb;
    reg signed [7:0] me_best_mvx;  // Best MV from ME
    reg signed [7:0] me_best_mvy;
    reg signed [7:0] me_best_mvx_l0;
    reg signed [7:0] me_best_mvy_l0;
    reg signed [7:0] me_best_mvx_l1;
    reg signed [7:0] me_best_mvy_l1;
    reg [17:0] me_best_sad;
    reg [17:0] me_fullpel_best_sad;

    // Inter prediction buffer: stores the reference block from ME
    reg [256*BIT_DEPTH-1:0] inter_pred_buf;

    // Full-pel MV saved for chroma offset computation
    reg signed [7:0] me_fullpel_mvx, me_fullpel_mvy;
    reg        luma_fetch_started;
    reg [8:0]  luma_fetch_cnt;
    reg [4:0]  luma_f_row, luma_f_col;
    reg [LUMA_RAW_SAMPLES*BD-1:0] luma_raw;
    reg        b_bi_luma_fetch_l1_phase;
    reg [256*BIT_DEPTH-1:0] b_bi_fullpel_ref_l1;
    reg [17:0] b_bi_fullpel_sad_l1;
    reg [256*BIT_DEPTH-1:0] b_bi_luma_pred_l0;
    reg [17:0] b_bi_luma_sad_l0;
    reg        b_direct_pending_valid;
    reg        b_direct_pending_use_l1;
    reg        b_direct_pending_use_bi;
    reg        b_direct_pending_from_col_l1;
    reg [1:0]  b_direct_pending_ref_idx_l0, b_direct_pending_ref_idx_l1;
    reg signed [7:0] b_direct_pending_mvx_l0, b_direct_pending_mvy_l0;
    reg signed [7:0] b_direct_pending_mvx_l1, b_direct_pending_mvy_l1;
    reg [256*BIT_DEPTH-1:0] b_direct_luma_pred_l0;
    reg [17:0] b_direct_luma_sad_l0;
    reg signed [7:0] b_bi_mvp_x_l0_reg, b_bi_mvp_y_l0_reg;
    reg signed [7:0] b_bi_mvp_x_l1_reg, b_bi_mvp_y_l1_reg;

    // Inter chroma prediction buffers (8x8 for 4:2:0, 8x16 for 4:2:2)
    reg [CHR_MB_PIXELS*BIT_DEPTH-1:0] inter_chr_pred_cb, inter_chr_pred_cr;
    reg [CHR_MB_PIXELS*BIT_DEPTH-1:0] b_bi_chr_pred_cb_l0, b_bi_chr_pred_cr_l0;
    reg        inter_chr_mode;     // 1 = inter chroma prediction (vs intra DC)
    reg [CHR_FETCH_W-1:0] chr_fetch_cnt;
    reg        chr_fetch_started;  // 1 after initial address setup
    reg        b_bi_chr_fetch_l1_phase;
    reg        skip_probe_pending; // 1 while early chroma fetch decides P_SKIP
    reg        inter_chr_prefetched_valid; // 1 if inter chroma prediction was prefetched before luma coding
    // Chroma half-pel interpolation raw fetch buffers
    reg [CHR_RAW_SAMPLES*BD-1:0] chr_raw_cb, chr_raw_cr;
    reg [2:0]  chr_frac_x, chr_frac_y; // 1/8-pel chroma fraction (0,2,4,6)
    reg [4:0]  chr_fetch_rows; // up to 17 for 4:2:2 fractional
    reg [CHR_FETCH_COL_W-1:0] chr_fetch_cols;

    // Reference write-back counter
    reg [8:0]  ref_wr_idx;
    localparam [2:0] DBF_IDLE        = 3'd0;
    localparam [2:0] DBF_LEFT_LUMA   = 3'd1;
    localparam [2:0] DBF_TOP_LUMA    = 3'd2;
    localparam [2:0] DBF_LEFT_CHROMA = 3'd3;
    localparam [2:0] DBF_TOP_CHROMA  = 3'd4;
    localparam [2:0] DBW_LEFT_LUMA   = 3'd0;
    localparam [2:0] DBW_TOP_LUMA    = 3'd1;
    localparam [2:0] DBW_LEFT_CHROMA = 3'd2;
    localparam [2:0] DBW_TOP_CHROMA  = 3'd3;
    localparam [2:0] DBW_CUR_LUMA    = 3'd4;
    localparam [2:0] DBW_CUR_CHROMA  = 3'd5;
    reg [2:0]  deblock_fetch_phase;
    reg [2:0]  deblock_wr_phase;
    reg [6:0]  deblock_fetch_idx;
    reg        deblock_fetch_started;
    reg [64*BD-1:0] deblock_left_luma_p_buf;
    reg [64*BD-1:0] deblock_top_luma_p_buf;
    reg [4*CHR_MB_HEIGHT*BD-1:0] deblock_left_cb_p_buf;
    reg [4*CHR_MB_HEIGHT*BD-1:0] deblock_left_cr_p_buf;
    reg [4*CHR_MB_WIDTH*BD-1:0] deblock_top_cb_p_buf;
    reg [4*CHR_MB_WIDTH*BD-1:0] deblock_top_cr_p_buf;

    // MV storage for prediction (per-MB row above + left MB)
    reg signed [7:0] top_mvx [0:MB_COLS-1];  // Top row MV x (one per MB column)
    reg signed [7:0] top_mvy [0:MB_COLS-1];  // Top row MV y
    reg signed [7:0] left_mvx;        // Left MB MV x
    reg signed [7:0] left_mvy;        // Left MB MV y
    reg [6:0] top_mvd_abs_x [0:MB_COLS-1];
    reg [6:0] top_mvd_abs_y [0:MB_COLS-1];
    reg [6:0] left_mvd_abs_x;
    reg [6:0] left_mvd_abs_y;
    reg signed [7:0] top_mvx_l1 [0:MB_COLS-1];
    reg signed [7:0] top_mvy_l1 [0:MB_COLS-1];
    reg signed [7:0] left_mvx_l1;
    reg signed [7:0] left_mvy_l1;
    reg        top_is_inter [0:MB_COLS-1];   // 1 if top MB was inter
    reg        left_is_inter;         // 1 if left MB was inter
    reg        top_is_skip [0:MB_COLS-1];
    reg        left_is_skip;
    reg        top_is_inter_l1 [0:MB_COLS-1];
    reg        left_is_inter_l1;
    reg        top_is_b_l1 [0:MB_COLS-1];
    reg        left_is_b_l1;
    reg [1:0]  top_ref_idx [0:MB_COLS-1];
    reg [1:0]  left_ref_idx;
    reg [1:0]  top_ref_idx_l1 [0:MB_COLS-1];
    reg [1:0]  left_ref_idx_l1;
    // Diagonal (top-left) saved before top_mvx[mb_x] is overwritten
    reg signed [7:0] diag_mvx, diag_mvy;
    reg signed [7:0] diag_mvx_l1, diag_mvy_l1;
    reg        diag_is_inter;
    reg        diag_is_inter_l1;
    reg        diag_is_b_l1;
    reg [1:0]  diag_ref_idx;
    reg [1:0]  diag_ref_idx_l1;
    reg [1:0]  mb_ref_idx_reg;
    reg [1:0]  mb_ref_idx_l1_reg;
    reg [1:0]  me_search_pass;
    reg [2:0]  valid_ref_count;
    reg [2:0]  newest_ref_bank;
    reg [2:0]  older_ref_bank;
    reg [2:0]  oldest_ref_bank;
    reg [2:0]  ancient_ref_bank;
    reg [2:0]  next_write_bank;
    reg [2:0]  current_write_bank;
    reg [1:0]  slice_num_ref_idx_l0_active_minus1;
    reg signed [7:0] me_pass0_mvx, me_pass0_mvy;
    reg [17:0] me_pass0_sad;
    reg [256*BIT_DEPTH-1:0] me_pass0_ref_mb;
    reg [1:0]  me_pass0_ref_idx;
    reg        b_l0_pass_valid [0:2];
    reg signed [7:0] b_l0_pass_mvx [0:2];
    reg signed [7:0] b_l0_pass_mvy [0:2];
    reg [17:0] b_l0_pass_sad [0:2];
    reg [256*BIT_DEPTH-1:0] b_l0_pass_ref_mb [0:2];

    // MV predictor (median of A, B, C)
    reg signed [7:0] mvp_x, mvp_y;
    reg signed [7:0] mvp_x_l0, mvp_y_l0;
    reg signed [7:0] mvp_x_l1, mvp_y_l1;
    // MVD = actual MV - predicted MV (9-bit to avoid overflow: max ±128)
    wire signed [8:0] mvd_x_w = {me_best_mvx[7], me_best_mvx} - {mvp_x[7], mvp_x};
    wire signed [8:0] mvd_y_w = {me_best_mvy[7], me_best_mvy} - {mvp_y[7], mvp_y};
    wire signed [8:0] mvd_x_l0_w = {me_best_mvx_l0[7], me_best_mvx_l0} - {mvp_x_l0[7], mvp_x_l0};
    wire signed [8:0] mvd_y_l0_w = {me_best_mvy_l0[7], me_best_mvy_l0} - {mvp_y_l0[7], mvp_y_l0};
    wire signed [8:0] mvd_x_l1_w = {me_best_mvx_l1[7], me_best_mvx_l1} - {mvp_x_l1[7], mvp_x_l1};
    wire signed [8:0] mvd_y_l1_w = {me_best_mvy_l1[7], me_best_mvy_l1} - {mvp_y_l1[7], mvp_y_l1};
    wire [5:0] intra_ipcm_type_code =
        is_b_frame ? 6'd48 : (is_p_frame ? 6'd30 : 6'd25);
    wire [5:0] intra_i4_type_code =
        is_b_frame ? 6'd23 : (is_p_frame ? 6'd5 : 6'd0);
    wire [5:0] intra_i16_base_type_code =
        is_b_frame ? 6'd24 : (is_p_frame ? 6'd6 : 6'd1);
    wire allow_nonidr_ipcm = (ENABLE_P_IPCM != 0);
    wire allow_ipcm_w = is_idr_in ? (ENABLE_IDR_IPCM != 0) : allow_nonidr_ipcm;

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
    reg         intra16_start;
    wire        intra16_done;
    reg         sb_top_avail, sb_left_avail, sb_top_left_avail;
    reg [4*BIT_DEPTH-1:0]  sb_top_pixels;
    reg [4*BIT_DEPTH-1:0]  sb_top_right_pixels;
    reg [4*BIT_DEPTH-1:0]  sb_left_pixels;
    reg [BIT_DEPTH-1:0]    sb_top_left_pixel;
    reg [16*BIT_DEPTH-1:0] sb_orig_pixels;
    wire [16*BIT_DEPTH-1:0]      pred_4x4_w;
    wire [16*(BIT_DEPTH+1)-1:0]  resid_4x4_w;
    wire [3:0]                   pred_mode_w;
    wire [256*BIT_DEPTH-1:0]     intra16_pred_w;
    wire [1:0]                   intra16_mode_w;
    wire [BIT_DEPTH+8:0]         intra16_sad_w;

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
    reg  [256*BIT_DEPTH-1:0] luma_recon_buf;
    wire [256*BIT_DEPTH-1:0] recon_out_w;
    wire [16*BIT_DEPTH-1:0]  recon_top_row_w;
    wire [16*BIT_DEPTH-1:0]  recon_right_col_w;
    reg  [16*BIT_DEPTH-1:0]  recon_top_row_buf_w;
    reg  [16*BIT_DEPTH-1:0]  recon_right_col_buf_w;

    // Chroma reconstruction buffers (8x8 for 4:2:0, 8x16 for 4:2:2, 16x16 for 4:4:4)
    reg [CHR_MB_PIXELS*BIT_DEPTH-1:0] chr_recon_cb;
    reg [CHR_MB_PIXELS*BIT_DEPTH-1:0] chr_recon_cr;
    reg [256*BIT_DEPTH-1:0] intra16_pred_buf;
    reg [1:0]  intra16_mode_mb;

    // Chroma MB-boundary neighbor storage for intra chroma prediction.
    // Top neighbors: bottom row of above MB's chroma, per MB column.
    reg [CHR_MB_WIDTH*BIT_DEPTH-1:0] top_chr_cb_nb [0:MB_COLS-1];
    reg [CHR_MB_WIDTH*BIT_DEPTH-1:0] top_chr_cr_nb [0:MB_COLS-1];
    // Left neighbors: right column of left MB's chroma.
    reg [CHR_MB_HEIGHT*BIT_DEPTH-1:0] left_chr_cb_nb;
    reg [CHR_MB_HEIGHT*BIT_DEPTH-1:0] left_chr_cr_nb;
    reg [15:0] frame_skip_mb_count;
    reg [15:0] frame_b_l1_mb_count;
    reg [15:0] frame_b_bi_mb_count;
    reg [15:0] frame_b_direct_mb_count;
    reg [15:0] frame_b_l0_nonzero_ref_mb_count;
    reg [15:0] frame_b_direct_nonzero_ref_mb_count;
    reg [15:0] frame_b_direct_from_l1_mb_count;
    reg [15:0] frame_cabac_p16x16_mb_count;

    // Reference-bank MB metadata for colocated/direct derivation.
    reg        refmeta_is_intra [0:4][0:TOTAL_MBS-1];
    reg        refmeta_has_l0   [0:4][0:TOTAL_MBS-1];
    reg        refmeta_has_l1   [0:4][0:TOTAL_MBS-1];
    reg [1:0]  refmeta_ref_idx_l0 [0:4][0:TOTAL_MBS-1];
    reg [1:0]  refmeta_ref_idx_l1 [0:4][0:TOTAL_MBS-1];
    reg signed [7:0] refmeta_mvx_l0 [0:4][0:TOTAL_MBS-1];
    reg signed [7:0] refmeta_mvy_l0 [0:4][0:TOTAL_MBS-1];
    reg signed [7:0] refmeta_mvx_l1 [0:4][0:TOTAL_MBS-1];
    reg signed [7:0] refmeta_mvy_l1 [0:4][0:TOTAL_MBS-1];
    reg [8:0]  refbank_poc_lsb [0:4];
    reg        refbank_has_l0_ref0 [0:4];
    reg [2:0]  refbank_l0_ref0_bank [0:4];
    reg        refbank_has_l0_ref1 [0:4];
    reg [2:0]  refbank_l0_ref1_bank [0:4];
    reg        refbank_has_l0_ref2 [0:4];
    reg [2:0]  refbank_l0_ref2_bank [0:4];
    reg        refbank_has_l1_ref0 [0:4];
    reg [2:0]  refbank_l1_ref0_bank [0:4];
    // Pre-computed chroma DC prediction values (one per 4x4 sub-block, per plane)
    reg [BIT_DEPTH-1:0] chr_dc_pred [0:CHR_BLOCKS_STORAGE-1];
    // Chroma residual override: when in chroma mode, bypass h264_intra_pred
    reg        chr_pred_mode;     // 1 = use chr_dc_pred instead of h264_intra_pred
    reg [16*(BIT_DEPTH+1)-1:0] chr_resid_4x4;   // chroma residual computed directly

    // Bitstream writer
    reg         bs_cmd_sps, bs_cmd_pps, bs_cmd_slice, bs_cmd_mb_hdr, bs_cmd_trailing, bs_cmd_flush, bs_cmd_clear_fifo;
    wire        bs_busy, bs_cmd_done;
    reg         mb_has_residual;
    reg         bs_hold_fifo_drain;
    reg         is_intra16_mb_hdr;
    reg         is_ipcm_mb_hdr;
    reg [5:0]   intra_mb_type_code_num;
    reg         pskip_syntax_eligible_reg;
    reg         bskip_syntax_eligible_reg;
    reg [1:0]   cabac_skip_ctx_reg;

    wire        cabac_feature_enable_w = (ENABLE_CABAC_PSKIP != 0) || (ENABLE_CABAC_P16X16 != 0);
    wire        cabac_p16x16_enable_w = (ENABLE_CABAC_P16X16 != 0);
    wire        cabac_slice_enable_w = cabac_feature_enable_w && is_p_frame;

    // CABAC P16x16 residual payload captured while the normal residual
    // pipeline walks the MB's 4x4 blocks.  h264_bitstream emits the deferred
    // CABAC macroblock header after residual processing, so it needs stable
    // whole-MB snapshots instead of the live zigzag block wires.
    reg [3:0]    cabac_cbp_luma_reg;
    reg [4095:0] cabac_luma_scan_flat_reg;
    reg [15:0]   cabac_luma_nz_mask_reg;
    reg [4095:0] cabac_chroma_scan_flat_reg;
    reg [15:0]   cabac_chroma_nz_mask_reg;

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
    function automatic [CHR_BLK_W-1:0] chroma_blk_idx_from_rc;
        input [1:0] blk_r;
        input [1:0] blk_c;
        integer idx_i;
        begin
            if (CHROMA_FORMAT_IDC == 3)
                idx_i = {blk_r[1], blk_c[1], blk_r[0], blk_c[0]};
            else
                idx_i = (blk_r * CHR_BLOCK_COLS) + blk_c;
            chroma_blk_idx_from_rc = idx_i[CHR_BLK_W-1:0];
        end
    endfunction

    function automatic [SUB_BLK_W-1:0] chroma_sub_blk_from_idx;
        input plane_is_cr;
        input [CHR_BLK_W-1:0] blk_idx;
        integer idx_i;
        begin
            idx_i = 16 + (plane_is_cr ? CHR_BLOCKS_PER_PLANE : 0) + blk_idx;
            chroma_sub_blk_from_idx = idx_i[SUB_BLK_W-1:0];
        end
    endfunction

    function automatic [3:0] cabac_chroma_payload_blk_idx;
        input plane_is_cr;
        input [CHR_BLK_W-1:0] blk_idx;
        integer idx_i;
        begin
            idx_i = (plane_is_cr ? CHR_BLOCKS_PER_PLANE : 0) + blk_idx;
            cabac_chroma_payload_blk_idx = idx_i[3:0];
        end
    endfunction

    function automatic [SUB_BLK_W-1:0] chroma_sub_blk_from_rc;
        input plane_is_cr;
        input [1:0] blk_r;
        input [1:0] blk_c;
        integer idx_i;
        begin
            if (CHROMA_FORMAT_IDC == 3)
                idx_i = 16 + (plane_is_cr ? CHR_BLOCKS_PER_PLANE : 0) + {blk_r[1], blk_c[1], blk_r[0], blk_c[0]};
            else
                idx_i = 16 + (plane_is_cr ? CHR_BLOCKS_PER_PLANE : 0) + (blk_r * CHR_BLOCK_COLS) + blk_c;
            chroma_sub_blk_from_rc = idx_i[SUB_BLK_W-1:0];
        end
    endfunction

    function automatic [1:0] chroma_blk_row_from_idx;
        input [CHR_BLK_W-1:0] blk_idx;
        integer idx_i;
        begin
            idx_i = blk_idx;
            if (CHROMA_FORMAT_IDC == 3)
                chroma_blk_row_from_idx = {idx_i[3], idx_i[1]};
            else
                chroma_blk_row_from_idx = idx_i / CHR_BLOCK_COLS;
        end
    endfunction

    function automatic [1:0] chroma_blk_col_from_idx;
        input [CHR_BLK_W-1:0] blk_idx;
        integer idx_i;
        begin
            idx_i = blk_idx;
            if (CHROMA_FORMAT_IDC == 3)
                chroma_blk_col_from_idx = {idx_i[2], idx_i[0]};
            else
                chroma_blk_col_from_idx = idx_i % CHR_BLOCK_COLS;
        end
    endfunction

    function automatic [SUB_BLK_W-1:0] luma_sub_blk_from_rc;
        input [1:0] blk_r;
        input [1:0] blk_c;
        begin
            luma_sub_blk_from_rc = {blk_r[1], blk_c[1], blk_r[0], blk_c[0]};
        end
    endfunction

    function automatic [19:0] cur_luma_addr_fn;
        input integer mbx_i;
        input integer mby_i;
        input integer row_i;
        input integer col_i;
        integer addr_i;
        begin
            addr_i = ((mby_i * 16) + row_i) * FRAME_WIDTH + ((mbx_i * 16) + col_i);
            cur_luma_addr_fn = addr_i[19:0];
        end
    endfunction

    function automatic [17:0] cur_chroma_addr_fn;
        input integer mbx_i;
        input integer mby_i;
        input integer row_i;
        input integer col_i;
        integer addr_i;
        begin
            addr_i = ((mby_i * CHR_MB_HEIGHT) + row_i) * CHR_WIDTH + ((mbx_i * CHR_MB_WIDTH) + col_i);
            cur_chroma_addr_fn = addr_i[17:0];
        end
    endfunction

    function automatic [2:0] deblock_first_fetch_phase_fn;
        input left_avail_i;
        input top_avail_i;
        begin
            if (left_avail_i)
                deblock_first_fetch_phase_fn = DBF_LEFT_LUMA;
            else if (top_avail_i)
                deblock_first_fetch_phase_fn = DBF_TOP_LUMA;
            else
                deblock_first_fetch_phase_fn = DBF_IDLE;
        end
    endfunction

    function automatic [2:0] deblock_next_fetch_phase_fn;
        input [2:0] phase_i;
        input left_avail_i;
        input top_avail_i;
        begin
            case (phase_i)
                DBF_LEFT_LUMA:   deblock_next_fetch_phase_fn = top_avail_i ? DBF_TOP_LUMA : DBF_LEFT_CHROMA;
                DBF_TOP_LUMA:    deblock_next_fetch_phase_fn = left_avail_i ? DBF_LEFT_CHROMA : DBF_TOP_CHROMA;
                DBF_LEFT_CHROMA: deblock_next_fetch_phase_fn = top_avail_i ? DBF_TOP_CHROMA : DBF_IDLE;
                default:         deblock_next_fetch_phase_fn = DBF_IDLE;
            endcase
        end
    endfunction

    function automatic [2:0] deblock_first_write_phase_fn;
        input left_avail_i;
        input top_avail_i;
        input deblock_active_i;
        begin
            if (!deblock_active_i)
                deblock_first_write_phase_fn = DBW_CUR_LUMA;
            else if (left_avail_i)
                deblock_first_write_phase_fn = DBW_LEFT_LUMA;
            else if (top_avail_i)
                deblock_first_write_phase_fn = DBW_TOP_LUMA;
            else
                deblock_first_write_phase_fn = DBW_CUR_LUMA;
        end
    endfunction

    function automatic [2:0] deblock_next_write_phase_fn;
        input [2:0] phase_i;
        input left_avail_i;
        input top_avail_i;
        begin
            case (phase_i)
                DBW_LEFT_LUMA:   deblock_next_write_phase_fn = top_avail_i ? DBW_TOP_LUMA : DBW_LEFT_CHROMA;
                DBW_TOP_LUMA:    deblock_next_write_phase_fn = left_avail_i ? DBW_LEFT_CHROMA : DBW_TOP_CHROMA;
                DBW_LEFT_CHROMA: deblock_next_write_phase_fn = top_avail_i ? DBW_TOP_CHROMA : DBW_CUR_LUMA;
                DBW_TOP_CHROMA:  deblock_next_write_phase_fn = DBW_CUR_LUMA;
                DBW_CUR_LUMA:    deblock_next_write_phase_fn = DBW_CUR_CHROMA;
                default:         deblock_next_write_phase_fn = DBW_CUR_CHROMA;
            endcase
        end
    endfunction

    wire is_luma = (sub_blk < 16);
    wire is_cb   = (sub_blk >= 16 && sub_blk < (16 + CHR_BLOCKS_PER_PLANE));
    wire is_cr   = (sub_blk >= (16 + CHR_BLOCKS_PER_PLANE));
    wire [CHR_BLK_W-1:0] chroma_sub_blk_idx_w = is_cr ? (sub_blk - (16 + CHR_BLOCKS_PER_PLANE)) :
                                                is_cb ? (sub_blk - 16) :
                                                {CHR_BLK_W{1'b0}};
    wire [1:0] chr_sb_r_w = chroma_blk_row_from_idx(chroma_sub_blk_idx_w);
    wire [1:0] chr_sb_c_w = chroma_blk_col_from_idx(chroma_sub_blk_idx_w);
    wire [1:0] sb_r = is_luma ? {sub_blk[3], sub_blk[1]} : chr_sb_r_w;
    wire [1:0] sb_c = is_luma ? {sub_blk[2], sub_blk[0]} : chr_sb_c_w;
    wire [1:0] chr_blk_row_w = chroma_blk_row_from_idx(chr_blk);
    wire [1:0] chr_blk_col_w = chroma_blk_col_from_idx(chr_blk);
    wire [1:0] chr_recon_blk_row_w = chroma_blk_row_from_idx(chr_recon_blk);
    wire [1:0] chr_recon_blk_col_w = chroma_blk_col_from_idx(chr_recon_blk);
    wire force_intra_pred_mode_w = (CHROMA_FORMAT_IDC == 3) &&
                                   (top_state == TS_CHROMA) &&
                                   !inter_chr_mode &&
                                   (is_cb || is_cr);
    wire [3:0] chr_blk_idx4_w = chr_blk;
    wire [3:0] forced_intra_pred_mode_w = intra_mode_cur[chr_blk_idx4_w];

    localparam BD = BIT_DEPTH;
    localparam BD1 = BIT_DEPTH + 1;
    localparam CW  = BIT_DEPTH + 8; // coefficient width for transform/quant pipeline
    localparam CW8 = BIT_DEPTH + 14; // coefficient width for 8x8 transform pipeline
    wire use_weighted_pred_w = WEIGHTED_PRED_ENABLE && (is_p_frame || is_b_frame);
    wire use_post_weighted_pred_w = use_weighted_pred_w && !(is_b_frame && is_b_bi_mb_reg);
    wire b_multi_ref_l0_enable_w = !weighted_pred_enable_cfg_w;
    wire [1:0] b_slice_num_ref_idx_l0_active_minus1_w =
        b_multi_ref_l0_enable_w ?
            ((valid_ref_count >= 3'd4) ? 2'd2 :
             (valid_ref_count >= 3'd3) ? 2'd1 : 2'd0) :
            2'd0;
    wire [2:0] b_l0_ref_bank_w =
        (is_b_frame && (valid_ref_count >= 3'd2)) ? older_ref_bank : newest_ref_bank;
    wire [1:0] b_l1_search_pass_w =
        b_multi_ref_l0_enable_w ?
            ((valid_ref_count >= 3'd4) ? 2'd3 :
             (valid_ref_count >= 3'd3) ? 2'd2 : 2'd1) :
            2'd1;
    reg        direct_temporal_slice_mode_reg;
    wire direct_spatial_mv_pred_flag_w = ~direct_temporal_slice_mode_reg;
    wire weighted_pred_enable_cfg_w = (WEIGHTED_PRED_ENABLE != 0);
    wire [3:0] luma_log2_weight_denom_cfg_w = LUMA_LOG2_WEIGHT_DENOM[3:0];
    wire signed [8:0] luma_weight_cfg_w = LUMA_WEIGHT[8:0];
    wire signed [8:0] luma_offset_cfg_w = LUMA_OFFSET[8:0];
    wire [3:0] chroma_log2_weight_denom_cfg_w = CHROMA_LOG2_WEIGHT_DENOM[3:0];
    wire signed [8:0] chroma_weight_cb_cfg_w = CHROMA_WEIGHT_CB[8:0];
    wire signed [8:0] chroma_offset_cb_cfg_w = CHROMA_OFFSET_CB[8:0];
    wire signed [8:0] chroma_weight_cr_cfg_w = CHROMA_WEIGHT_CR[8:0];
    wire signed [8:0] chroma_offset_cr_cfg_w = CHROMA_OFFSET_CR[8:0];

    function [BD-1:0] clip_weighted_sample;
        input integer sample_in;
        integer max_sample;
        begin
            max_sample = (1 << BD) - 1;
            if (sample_in < 0)
                clip_weighted_sample = {BD{1'b0}};
            else if (sample_in > max_sample)
                clip_weighted_sample = max_sample[BD-1:0];
            else
                clip_weighted_sample = sample_in[BD-1:0];
        end
    endfunction

    function [BD-1:0] apply_luma_weight;
        input [BD-1:0] sample_in;
        integer weighted_sample;
        integer round_val;
        begin
            round_val = (LUMA_LOG2_WEIGHT_DENOM > 0) ? (1 << (LUMA_LOG2_WEIGHT_DENOM - 1)) : 0;
            weighted_sample = (LUMA_WEIGHT * sample_in) + round_val + (LUMA_OFFSET << LUMA_LOG2_WEIGHT_DENOM);
            weighted_sample = weighted_sample >>> LUMA_LOG2_WEIGHT_DENOM;
            apply_luma_weight = clip_weighted_sample(weighted_sample);
        end
    endfunction

    function [BD-1:0] apply_chroma_cb_weight;
        input [BD-1:0] sample_in;
        integer weighted_sample;
        integer round_val;
        begin
            round_val = (CHROMA_LOG2_WEIGHT_DENOM > 0) ? (1 << (CHROMA_LOG2_WEIGHT_DENOM - 1)) : 0;
            weighted_sample = (CHROMA_WEIGHT_CB * sample_in) + round_val + (CHROMA_OFFSET_CB << CHROMA_LOG2_WEIGHT_DENOM);
            weighted_sample = weighted_sample >>> CHROMA_LOG2_WEIGHT_DENOM;
            apply_chroma_cb_weight = clip_weighted_sample(weighted_sample);
        end
    endfunction

    function [BD-1:0] apply_chroma_cr_weight;
        input [BD-1:0] sample_in;
        integer weighted_sample;
        integer round_val;
        begin
            round_val = (CHROMA_LOG2_WEIGHT_DENOM > 0) ? (1 << (CHROMA_LOG2_WEIGHT_DENOM - 1)) : 0;
            weighted_sample = (CHROMA_WEIGHT_CR * sample_in) + round_val + (CHROMA_OFFSET_CR << CHROMA_LOG2_WEIGHT_DENOM);
            weighted_sample = weighted_sample >>> CHROMA_LOG2_WEIGHT_DENOM;
            apply_chroma_cr_weight = clip_weighted_sample(weighted_sample);
        end
    endfunction

    function automatic [6:0] cap_abs_mvd;
        input signed [8:0] mvd_in;
        reg [8:0] abs_i;
        begin
            abs_i = mvd_in[8] ? (~mvd_in + 9'd1) : mvd_in;
            if (abs_i > 9'd66)
                cap_abs_mvd = 7'd66;
            else
                cap_abs_mvd = abs_i[6:0];
        end
    endfunction

    function automatic [1:0] cabac_mvd_ctx_class;
        input [6:0] left_abs_i;
        input [6:0] top_abs_i;
        integer sum_i;
        begin
            sum_i = left_abs_i + top_abs_i;
            cabac_mvd_ctx_class = {1'b0, (sum_i > 2)} + {1'b0, (sum_i > 32)};
        end
    endfunction

    wire [6:0] cabac_left_mvd_abs_x_w = mb_left_avail ? left_mvd_abs_x : 7'd0;
    wire [6:0] cabac_left_mvd_abs_y_w = mb_left_avail ? left_mvd_abs_y : 7'd0;
    wire [6:0] cabac_top_mvd_abs_x_w = mb_top_avail ? top_mvd_abs_x[mb_x] : 7'd0;
    wire [6:0] cabac_top_mvd_abs_y_w = mb_top_avail ? top_mvd_abs_y[mb_x] : 7'd0;
    wire [1:0] cabac_mvd_ctx_x_w = cabac_mvd_ctx_class(cabac_left_mvd_abs_x_w, cabac_top_mvd_abs_x_w);
    wire [1:0] cabac_mvd_ctx_y_w = cabac_mvd_ctx_class(cabac_left_mvd_abs_y_w, cabac_top_mvd_abs_y_w);
    wire [1:0] cabac_cbp_luma_ctx0_sel_w = {!mb_top_avail, !mb_left_avail};
    wire [1:0] cabac_cbp_luma_ctx1_sel_w = {!mb_top_avail, 1'b0};
    wire [1:0] cabac_cbp_luma_ctx2_sel_w = {1'b0, !mb_left_avail};
    wire        cabac_p16x16_supported_w =
        cabac_p16x16_enable_w &&
        is_p_frame &&
        is_inter_mb_reg &&
        !use_weighted_pred_w &&
        (slice_num_ref_idx_l0_active_minus1 == 2'd0) &&
        (mb_ref_idx_reg == 2'd0) &&
        (mvd_x_l0_w == 9'sd0) &&
        (mvd_y_l0_w == 9'sd0);
    wire        cabac_luma_residual_payload_ready_w =
        (cabac_cbp_luma_reg != 4'd0) &&
        (cabac_luma_nz_mask_reg != 16'd0);
    wire        cabac_non_skip_subset_ok_w =
        cabac_p16x16_supported_w &&
        !is_skip_mb_reg &&
        (!mb_has_residual || cabac_luma_residual_payload_ready_w);

    function [BD-1:0] apply_luma_bi_weight;
        input [BD-1:0] sample0_in;
        input [BD-1:0] sample1_in;
        integer weighted_sample;
        integer round_val;
        begin
            round_val = 1 << LUMA_LOG2_WEIGHT_DENOM;
            weighted_sample = (LUMA_WEIGHT * sample0_in) + (LUMA_WEIGHT * sample1_in)
                            + round_val + (LUMA_OFFSET << (LUMA_LOG2_WEIGHT_DENOM + 1));
            weighted_sample = weighted_sample >>> (LUMA_LOG2_WEIGHT_DENOM + 1);
            apply_luma_bi_weight = clip_weighted_sample(weighted_sample);
        end
    endfunction

    function [BD-1:0] apply_chroma_cb_bi_weight;
        input [BD-1:0] sample0_in;
        input [BD-1:0] sample1_in;
        integer weighted_sample;
        integer round_val;
        begin
            round_val = 1 << CHROMA_LOG2_WEIGHT_DENOM;
            weighted_sample = (CHROMA_WEIGHT_CB * sample0_in) + (CHROMA_WEIGHT_CB * sample1_in)
                            + round_val + (CHROMA_OFFSET_CB << (CHROMA_LOG2_WEIGHT_DENOM + 1));
            weighted_sample = weighted_sample >>> (CHROMA_LOG2_WEIGHT_DENOM + 1);
            apply_chroma_cb_bi_weight = clip_weighted_sample(weighted_sample);
        end
    endfunction

    function [BD-1:0] apply_chroma_cr_bi_weight;
        input [BD-1:0] sample0_in;
        input [BD-1:0] sample1_in;
        integer weighted_sample;
        integer round_val;
        begin
            round_val = 1 << CHROMA_LOG2_WEIGHT_DENOM;
            weighted_sample = (CHROMA_WEIGHT_CR * sample0_in) + (CHROMA_WEIGHT_CR * sample1_in)
                            + round_val + (CHROMA_OFFSET_CR << (CHROMA_LOG2_WEIGHT_DENOM + 1));
            weighted_sample = weighted_sample >>> (CHROMA_LOG2_WEIGHT_DENOM + 1);
            apply_chroma_cr_bi_weight = clip_weighted_sample(weighted_sample);
        end
    endfunction

    function [2:0] pick_free_ref_bank;
        input [2:0] latest_bank;
        input [2:0] older_bank;
        input [2:0] oldest_bank;
        input [2:0] ancient_bank;
        begin
            if (latest_bank != 3'd0 && older_bank != 3'd0 && oldest_bank != 3'd0 && ancient_bank != 3'd0)
                pick_free_ref_bank = 3'd0;
            else if (latest_bank != 3'd1 && older_bank != 3'd1 && oldest_bank != 3'd1 && ancient_bank != 3'd1)
                pick_free_ref_bank = 3'd1;
            else if (latest_bank != 3'd2 && older_bank != 3'd2 && oldest_bank != 3'd2 && ancient_bank != 3'd2)
                pick_free_ref_bank = 3'd2;
            else if (latest_bank != 3'd3 && older_bank != 3'd3 && oldest_bank != 3'd3 && ancient_bank != 3'd3)
                pick_free_ref_bank = 3'd3;
            else
                pick_free_ref_bank = 3'd4;
        end
    endfunction

    function automatic [2:0] b_l0_ref_bank_from_idx;
        input [1:0] ref_idx_in;
        begin
            case (ref_idx_in)
                2'd0: b_l0_ref_bank_from_idx = older_ref_bank;
                2'd1: b_l0_ref_bank_from_idx = oldest_ref_bank;
                2'd2: b_l0_ref_bank_from_idx = ancient_ref_bank;
                default: b_l0_ref_bank_from_idx = older_ref_bank;
            endcase
        end
    endfunction

    function automatic direct_temporal_slice_mode_next;
        input is_b_slice_in;
        input is_idr_slice_in;
        input [8:0] pic_order_cnt_lsb_in_f;
        begin
            direct_temporal_slice_mode_next =
                ~is_idr_slice_in &&
                is_b_slice_in &&
                (force_b_direct_temporal_in ||
                 ((valid_ref_count >= 3'd2) &&
                  refbank_has_l0_ref0[newest_ref_bank] &&
                  ((refbank_l0_ref0_bank[newest_ref_bank] == older_ref_bank) ||
                   ((valid_ref_count >= 3'd3) && (refbank_l0_ref0_bank[newest_ref_bank] == oldest_ref_bank)) ||
                   ((valid_ref_count >= 3'd4) && (refbank_l0_ref0_bank[newest_ref_bank] == ancient_ref_bank))) &&
                  (refbank_poc_lsb[newest_ref_bank] != pic_order_cnt_lsb_in_f)));
        end
    endfunction

    task automatic map_refbank_l0_ref_bank;
        input [2:0] picture_bank_in;
        input [1:0] ref_idx_in;
        output      ref_valid_out;
        output [2:0] ref_bank_out;
        begin
            ref_valid_out = 1'b0;
            ref_bank_out = 3'd0;
            case (ref_idx_in)
                2'd0: begin
                    ref_valid_out = refbank_has_l0_ref0[picture_bank_in];
                    ref_bank_out = refbank_l0_ref0_bank[picture_bank_in];
                end
                2'd1: begin
                    ref_valid_out = refbank_has_l0_ref1[picture_bank_in];
                    ref_bank_out = refbank_l0_ref1_bank[picture_bank_in];
                end
                2'd2: begin
                    ref_valid_out = refbank_has_l0_ref2[picture_bank_in];
                    ref_bank_out = refbank_l0_ref2_bank[picture_bank_in];
                end
                default: begin
                    ref_valid_out = 1'b0;
                    ref_bank_out = 3'd0;
                end
            endcase
        end
    endtask

    task automatic map_refbank_l1_ref_bank;
        input [2:0] picture_bank_in;
        input [1:0] ref_idx_in;
        output      ref_valid_out;
        output [2:0] ref_bank_out;
        begin
            ref_valid_out = 1'b0;
            ref_bank_out = 3'd0;
            case (ref_idx_in)
                2'd0: begin
                    ref_valid_out = refbank_has_l1_ref0[picture_bank_in];
                    ref_bank_out = refbank_l1_ref0_bank[picture_bank_in];
                end
                default: begin
                    ref_valid_out = 1'b0;
                    ref_bank_out = 3'd0;
                end
            endcase
        end
    endtask

    task automatic map_b_l0_bank_to_ref_idx;
        input [2:0] ref_bank_in;
        output      ref_valid_out;
        output [1:0] ref_idx_out;
        begin
            ref_valid_out = 1'b0;
            ref_idx_out = 2'd0;
            if ((valid_ref_count >= 3'd2) && (ref_bank_in == older_ref_bank)) begin
                ref_valid_out = 1'b1;
                ref_idx_out = 2'd0;
            end else if ((valid_ref_count >= 3'd3) && (ref_bank_in == oldest_ref_bank)) begin
                ref_valid_out = 1'b1;
                ref_idx_out = 2'd1;
            end else if ((valid_ref_count >= 3'd4) && (ref_bank_in == ancient_ref_bank)) begin
                ref_valid_out = 1'b1;
                ref_idx_out = 2'd2;
            end
        end
    endtask

    task automatic calc_inter_mvp;
        input        use_l1;
        input [1:0]  ref_idx_in;
        output signed [7:0] pred_x;
        output signed [7:0] pred_y;
        reg signed [7:0] ax, ay, bx, by, cx, cy;
        reg signed [7:0] med_x, med_y;
        reg a_avail, b_avail, c_avail, d_avail;
        reg a_match, b_match, c_match;
        reg [1:0] match_cnt;
        begin
            a_avail = (mb_x > 7'd0);
            b_avail = (mb_y > 6'd0);
            c_avail = (mb_y > 6'd0) && (mb_x < MB_COLS[6:0] - 7'd1);
            d_avail = (mb_y > 6'd0) && (mb_x > 7'd0);

            if (use_l1) begin
                ax = a_avail ? left_mvx_l1 : 8'sd0;
                ay = a_avail ? left_mvy_l1 : 8'sd0;
                a_match = a_avail && left_is_inter_l1 && (left_ref_idx_l1 == ref_idx_in);
                bx = b_avail ? top_mvx_l1[mb_x] : 8'sd0;
                by = b_avail ? top_mvy_l1[mb_x] : 8'sd0;
                b_match = b_avail && top_is_inter_l1[mb_x] && (top_ref_idx_l1[mb_x] == ref_idx_in);
                if (c_avail) begin
                    cx = top_mvx_l1[mb_x + 7'd1];
                    cy = top_mvy_l1[mb_x + 7'd1];
                    c_match = top_is_inter_l1[mb_x + 7'd1] && (top_ref_idx_l1[mb_x + 7'd1] == ref_idx_in);
                end else if (d_avail) begin
                    cx = diag_mvx_l1;
                    cy = diag_mvy_l1;
                    c_match = diag_is_inter_l1 && (diag_ref_idx_l1 == ref_idx_in);
                end else begin
                    cx = 8'sd0;
                    cy = 8'sd0;
                    c_match = 1'b0;
                end
            end else begin
                ax = a_avail ? left_mvx : 8'sd0;
                ay = a_avail ? left_mvy : 8'sd0;
                a_match = a_avail && left_is_inter && (left_ref_idx == ref_idx_in);
                bx = b_avail ? top_mvx[mb_x] : 8'sd0;
                by = b_avail ? top_mvy[mb_x] : 8'sd0;
                b_match = b_avail && top_is_inter[mb_x] && (top_ref_idx[mb_x] == ref_idx_in);
                if (c_avail) begin
                    cx = top_mvx[mb_x + 7'd1];
                    cy = top_mvy[mb_x + 7'd1];
                    c_match = top_is_inter[mb_x + 7'd1] && (top_ref_idx[mb_x + 7'd1] == ref_idx_in);
                end else if (d_avail) begin
                    cx = diag_mvx;
                    cy = diag_mvy;
                    c_match = diag_is_inter && (diag_ref_idx == ref_idx_in);
                end else begin
                    cx = 8'sd0;
                    cy = 8'sd0;
                    c_match = 1'b0;
                end
            end

            if (!b_avail && !c_avail && !d_avail) begin
                bx = ax; by = ay; b_match = a_match;
                cx = ax; cy = ay; c_match = a_match;
            end

            match_cnt = {1'b0, a_match} + {1'b0, b_match} + {1'b0, c_match};
            med_x = (ax > bx && ax > cx) ? ((bx > cx) ? bx : cx) :
                    (ax < bx && ax < cx) ? ((bx < cx) ? bx : cx) : ax;
            med_y = (ay > by && ay > cy) ? ((by > cy) ? by : cy) :
                    (ay < by && ay < cy) ? ((by < cy) ? by : cy) : ay;

            if (match_cnt == 2'd1) begin
                if (a_match) begin
                    pred_x = ax;
                    pred_y = ay;
                end else if (b_match) begin
                    pred_x = bx;
                    pred_y = by;
                end else begin
                    pred_x = cx;
                    pred_y = cy;
                end
            end else begin
                pred_x = med_x;
                pred_y = med_y;
            end
        end
    endtask

    task automatic calc_direct_list_candidate;
        input        use_l1;
        output       has_list;
        output [1:0] ref_idx_out;
        output signed [7:0] mvx_out;
        output signed [7:0] mvy_out;
        reg a_avail, b_avail, c_avail, d_avail;
        reg a_valid, b_valid, c_valid;
        reg [1:0] ref_a, ref_b, ref_c;
        reg [1:0] min_ref;
        begin
            a_avail = (mb_x > 7'd0);
            b_avail = (mb_y > 6'd0);
            c_avail = (mb_y > 6'd0) && (mb_x < MB_COLS[6:0] - 7'd1);
            d_avail = (mb_y > 6'd0) && (mb_x > 7'd0);

            if (use_l1) begin
                a_valid = a_avail && left_is_inter_l1;
                b_valid = b_avail && top_is_inter_l1[mb_x];
                if (c_avail) begin
                    c_valid = top_is_inter_l1[mb_x + 7'd1];
                    ref_c = top_ref_idx_l1[mb_x + 7'd1];
                end else if (d_avail) begin
                    c_valid = diag_is_inter_l1;
                    ref_c = diag_ref_idx_l1;
                end else begin
                    c_valid = 1'b0;
                    ref_c = 2'd0;
                end
                ref_a = left_ref_idx_l1;
                ref_b = top_ref_idx_l1[mb_x];
            end else begin
                a_valid = a_avail && left_is_inter;
                b_valid = b_avail && top_is_inter[mb_x];
                if (c_avail) begin
                    c_valid = top_is_inter[mb_x + 7'd1];
                    ref_c = top_ref_idx[mb_x + 7'd1];
                end else if (d_avail) begin
                    c_valid = diag_is_inter;
                    ref_c = diag_ref_idx;
                end else begin
                    c_valid = 1'b0;
                    ref_c = 2'd0;
                end
                ref_a = left_ref_idx;
                ref_b = top_ref_idx[mb_x];
            end

            if (!a_valid && !b_valid && !c_valid) begin
                has_list = 1'b0;
                ref_idx_out = 2'd0;
                mvx_out = 8'sd0;
                mvy_out = 8'sd0;
            end else begin
                has_list = 1'b1;
                min_ref = a_valid ? ref_a : (b_valid ? ref_b : ref_c);
                if (b_valid && (ref_b < min_ref))
                    min_ref = ref_b;
                if (c_valid && (ref_c < min_ref))
                    min_ref = ref_c;
                ref_idx_out = min_ref;
                calc_inter_mvp(use_l1, min_ref, mvx_out, mvy_out);
            end
        end
    endtask

    task automatic calc_b_direct16x16;
        output       direct_use_l1;
        output       direct_use_bi;
        output [1:0] direct_ref_idx_l0;
        output [1:0] direct_ref_idx_l1;
        output signed [7:0] direct_mvx_l0;
        output signed [7:0] direct_mvy_l0;
        output signed [7:0] direct_mvx_l1;
        output signed [7:0] direct_mvy_l1;
        reg has_l0, has_l1;
        reg col_is_intra, col_has_l0, col_has_l1, col_zero_flag;
        reg [1:0] col_ref_idx_l0, col_ref_idx_l1;
        reg signed [7:0] col_mvx_l0, col_mvy_l0, col_mvx_l1, col_mvy_l1;
        begin
            calc_direct_list_candidate(1'b0, has_l0, direct_ref_idx_l0, direct_mvx_l0, direct_mvy_l0);
            calc_direct_list_candidate(1'b1, has_l1, direct_ref_idx_l1, direct_mvx_l1, direct_mvy_l1);

            if (!has_l0 && !has_l1) begin
                has_l0 = 1'b1;
                has_l1 = 1'b1;
                direct_ref_idx_l0 = 2'd0;
                direct_ref_idx_l1 = 2'd0;
                direct_mvx_l0 = 8'sd0;
                direct_mvy_l0 = 8'sd0;
                direct_mvx_l1 = 8'sd0;
                direct_mvy_l1 = 8'sd0;
            end

            col_is_intra = refmeta_is_intra[newest_ref_bank][mb_count];
            col_has_l0   = refmeta_has_l0[newest_ref_bank][mb_count];
            col_has_l1   = refmeta_has_l1[newest_ref_bank][mb_count];
            col_ref_idx_l0 = refmeta_ref_idx_l0[newest_ref_bank][mb_count];
            col_ref_idx_l1 = refmeta_ref_idx_l1[newest_ref_bank][mb_count];
            col_mvx_l0 = refmeta_mvx_l0[newest_ref_bank][mb_count];
            col_mvy_l0 = refmeta_mvy_l0[newest_ref_bank][mb_count];
            col_mvx_l1 = refmeta_mvx_l1[newest_ref_bank][mb_count];
            col_mvy_l1 = refmeta_mvy_l1[newest_ref_bank][mb_count];

            if (!col_is_intra &&
                !((direct_mvx_l0 == 8'sd0) && (direct_mvy_l0 == 8'sd0) &&
                  (direct_mvx_l1 == 8'sd0) && (direct_mvy_l1 == 8'sd0)) &&
                !((has_l0 && (direct_ref_idx_l0 != 2'd0)) &&
                  (has_l1 && (direct_ref_idx_l1 != 2'd0)))) begin
                col_zero_flag = 1'b0;
                if (col_has_l0 && (col_ref_idx_l0 == 2'd0) &&
                    ($signed(col_mvx_l0) >= -8'sd1) && ($signed(col_mvx_l0) <= 8'sd1) &&
                    ($signed(col_mvy_l0) >= -8'sd1) && ($signed(col_mvy_l0) <= 8'sd1))
                    col_zero_flag = 1'b1;
                else if (!col_has_l0 && col_has_l1 && (col_ref_idx_l1 == 2'd0) &&
                         ($signed(col_mvx_l1) >= -8'sd1) && ($signed(col_mvx_l1) <= 8'sd1) &&
                         ($signed(col_mvy_l1) >= -8'sd1) && ($signed(col_mvy_l1) <= 8'sd1))
                    col_zero_flag = 1'b1;

                if (col_zero_flag) begin
                    if (has_l0 && (direct_ref_idx_l0 == 2'd0)) begin
                        direct_mvx_l0 = 8'sd0;
                        direct_mvy_l0 = 8'sd0;
                    end
                    if (has_l1 && (direct_ref_idx_l1 == 2'd0)) begin
                        direct_mvx_l1 = 8'sd0;
                        direct_mvy_l1 = 8'sd0;
                    end
                end
            end

            direct_use_bi = has_l0 && has_l1;
            direct_use_l1 = !has_l0 && has_l1;
        end
    endtask

    function integer clip_temporal_delta;
        input integer delta_in;
        begin
            if (delta_in < -128)
                clip_temporal_delta = -128;
            else if (delta_in > 127)
                clip_temporal_delta = 127;
            else
                clip_temporal_delta = delta_in;
        end
    endfunction

    function signed [7:0] clip_mv_qpel8;
        input integer mv_in;
        begin
            if (mv_in < -128)
                clip_mv_qpel8 = -128;
            else if (mv_in > 127)
                clip_mv_qpel8 = 127;
            else
                clip_mv_qpel8 = mv_in;
        end
    endfunction

    task automatic calc_temporal_direct_candidate_from_colocated;
        input        col_has_ref_in;
        input        col_ref_bank_valid_in;
        input [2:0]  col_ref_bank_in;
        input        cur_ref_idx_valid_in;
        input [1:0]  cur_ref_idx_l0_in;
        input signed [7:0] col_mvx_in;
        input signed [7:0] col_mvy_in;
        output       cand_valid_out;
        output [1:0] cand_ref_idx_l0_out;
        output [1:0] cand_ref_idx_l1_out;
        output signed [7:0] cand_mvx_l0_out;
        output signed [7:0] cand_mvy_l0_out;
        output signed [7:0] cand_mvx_l1_out;
        output signed [7:0] cand_mvy_l1_out;
        output integer cand_metric_out;
        integer poc0_i, poc1_i, cur_poc_i;
        integer td_i, tb_i, tx_i, dist_scale_i;
        integer mv_col_x_i, mv_col_y_i;
        integer mv_l0_x_i, mv_l0_y_i;
        integer mv_l1_x_i, mv_l1_y_i;
        begin
            cand_valid_out = 1'b0;
            cand_ref_idx_l0_out = 2'd0;
            cand_ref_idx_l1_out = 2'd0;
            cand_mvx_l0_out = 8'sd0;
            cand_mvy_l0_out = 8'sd0;
            cand_mvx_l1_out = 8'sd0;
            cand_mvy_l1_out = 8'sd0;
            cand_metric_out = 32'h7fffffff;

            if (col_has_ref_in && col_ref_bank_valid_in && cur_ref_idx_valid_in) begin
                cand_ref_idx_l0_out = cur_ref_idx_l0_in;
                poc0_i = refbank_poc_lsb[col_ref_bank_in];
                poc1_i = refbank_poc_lsb[newest_ref_bank];
                cur_poc_i = cur_pic_order_cnt_lsb;
                td_i = clip_temporal_delta(poc1_i - poc0_i);
                mv_col_x_i = $signed(col_mvx_in);
                mv_col_y_i = $signed(col_mvy_in);

                if (td_i == 0) begin
                    dist_scale_i = 256;
                end else begin
                    tb_i = clip_temporal_delta(cur_poc_i - poc0_i);
                    tx_i = (16384 + ((td_i < 0 ? -td_i : td_i) >> 1)) / td_i;
                    dist_scale_i = (tb_i * tx_i + 32) >>> 6;
                    if (dist_scale_i < -1024)
                        dist_scale_i = -1024;
                    else if (dist_scale_i > 1023)
                        dist_scale_i = 1023;
                end

                mv_l0_x_i = (dist_scale_i * mv_col_x_i + 128) >>> 8;
                mv_l0_y_i = (dist_scale_i * mv_col_y_i + 128) >>> 8;
                mv_l1_x_i = mv_l0_x_i - mv_col_x_i;
                mv_l1_y_i = mv_l0_y_i - mv_col_y_i;

                cand_valid_out = 1'b1;
                cand_mvx_l0_out = clip_mv_qpel8(mv_l0_x_i);
                cand_mvy_l0_out = clip_mv_qpel8(mv_l0_y_i);
                cand_mvx_l1_out = clip_mv_qpel8(mv_l1_x_i);
                cand_mvy_l1_out = clip_mv_qpel8(mv_l1_y_i);
                cand_metric_out =
                    ((mv_l0_x_i < 0) ? -mv_l0_x_i : mv_l0_x_i) +
                    ((mv_l0_y_i < 0) ? -mv_l0_y_i : mv_l0_y_i) +
                    ((mv_l1_x_i < 0) ? -mv_l1_x_i : mv_l1_x_i) +
                    ((mv_l1_y_i < 0) ? -mv_l1_y_i : mv_l1_y_i);
            end
        end
    endtask

    task automatic calc_b_direct16x16_temporal;
        output       direct_valid;
        output       direct_use_l1;
        output       direct_use_bi;
        output       direct_from_col_l1;
        output [1:0] direct_ref_idx_l0;
        output [1:0] direct_ref_idx_l1;
        output signed [7:0] direct_mvx_l0;
        output signed [7:0] direct_mvy_l0;
        output signed [7:0] direct_mvx_l1;
        output signed [7:0] direct_mvy_l1;
        reg col_is_intra, col_has_l0, col_has_l1;
        reg [1:0] col_ref_idx_l0, col_ref_idx_l1;
        reg       col_ref_bank_l0_valid, col_ref_bank_l1_valid;
        reg       cur_ref_idx_l0_valid, cur_ref_idx_l1_valid;
        reg [2:0] col_ref_bank_l0;
        reg [2:0] col_ref_bank_l1;
        reg [1:0] cur_ref_idx_l0_from_l0;
        reg [1:0] cur_ref_idx_l0_from_l1;
        reg signed [7:0] col_mvx_l0, col_mvy_l0, col_mvx_l1, col_mvy_l1;
        reg cand_l0_valid, cand_l1_valid;
        reg [1:0] cand_l0_ref_idx_l0, cand_l1_ref_idx_l0;
        reg [1:0] cand_l0_ref_idx_l1, cand_l1_ref_idx_l1;
        reg signed [7:0] cand_l0_mvx_l0, cand_l0_mvy_l0, cand_l0_mvx_l1, cand_l0_mvy_l1;
        reg signed [7:0] cand_l1_mvx_l0, cand_l1_mvy_l0, cand_l1_mvx_l1, cand_l1_mvy_l1;
        integer cand_l0_metric_i, cand_l1_metric_i;
        begin
            direct_valid = 1'b0;
            direct_use_l1 = 1'b0;
            direct_use_bi = 1'b0;
            direct_from_col_l1 = 1'b0;
            direct_ref_idx_l0 = 2'd0;
            direct_ref_idx_l1 = 2'd0;
            direct_mvx_l0 = 8'sd0;
            direct_mvy_l0 = 8'sd0;
            direct_mvx_l1 = 8'sd0;
            direct_mvy_l1 = 8'sd0;
            col_ref_bank_l0_valid = 1'b0;
            col_ref_bank_l1_valid = 1'b0;
            cur_ref_idx_l0_valid = 1'b0;
            cur_ref_idx_l1_valid = 1'b0;
            col_ref_bank_l0 = 3'd0;
            col_ref_bank_l1 = 3'd0;
            cur_ref_idx_l0_from_l0 = 2'd0;
            cur_ref_idx_l0_from_l1 = 2'd0;
            cand_l0_valid = 1'b0;
            cand_l1_valid = 1'b0;

            if (valid_ref_count >= 3'd2) begin
                col_is_intra = refmeta_is_intra[newest_ref_bank][mb_count];
                col_has_l0 = refmeta_has_l0[newest_ref_bank][mb_count];
                col_has_l1 = refmeta_has_l1[newest_ref_bank][mb_count];
                col_ref_idx_l0 = refmeta_ref_idx_l0[newest_ref_bank][mb_count];
                col_ref_idx_l1 = refmeta_ref_idx_l1[newest_ref_bank][mb_count];
                col_mvx_l0 = refmeta_mvx_l0[newest_ref_bank][mb_count];
                col_mvy_l0 = refmeta_mvy_l0[newest_ref_bank][mb_count];
                col_mvx_l1 = refmeta_mvx_l1[newest_ref_bank][mb_count];
                col_mvy_l1 = refmeta_mvy_l1[newest_ref_bank][mb_count];
                map_refbank_l0_ref_bank(newest_ref_bank, col_ref_idx_l0, col_ref_bank_l0_valid, col_ref_bank_l0);
                map_b_l0_bank_to_ref_idx(col_ref_bank_l0, cur_ref_idx_l0_valid, cur_ref_idx_l0_from_l0);
                map_refbank_l1_ref_bank(newest_ref_bank, col_ref_idx_l1, col_ref_bank_l1_valid, col_ref_bank_l1);
                map_b_l0_bank_to_ref_idx(col_ref_bank_l1, cur_ref_idx_l1_valid, cur_ref_idx_l0_from_l1);

                // In reordered BREF chains the colocated picture can point at a
                // reference bank that aged out of the current B-slice List0.
                // Keep temporal-direct available by remapping that colocated
                // reference to the deepest current List0 slot instead of
                // dropping the B_DIRECT candidate and falling back to L1.
                if (col_ref_bank_l0_valid && !cur_ref_idx_l0_valid && (valid_ref_count >= 3'd3)) begin
                    cur_ref_idx_l0_valid = 1'b1;
                    cur_ref_idx_l0_from_l0 = (valid_ref_count >= 3'd4) ? 2'd2 : 2'd1;
                end
                if (col_ref_bank_l1_valid && !cur_ref_idx_l1_valid && (valid_ref_count >= 3'd3)) begin
                    cur_ref_idx_l1_valid = 1'b1;
                    cur_ref_idx_l0_from_l1 = (valid_ref_count >= 3'd4) ? 2'd2 : 2'd1;
                end

                calc_temporal_direct_candidate_from_colocated(
                    col_has_l0,
                    col_ref_bank_l0_valid,
                    col_ref_bank_l0,
                    cur_ref_idx_l0_valid,
                    cur_ref_idx_l0_from_l0,
                    col_mvx_l0,
                    col_mvy_l0,
                    cand_l0_valid,
                    cand_l0_ref_idx_l0,
                    cand_l0_ref_idx_l1,
                    cand_l0_mvx_l0,
                    cand_l0_mvy_l0,
                    cand_l0_mvx_l1,
                    cand_l0_mvy_l1,
                    cand_l0_metric_i
                );
                // Reordered BREF colocated BI blocks can carry the usable past
                // mapping in their stored List1 reference instead of List0.
                calc_temporal_direct_candidate_from_colocated(
                    col_has_l1,
                    col_ref_bank_l1_valid,
                    col_ref_bank_l1,
                    cur_ref_idx_l1_valid,
                    cur_ref_idx_l0_from_l1,
                    col_mvx_l1,
                    col_mvy_l1,
                    cand_l1_valid,
                    cand_l1_ref_idx_l0,
                    cand_l1_ref_idx_l1,
                    cand_l1_mvx_l0,
                    cand_l1_mvy_l0,
                    cand_l1_mvx_l1,
                    cand_l1_mvy_l1,
                    cand_l1_metric_i
                );

                if (col_is_intra) begin
                    direct_valid = 1'b1;
                    direct_use_bi = 1'b1;
                end else if (cand_l0_valid || cand_l1_valid) begin
                    direct_valid = 1'b1;
                    direct_use_bi = 1'b1;
                    if (cand_l1_valid && (!cand_l0_valid || (cand_l1_metric_i <= cand_l0_metric_i))) begin
                        direct_from_col_l1 = 1'b1;
                        direct_ref_idx_l0 = cand_l1_ref_idx_l0;
                        direct_ref_idx_l1 = cand_l1_ref_idx_l1;
                        direct_mvx_l0 = cand_l1_mvx_l0;
                        direct_mvy_l0 = cand_l1_mvy_l0;
                        direct_mvx_l1 = cand_l1_mvx_l1;
                        direct_mvy_l1 = cand_l1_mvy_l1;
                    end else begin
                        direct_ref_idx_l0 = cand_l0_ref_idx_l0;
                        direct_ref_idx_l1 = cand_l0_ref_idx_l1;
                        direct_mvx_l0 = cand_l0_mvx_l0;
                        direct_mvy_l0 = cand_l0_mvy_l0;
                        direct_mvx_l1 = cand_l0_mvx_l1;
                        direct_mvy_l1 = cand_l0_mvy_l1;
                    end
                end
            end
        end
    endtask

    function integer clip_bd_sample;
        input integer sample_in;
        integer max_sample;
        begin
            max_sample = (1 << BD) - 1;
            if (sample_in < 0)
                clip_bd_sample = 0;
            else if (sample_in > max_sample)
                clip_bd_sample = max_sample;
            else
                clip_bd_sample = sample_in;
        end
    endfunction

    function integer luma_raw_sample;
        input integer x;
        input integer y;
        integer sample_idx;
        begin
            sample_idx = ((y * LUMA_RAW_COLS) + x) * BD;
            luma_raw_sample = luma_raw[sample_idx +: BD];
        end
    endfunction

    function integer luma_tap_h;
        input integer x;
        input integer y;
        begin
            luma_tap_h = luma_raw_sample(x - 2, y) + luma_raw_sample(x + 3, y)
                       - 5 * (luma_raw_sample(x - 1, y) + luma_raw_sample(x + 2, y))
                       + 20 * (luma_raw_sample(x, y) + luma_raw_sample(x + 1, y));
        end
    endfunction

    function integer luma_tap_v;
        input integer x;
        input integer y;
        begin
            luma_tap_v = luma_raw_sample(x, y - 2) + luma_raw_sample(x, y + 3)
                       - 5 * (luma_raw_sample(x, y - 1) + luma_raw_sample(x, y + 2))
                       + 20 * (luma_raw_sample(x, y) + luma_raw_sample(x, y + 1));
        end
    endfunction

    function integer luma_hpel_h_sample;
        input integer x;
        input integer y;
        begin
            luma_hpel_h_sample = clip_bd_sample((luma_tap_h(x, y) + 16) >>> 5);
        end
    endfunction

    function integer luma_hpel_v_sample;
        input integer x;
        input integer y;
        begin
            luma_hpel_v_sample = clip_bd_sample((luma_tap_v(x, y) + 16) >>> 5);
        end
    endfunction

    function integer luma_hpel_c_sample;
        input integer x;
        input integer y;
        integer tap_mix;
        begin
            tap_mix = luma_tap_v(x - 2, y) + luma_tap_v(x + 3, y)
                    - 5 * (luma_tap_v(x - 1, y) + luma_tap_v(x + 2, y))
                    + 20 * (luma_tap_v(x, y) + luma_tap_v(x + 1, y));
            luma_hpel_c_sample = clip_bd_sample((tap_mix + 512) >>> 10);
        end
    endfunction

    function [1:0] qpel_ref0_plane;
        input [3:0] qpel_idx;
        begin
            case (qpel_idx)
                4'd0: qpel_ref0_plane = 2'd0;
                4'd1: qpel_ref0_plane = 2'd1;
                4'd2: qpel_ref0_plane = 2'd1;
                4'd3: qpel_ref0_plane = 2'd1;
                4'd4: qpel_ref0_plane = 2'd0;
                4'd5: qpel_ref0_plane = 2'd1;
                4'd6: qpel_ref0_plane = 2'd1;
                4'd7: qpel_ref0_plane = 2'd1;
                4'd8: qpel_ref0_plane = 2'd2;
                4'd9: qpel_ref0_plane = 2'd3;
                4'd10: qpel_ref0_plane = 2'd3;
                4'd11: qpel_ref0_plane = 2'd3;
                4'd12: qpel_ref0_plane = 2'd0;
                4'd13: qpel_ref0_plane = 2'd1;
                4'd14: qpel_ref0_plane = 2'd1;
                default: qpel_ref0_plane = 2'd1;
            endcase
        end
    endfunction

    function [1:0] qpel_ref1_plane;
        input [3:0] qpel_idx;
        begin
            case (qpel_idx)
                4'd0: qpel_ref1_plane = 2'd0;
                4'd1: qpel_ref1_plane = 2'd0;
                4'd2: qpel_ref1_plane = 2'd1;
                4'd3: qpel_ref1_plane = 2'd0;
                4'd4: qpel_ref1_plane = 2'd2;
                4'd5: qpel_ref1_plane = 2'd2;
                4'd6: qpel_ref1_plane = 2'd3;
                4'd7: qpel_ref1_plane = 2'd2;
                4'd8: qpel_ref1_plane = 2'd2;
                4'd9: qpel_ref1_plane = 2'd2;
                4'd10: qpel_ref1_plane = 2'd3;
                4'd11: qpel_ref1_plane = 2'd2;
                4'd12: qpel_ref1_plane = 2'd2;
                4'd13: qpel_ref1_plane = 2'd2;
                4'd14: qpel_ref1_plane = 2'd3;
                default: qpel_ref1_plane = 2'd2;
            endcase
        end
    endfunction

    function integer qpel_plane_sample;
        input [1:0] plane_sel;
        input integer x;
        input integer y;
        begin
            case (plane_sel)
                2'd0: qpel_plane_sample = luma_raw_sample(x, y);
                2'd1: qpel_plane_sample = luma_hpel_h_sample(x, y);
                2'd2: qpel_plane_sample = luma_hpel_v_sample(x, y);
                default: qpel_plane_sample = luma_hpel_c_sample(x, y);
            endcase
        end
    endfunction

    task automatic build_exact_luma_pred;
        input signed [7:0] mvx_qpel;
        input signed [7:0] mvy_qpel;
        output [256*BD-1:0] pred_buf_out;
        output integer sad_out;
        integer px_i, py_i;
        integer pred_sample_i, comp_sample_i, orig_sample_i, ref1_sample_i, ref2_sample_i;
        integer frac_x_i, frac_y_i, base_x_i, base_y_i;
        reg [3:0] qpel_idx_i;
        reg [1:0] ref0_plane_i, ref1_plane_i;
        begin
            frac_x_i = mvx_qpel & 8'sd3;
            frac_y_i = mvy_qpel & 8'sd3;
            base_x_i = 3 + ($signed(mvx_qpel) >>> 2);
            base_y_i = 3 + ($signed(mvy_qpel) >>> 2);
            qpel_idx_i = ((frac_y_i & 3) << 2) | (frac_x_i & 3);
            ref0_plane_i = qpel_ref0_plane(qpel_idx_i);
            ref1_plane_i = qpel_ref1_plane(qpel_idx_i);
            pred_buf_out = {(256*BD){1'b0}};
            sad_out = 0;
            for (py_i = 0; py_i < 16; py_i = py_i + 1) begin
                for (px_i = 0; px_i < 16; px_i = px_i + 1) begin
                    ref1_sample_i = qpel_plane_sample(
                        ref0_plane_i,
                        base_x_i + px_i,
                        base_y_i + py_i + ((frac_y_i == 3) ? 1 : 0)
                    );
                    if (qpel_idx_i & 4'b0101) begin
                        ref2_sample_i = qpel_plane_sample(
                            ref1_plane_i,
                            base_x_i + px_i + ((frac_x_i == 3) ? 1 : 0),
                            base_y_i + py_i
                        );
                        pred_sample_i = (ref1_sample_i + ref2_sample_i + 1) >>> 1;
                    end else begin
                        pred_sample_i = ref1_sample_i;
                    end
                    pred_buf_out[((py_i*16)+px_i)*BD +: BD] = pred_sample_i[BD-1:0];
                    comp_sample_i = use_post_weighted_pred_w ? apply_luma_weight(pred_sample_i[BD-1:0]) : pred_sample_i;
                    orig_sample_i = fetched_luma[((py_i*16)+px_i)*BD +: BD];
                    if (orig_sample_i >= comp_sample_i)
                        sad_out = sad_out + (orig_sample_i - comp_sample_i);
                    else
                        sad_out = sad_out + (comp_sample_i - orig_sample_i);
                end
            end
        end
    endtask

    reg [256*BD-1:0] pred_buf;
    wire [3:0] mb_blk_idx = {sb_r, sb_c};
    wire [BD-1:0] intra16_top_left_w =
        (mb_top_avail && mb_left_avail) ? top_ref_flat[(mb_x * 16 * BD) - BD +: BD] : {BD{1'b0}};

    // Inter residual for current 4x4 sub-block (16 pixels × (BIT_DEPTH+1) bits signed)
    reg [16*BD1-1:0] inter_resid_4x4;
    reg [16*BD1-1:0] intra16_resid_4x4;

    // Muxed residual: use inter residual for inter luma only, intra residual otherwise
    wire [16*BD1-1:0] resid_mux = (is_inter_mb_reg && is_luma) ? inter_resid_4x4 :
                                  (use_intra16_mb_reg && is_luma) ? intra16_resid_4x4 :
                                  chr_pred_mode ? chr_resid_4x4 : resid_4x4_w;

    integer idx_ei, idx_pi, idx_ir, idx_rb, meta_bank_i, meta_mb_i;
    // Chroma pixel index helper for 4:2:0, 4:2:2, and 4:4:4.
    // The transformed chroma path still targets the current 4:2:0 / 4:2:2 flow;
    // this helper is widened so the tree also compiles for 4:4:4 I_PCM work.
    function automatic [7:0] chr_pix_idx;
        input [1:0] blk_r;
        input [3:0] pix;  // idx_ei or idx_pi: [3:2]=pixel_row, [1:0]=pixel_col
        input [1:0] blk_c;
        begin
            if (CHROMA_FORMAT_IDC == 3)
                chr_pix_idx = {blk_r[1:0], pix[3:2], blk_c[1:0], pix[1:0]}; // 8 bits, 256 pixels
            else if (CHROMA_FORMAT_IDC == 2)
                chr_pix_idx = {1'b0, blk_r[1:0], pix[3:2], blk_c[0], pix[1:0]}; // 7 bits, 128 pixels
            else
                chr_pix_idx = {2'b00, blk_r[0], pix[3:2], blk_c[0], pix[1:0]}; // 6 bits, 64 pixels
        end
    endfunction

    always @(*) begin
        // Sub-block original pixels
sb_orig_pixels = {(16*BD){1'b0}};
        for (idx_ei = 0; idx_ei < 16; idx_ei = idx_ei + 1) begin
            if (is_cb)
                sb_orig_pixels[idx_ei*BD +: BD] = fetched_cb[chr_pix_idx(sb_r, idx_ei[3:0], sb_c)*BD +: BD];
            else if (is_cr)
                sb_orig_pixels[idx_ei*BD +: BD] = fetched_cr[chr_pix_idx(sb_r, idx_ei[3:0], sb_c)*BD +: BD];
            else
                sb_orig_pixels[idx_ei*BD +: BD] = fetched_luma[{sb_r, idx_ei[3:2], sb_c, idx_ei[1:0]}*BD +: BD];
        end

        // Sub-block prediction pixels for reconstruct
        // For inter MBs: use inter_pred_buf; for intra: use pred_4x4_w scattered into MB
pred_buf = {(256*BD){1'b0}};
        if (is_inter_mb_reg && is_luma) begin
            if (use_post_weighted_pred_w) begin
                for (idx_pi = 0; idx_pi < 256; idx_pi = idx_pi + 1)
                    pred_buf[idx_pi*BD +: BD] = apply_luma_weight(inter_pred_buf[idx_pi*BD +: BD]);
            end else begin
                pred_buf = inter_pred_buf;
            end
        end else if (is_inter_mb_reg && (CHROMA_FORMAT_IDC == 3) && (is_cb || is_cr)) begin
            for (idx_pi = 0; idx_pi < 256; idx_pi = idx_pi + 1) begin
                if (is_cr)
                    pred_buf[idx_pi*BD +: BD] = use_post_weighted_pred_w ? apply_chroma_cr_weight(inter_chr_pred_cr[idx_pi*BD +: BD])
                                                                    : inter_chr_pred_cr[idx_pi*BD +: BD];
                else
                    pred_buf[idx_pi*BD +: BD] = use_post_weighted_pred_w ? apply_chroma_cb_weight(inter_chr_pred_cb[idx_pi*BD +: BD])
                                                                    : inter_chr_pred_cb[idx_pi*BD +: BD];
            end
        end else if (use_intra16_mb_reg && is_luma) begin
            pred_buf = intra16_pred_buf;
        end else begin
            for (idx_pi = 0; idx_pi < 16; idx_pi = idx_pi + 1) begin
                if (is_luma)
                    pred_buf[{sb_r, idx_pi[3:2], sb_c, idx_pi[1:0]}*BD +: BD] = pred_4x4_w[idx_pi*BD +: BD];
                else
                    pred_buf[chr_pix_idx(sb_r, idx_pi[3:0], sb_c)*BD +: BD] = pred_4x4_w[idx_pi*BD +: BD];
            end
        end

        // Inter residual: orig - inter_pred for current 4x4 sub-block
        inter_resid_4x4 = {(16*BD1){1'b0}};
        intra16_resid_4x4 = {(16*BD1){1'b0}};
        for (idx_ir = 0; idx_ir < 16; idx_ir = idx_ir + 1) begin : inter_resid_calc
            reg [BD-1:0] orig_pix, pred_pix;
            reg signed [BD:0] diff;
            orig_pix = fetched_luma[{sb_r, idx_ir[3:2], sb_c, idx_ir[1:0]}*BD +: BD];
            pred_pix = inter_pred_buf[{sb_r, idx_ir[3:2], sb_c, idx_ir[1:0]}*BD +: BD];
            if (use_post_weighted_pred_w)
                pred_pix = apply_luma_weight(pred_pix);
            diff = $signed({1'b0, orig_pix}) - $signed({1'b0, pred_pix});
            inter_resid_4x4[idx_ir*BD1 +: BD1] = diff;
            pred_pix = intra16_pred_buf[{sb_r, idx_ir[3:2], sb_c, idx_ir[1:0]}*BD +: BD];
            diff = $signed({1'b0, orig_pix}) - $signed({1'b0, pred_pix});
            intra16_resid_4x4[idx_ir*BD1 +: BD1] = diff;
        end

        // Neighbor routing
        sb_top_left_avail = 1'b0;
        sb_top_left_pixel = {BD{1'b0}};
        sb_top_right_pixels = {(4*BD){1'b0}};
        if (sb_r == 2'd0) begin
            if (is_luma) begin
                sb_top_avail  = mb_top_avail;
                sb_top_pixels = top_pixels_flat[sb_c*4*BD +: 4*BD];
            end else begin
                sb_top_avail  = mb_top_avail;
                sb_top_pixels = is_cb ? top_chr_cb_nb[mb_x][sb_c*4*BD +: 4*BD]
                                      : top_chr_cr_nb[mb_x][sb_c*4*BD +: 4*BD];
            end
        end else if (is_luma) begin
            sb_top_avail  = 1'b1;
            sb_top_pixels = recon_buf[((sb_r*4 - 1)*16 + sb_c*4)*BD +: 4*BD];
        end else begin
            // Chroma inner top: read from the reconstructed chroma plane.
            sb_top_avail  = 1'b1;
            if (is_cb) begin
                sb_top_pixels[0*BD +: BD] = chr_recon_cb[((sb_r*4-1)*CHR_MB_WIDTH + sb_c*4 + 0)*BD +: BD];
                sb_top_pixels[1*BD +: BD] = chr_recon_cb[((sb_r*4-1)*CHR_MB_WIDTH + sb_c*4 + 1)*BD +: BD];
                sb_top_pixels[2*BD +: BD] = chr_recon_cb[((sb_r*4-1)*CHR_MB_WIDTH + sb_c*4 + 2)*BD +: BD];
                sb_top_pixels[3*BD +: BD] = chr_recon_cb[((sb_r*4-1)*CHR_MB_WIDTH + sb_c*4 + 3)*BD +: BD];
            end else begin
                sb_top_pixels[0*BD +: BD] = chr_recon_cr[((sb_r*4-1)*CHR_MB_WIDTH + sb_c*4 + 0)*BD +: BD];
                sb_top_pixels[1*BD +: BD] = chr_recon_cr[((sb_r*4-1)*CHR_MB_WIDTH + sb_c*4 + 1)*BD +: BD];
                sb_top_pixels[2*BD +: BD] = chr_recon_cr[((sb_r*4-1)*CHR_MB_WIDTH + sb_c*4 + 2)*BD +: BD];
                sb_top_pixels[3*BD +: BD] = chr_recon_cr[((sb_r*4-1)*CHR_MB_WIDTH + sb_c*4 + 3)*BD +: BD];
            end
        end

        if (sb_top_avail) begin
            if (is_luma) begin
                if (sb_r == 2'd0) begin
                    if (sb_c == 2'd3) begin
                        if (mb_x < MB_COLS[6:0] - 7'd1)
                            sb_top_right_pixels = top_ref_flat[((mb_x + 7'd1) * 16 * BD) +: 4*BD];
                        else
                            sb_top_right_pixels = {4{sb_top_pixels[3*BD +: BD]}};
                    end else begin
                        sb_top_right_pixels = top_pixels_flat[((sb_c*4) + 3'd4)*BD +: 4*BD];
                    end
                end else if (sub_blk == 5'd3 || sub_blk == 5'd11 || sb_c == 2'd3) begin
                    sb_top_right_pixels = {4{sb_top_pixels[3*BD +: BD]}};
                end else begin
                    sb_top_right_pixels = recon_buf[((sb_r*4 - 1)*16 + sb_c*4 + 4)*BD +: 4*BD];
                end
            end else begin
                if (sb_r == 2'd0) begin
                    if (sb_c == 2'd3) begin
                        if (mb_x < MB_COLS[6:0] - 7'd1)
                            sb_top_right_pixels = is_cb ? top_chr_cb_nb[mb_x + 7'd1][0 +: 4*BD]
                                                        : top_chr_cr_nb[mb_x + 7'd1][0 +: 4*BD];
                        else
                            sb_top_right_pixels = {4{sb_top_pixels[3*BD +: BD]}};
                    end else begin
                        sb_top_right_pixels = is_cb ? top_chr_cb_nb[mb_x][((sb_c*4) + 3'd4)*BD +: 4*BD]
                                                    : top_chr_cr_nb[mb_x][((sb_c*4) + 3'd4)*BD +: 4*BD];
                    end
                end else if (chroma_sub_blk_idx_w == 4'd3 || chroma_sub_blk_idx_w == 4'd11 || sb_c == 2'd3) begin
                    sb_top_right_pixels = {4{sb_top_pixels[3*BD +: BD]}};
                end else if (is_cb) begin
                    sb_top_right_pixels[0*BD +: BD] = chr_recon_cb[((sb_r*4-1)*CHR_MB_WIDTH + sb_c*4 + 4)*BD +: BD];
                    sb_top_right_pixels[1*BD +: BD] = chr_recon_cb[((sb_r*4-1)*CHR_MB_WIDTH + sb_c*4 + 5)*BD +: BD];
                    sb_top_right_pixels[2*BD +: BD] = chr_recon_cb[((sb_r*4-1)*CHR_MB_WIDTH + sb_c*4 + 6)*BD +: BD];
                    sb_top_right_pixels[3*BD +: BD] = chr_recon_cb[((sb_r*4-1)*CHR_MB_WIDTH + sb_c*4 + 7)*BD +: BD];
                end else begin
                    sb_top_right_pixels[0*BD +: BD] = chr_recon_cr[((sb_r*4-1)*CHR_MB_WIDTH + sb_c*4 + 4)*BD +: BD];
                    sb_top_right_pixels[1*BD +: BD] = chr_recon_cr[((sb_r*4-1)*CHR_MB_WIDTH + sb_c*4 + 5)*BD +: BD];
                    sb_top_right_pixels[2*BD +: BD] = chr_recon_cr[((sb_r*4-1)*CHR_MB_WIDTH + sb_c*4 + 6)*BD +: BD];
                    sb_top_right_pixels[3*BD +: BD] = chr_recon_cr[((sb_r*4-1)*CHR_MB_WIDTH + sb_c*4 + 7)*BD +: BD];
                end
            end
        end

        if (is_luma) begin
            if (sb_r == 2'd0) begin
                if (sb_c == 2'd0) begin
                    sb_top_left_avail = mb_top_avail && mb_left_avail;
                    if (mb_top_avail && mb_left_avail)
                        sb_top_left_pixel = top_ref_flat[(mb_x * 16 * BD) - BD +: BD];
                end else begin
                    sb_top_left_avail = mb_top_avail;
                    if (mb_top_avail)
                        sb_top_left_pixel = top_pixels_flat[(sb_c*4 - 1)*BD +: BD];
                end
            end else if (sb_c == 2'd0) begin
                sb_top_left_avail = mb_left_avail;
                if (mb_left_avail)
                    sb_top_left_pixel = left_pixels_flat[(sb_r*4 - 1)*BD +: BD];
            end else begin
                sb_top_left_avail = 1'b1;
                sb_top_left_pixel = recon_buf[((sb_r*4 - 1)*16 + (sb_c*4 - 1))*BD +: BD];
            end
        end else begin
            if (sb_r == 2'd0) begin
                if (sb_c == 2'd0) begin
                    sb_top_left_avail = mb_top_avail && mb_left_avail;
                    if (mb_top_avail && mb_left_avail)
                        sb_top_left_pixel = is_cb ? top_chr_cb_nb[mb_x - 7'd1][(CHR_MB_WIDTH-1)*BD +: BD]
                                                  : top_chr_cr_nb[mb_x - 7'd1][(CHR_MB_WIDTH-1)*BD +: BD];
                end else begin
                    sb_top_left_avail = mb_top_avail;
                    if (mb_top_avail)
                        sb_top_left_pixel = is_cb ? top_chr_cb_nb[mb_x][(sb_c*4 - 1)*BD +: BD]
                                                  : top_chr_cr_nb[mb_x][(sb_c*4 - 1)*BD +: BD];
                end
            end else if (sb_c == 2'd0) begin
                sb_top_left_avail = mb_left_avail;
                if (mb_left_avail)
                    sb_top_left_pixel = is_cb ? left_chr_cb_nb[(sb_r*4 - 1)*BD +: BD]
                                              : left_chr_cr_nb[(sb_r*4 - 1)*BD +: BD];
            end else begin
                sb_top_left_avail = 1'b1;
                if (is_cb)
                    sb_top_left_pixel = chr_recon_cb[((sb_r*4 - 1)*CHR_MB_WIDTH + (sb_c*4 - 1))*BD +: BD];
                else
                    sb_top_left_pixel = chr_recon_cr[((sb_r*4 - 1)*CHR_MB_WIDTH + (sb_c*4 - 1))*BD +: BD];
            end
        end

        if (sb_c == 2'd0) begin
            if (is_luma) begin
                sb_left_avail  = mb_left_avail;
                sb_left_pixels = left_pixels_flat[sb_r*4*BD +: 4*BD];
            end else begin
                sb_left_avail  = mb_left_avail;
                sb_left_pixels = is_cb ? left_chr_cb_nb[sb_r*4*BD +: 4*BD]
                                       : left_chr_cr_nb[sb_r*4*BD +: 4*BD];
            end
        end else if (is_luma) begin
            sb_left_avail  = 1'b1;
            sb_left_pixels[0*BD +: BD] = recon_buf[((sb_r*4 + 0)*16 + (sb_c*4 - 1))*BD +: BD];
            sb_left_pixels[1*BD +: BD] = recon_buf[((sb_r*4 + 1)*16 + (sb_c*4 - 1))*BD +: BD];
            sb_left_pixels[2*BD +: BD] = recon_buf[((sb_r*4 + 2)*16 + (sb_c*4 - 1))*BD +: BD];
            sb_left_pixels[3*BD +: BD] = recon_buf[((sb_r*4 + 3)*16 + (sb_c*4 - 1))*BD +: BD];
        end else begin
            // Chroma inner left: read from the reconstructed chroma plane.
            sb_left_avail  = 1'b1;
            if (is_cb) begin
                sb_left_pixels[0*BD +: BD] = chr_recon_cb[((sb_r*4+0)*CHR_MB_WIDTH + sb_c*4-1)*BD +: BD];
                sb_left_pixels[1*BD +: BD] = chr_recon_cb[((sb_r*4+1)*CHR_MB_WIDTH + sb_c*4-1)*BD +: BD];
                sb_left_pixels[2*BD +: BD] = chr_recon_cb[((sb_r*4+2)*CHR_MB_WIDTH + sb_c*4-1)*BD +: BD];
                sb_left_pixels[3*BD +: BD] = chr_recon_cb[((sb_r*4+3)*CHR_MB_WIDTH + sb_c*4-1)*BD +: BD];
            end else begin
                sb_left_pixels[0*BD +: BD] = chr_recon_cr[((sb_r*4+0)*CHR_MB_WIDTH + sb_c*4-1)*BD +: BD];
                sb_left_pixels[1*BD +: BD] = chr_recon_cr[((sb_r*4+1)*CHR_MB_WIDTH + sb_c*4-1)*BD +: BD];
                sb_left_pixels[2*BD +: BD] = chr_recon_cr[((sb_r*4+2)*CHR_MB_WIDTH + sb_c*4-1)*BD +: BD];
                sb_left_pixels[3*BD +: BD] = chr_recon_cr[((sb_r*4+3)*CHR_MB_WIDTH + sb_c*4-1)*BD +: BD];
            end
        end
    end

    always @(*) begin
        recon_top_row_buf_w = {(16*BD){1'b0}};
        recon_right_col_buf_w = {(16*BD){1'b0}};
        for (idx_rb = 0; idx_rb < 16; idx_rb = idx_rb + 1) begin
            recon_top_row_buf_w[idx_rb*BD +: BD] = luma_recon_buf[((15*16)+idx_rb)*BD +: BD];
            recon_right_col_buf_w[idx_rb*BD +: BD] = luma_recon_buf[((idx_rb*16)+15)*BD +: BD];
        end
    end

    always @(*) begin : luma8_resid_and_recon_pack
        integer li;
        reg [7:0] mb_idx;
        reg [BD-1:0] orig_pix;
        reg [BD-1:0] pred_pix;
        luma8_resid_flat = {(64*BD1){1'b0}};
        luma8_recon_resid_flat = {256{1'b0}};
        for (li = 0; li < 64; li = li + 1) begin
            mb_idx = {luma8_group[1], li[5:3], luma8_group[0], li[2:0]};
            orig_pix = fetched_luma[mb_idx*BD +: BD];
            pred_pix = pred_buf[mb_idx*BD +: BD];
            luma8_resid_flat[li*BD1 +: BD1] = {1'b0, orig_pix} - {1'b0, pred_pix};
        end
        for (li = 0; li < 16; li = li + 1) begin
            mb_idx = {luma8_group[1], luma8_sub[1], li[3:2], luma8_group[0], luma8_sub[0], li[1:0]};
            luma8_recon_resid_flat[li*16 +: 16] = luma8_it_out_flat[mb_idx*16 +: 16];
        end
    end

    // ====================================================================
    // Quarter-pel luma refinement fetch window and chroma MV derivation
    // ====================================================================
    wire signed [7:0] chr_mv_x_active_w =
        (is_b_frame && is_b_bi_mb_reg) ? (b_bi_chr_fetch_l1_phase ? me_best_mvx_l1 : me_best_mvx_l0) :
                                         me_best_mvx;
    wire signed [7:0] chr_mv_y_active_w =
        (is_b_frame && is_b_bi_mb_reg) ? (b_bi_chr_fetch_l1_phase ? me_best_mvy_l1 : me_best_mvy_l0) :
                                         me_best_mvy;
    wire signed [7:0] chr_off_x = $signed(chr_mv_x_active_w) >>> 3;
    wire signed [7:0] chr_off_y = $signed(chr_mv_y_active_w) >>> 3;
    wire [2:0] chr_frac_x_w = chr_mv_x_active_w[2:0];
    wire [2:0] chr_frac_y_w = chr_mv_y_active_w[2:0];

    wire signed [11:0] luma_fc_x = $signed({1'b0, mb_x, 4'd0}) + $signed(me_fullpel_mvx) + $signed({7'd0, luma_f_col}) - 12'sd3;
    wire signed [11:0] luma_fc_y = $signed({1'b0, mb_y, 4'd0}) + $signed(me_fullpel_mvy) + $signed({7'd0, luma_f_row}) - 12'sd3;
    wire [10:0] luma_fc_cx = (luma_fc_x < 0) ? 11'd0 : (luma_fc_x >= FRAME_WIDTH[10:0]) ? FRAME_WIDTH[10:0] - 11'd1 : luma_fc_x[10:0];
    wire [9:0]  luma_fc_cy = (luma_fc_y < 0) ? 10'd0 : (luma_fc_y >= FRAME_HEIGHT[9:0]) ? FRAME_HEIGHT[9:0] - 10'd1 : luma_fc_y[9:0];
    wire [19:0] luma_f_addr_cur = luma_fc_cy * FRAME_WIDTH[10:0] + luma_fc_cx;

    // Chroma fetch: row/col counters for 9x9 or 8x8 fetch grid
    reg [4:0] chr_f_row;
    reg [CHR_FETCH_COL_W-1:0] chr_f_col;
    // Next col/row (for pipelined address)
    wire [CHR_FETCH_COL_W-1:0] chr_fn_col_w = (chr_f_col + 1'b1 >= chr_fetch_cols) ? {CHR_FETCH_COL_W{1'b0}} : (chr_f_col + 1'b1);
    wire [4:0] chr_fn_row_w = (chr_f_col + 1'b1 >= chr_fetch_cols) ? chr_f_row + 5'd1 : chr_f_row;
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
        // Default: ME drives the read port.
        // Luma interpolation and deblock neighbour fetches temporarily borrow it.
        if (top_state == TS_LUMA_FETCH)
            ref_mem_rd_addr = luma_f_addr_cur;
        else if ((top_state == TS_DEBLOCK_MB) && (deblock_fetch_phase == DBF_LEFT_LUMA))
            ref_mem_rd_addr = cur_luma_addr_fn(mb_x - 7'd1, mb_y, deblock_fetch_idx[5:2], 12 + deblock_fetch_idx[1:0]);
        else if ((top_state == TS_DEBLOCK_MB) && (deblock_fetch_phase == DBF_TOP_LUMA))
            ref_mem_rd_addr = cur_luma_addr_fn(mb_x, mb_y - 6'd1, 12 + deblock_fetch_idx[5:4], deblock_fetch_idx[3:0]);
        else
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
        .top_left_avail(sb_top_left_avail), .top_left(sb_top_left_pixel),
        .orig_4x4(sb_orig_pixels), .top_4(sb_top_pixels), .top_right_4(sb_top_right_pixels), .left_4(sb_left_pixels),
        .force_mode_en(force_intra_pred_mode_w), .force_mode(forced_intra_pred_mode_w),
        .pred_4x4(pred_4x4_w), .resid_4x4(resid_4x4_w), .pred_mode(pred_mode_w)
    );

    h264_intra16_pred #(.BIT_DEPTH(BIT_DEPTH)) u_intra16_pred (
        .clk(clk), .rst_n(rst_n), .start(intra16_start), .done(intra16_done),
        .top_avail(mb_top_avail), .left_avail(mb_left_avail), .top_left_avail(mb_top_avail && mb_left_avail),
        .top_left(intra16_top_left_w), .orig_16x16(fetched_luma), .top_16(top_pixels_flat), .left_16(left_pixels_flat),
        .pred_16x16(intra16_pred_w), .pred_mode(intra16_mode_w), .best_sad(intra16_sad_w)
    );

    h264_transform #(.BIT_DEPTH(BIT_DEPTH)) u_xform (.clk(clk), .rst_n(rst_n), .start(xform_start), .done(xform_done), .in_flat(resid_mux), .out_flat(xform_out_flat));
    h264_quantize #(.BIT_DEPTH(BIT_DEPTH)) u_quant (.clk(clk), .rst_n(rst_n), .start(quant_start), .done(quant_done), .in_flat(xform_out_flat), .quant_flat(quant_out_flat));
    // 8x8 High-profile luma path
    reg [64*BD1-1:0] luma8_resid_flat;
    reg [255:0]      luma8_recon_resid_flat;
    wire [64*CW8-1:0] luma8_xform_out_flat;
    wire              luma8_xform_done;
    wire [64*32-1:0]  luma8_quant_out_flat;
    wire              luma8_quant_done;
    wire [255:0]      luma8_scan_flat;
    wire [4:0]        luma8_total_coeffs;
    wire [1:0]        luma8_trailing_ones;
    wire [3:0]        luma8_last_nonzero_idx;
    wire [64*CW8-1:0]  luma8_iq_out_flat;
    wire [64*16-1:0]  luma8_it_out_flat;
    reg               luma8_xform_start, luma8_quant_start;
    reg               luma8_zz_start;
    wire              luma8_zz_done;
    reg               luma8_iq_start, luma8_it_start;
    wire              luma8_iq_done, luma8_it_done;
    h264_transform8x8 #(.BIT_DEPTH(BIT_DEPTH)) u_xform8 (.clk(clk), .rst_n(rst_n), .start(luma8_xform_start), .done(luma8_xform_done), .in_flat(luma8_resid_flat), .out_flat(luma8_xform_out_flat));
    h264_quantize8x8 #(.BIT_DEPTH(BIT_DEPTH)) u_quant8 (.clk(clk), .rst_n(rst_n), .start(luma8_quant_start), .done(luma8_quant_done), .qp(6'd26), .in_flat(luma8_xform_out_flat), .quant_flat(luma8_quant_out_flat));
    h264_zigzag8x8_cavlc #(.BIT_DEPTH(BIT_DEPTH), .QW(32)) u_zigzag8 (.clk(clk), .rst_n(rst_n), .start(luma8_zz_start), .done(luma8_zz_done), .in_flat(luma8_quant_out_flat), .sub_block_idx(luma8_sub), .scan_flat(luma8_scan_flat), .total_coeffs(luma8_total_coeffs), .trailing_ones(luma8_trailing_ones), .last_nonzero_idx(luma8_last_nonzero_idx));
    h264_inverse_quant8x8 #(.BIT_DEPTH(BIT_DEPTH)) u_iq8 (.clk(clk), .rst_n(rst_n), .start(luma8_iq_start), .done(luma8_iq_done), .qp(6'd26), .quant_flat(luma8_quant_out_flat), .dequant_flat(luma8_iq_out_flat));
    h264_inverse_transform8x8 #(.BIT_DEPTH(BIT_DEPTH)) u_it8 (.clk(clk), .rst_n(rst_n), .start(luma8_it_start), .done(luma8_it_done), .in_flat(luma8_iq_out_flat), .out_flat(luma8_it_out_flat));
    // Chroma processing signals
    reg         chr_dc_start, chr_dc_inverse;
    wire        chr_dc_done;
    reg  signed [CW-1:0] chr_dc_in0, chr_dc_in1, chr_dc_in2, chr_dc_in3;
    wire signed [15:0] chr_dc_out0, chr_dc_out1, chr_dc_out2, chr_dc_out3;

    // Chroma processing registers
    reg [2:0]   chr_phase;    // Phase within chroma processing
    reg [CHR_BLK_W-1:0] chr_blk;      // Which chroma 4x4 block within the plane
    reg         chr_is_cr;    // 0=Cb, 1=Cr
    reg [2:0]   luma16_phase; // Phase within I_16x16 luma DC/AC coding
    reg [2:0]   luma8_phase;  // Phase within High-profile 8x8 luma coding
    reg [1:0]   luma8_group;  // 0..3 8x8 luma group inside the MB
    reg [1:0]   luma8_sub;    // 0..3 4x4 syntax block within the 8x8 group
    reg         luma8_started;
    reg [255:0] cb_quant_buf [0:CHR_BLOCKS_PER_PLANE-1];
    reg [255:0] cr_quant_buf [0:CHR_BLOCKS_PER_PLANE-1];
    reg signed [CW-1:0] chr_dc_buf [0:CHR_BLOCKS_PER_PLANE-1];
    reg signed [15:0] cb_dc_q [0:CHR_BLOCKS_STORAGE-1];
    reg signed [15:0] cr_dc_q [0:CHR_BLOCKS_STORAGE-1];
    // Inverse Hadamard DC values for reconstruction (replaces DC in IQ output)
    reg signed [15:0] cb_inv_dc [0:CHR_BLOCKS_STORAGE-1];
    reg signed [15:0] cr_inv_dc [0:CHR_BLOCKS_STORAGE-1];
    reg [CHR_BLK_W-1:0] chr_recon_blk;           // Block counter for chroma reconstruction phase
    // Saved Cb DC prediction values (since chr_dc_pred gets overwritten by Cr)
    reg [BD-1:0] cb_dc_pred_saved [0:CHR_BLOCKS_STORAGE-1];
    reg [255:0] i16_quant_buf [0:15];
    reg signed [CW-1:0] i16_dc_buf [0:15];
    reg signed [15:0] i16_dc_q [0:15];
    reg signed [15:0] i16_inv_dc [0:15];
    reg [3:0] luma16_blk;
    reg [4:0] i16_dc_total_coeff;
    reg       i16_luma_ac_nonzero;
    reg       i16_chroma_dc_nonzero;
    reg       i16_chroma_ac_nonzero;
    reg [1:0] i16_cbp_chroma;
    reg [4:0] left_mb_i16dc_nz;
    reg [4:0] top_mb_i16dc_nz [0:MB_COLS-1];
    reg       left_is_i16;
    reg       top_is_i16 [0:MB_COLS-1];

    // Chroma DC zigzag input: pack 4 DCs into 256-bit format (positions 0-3)
    reg [255:0] chr_dc_zigzag_in;
    reg [255:0] i16_dc_zigzag_in;

    // Mux for zigzag input: normally quant_out_flat, during chroma DC it's chr_dc_zigzag_in
    reg         use_chr_dc_zigzag;
    reg         use_i16_dc_zigzag;
    wire [255:0] zigzag_in_mux = use_chr_dc_zigzag ? chr_dc_zigzag_in :
                                 use_i16_dc_zigzag ? i16_dc_zigzag_in : quant_out_flat;

    // Chroma AC: use quantized block buffer with DC zeroed out
    reg         use_chr_ac_zigzag;
    reg         use_i16_ac_zigzag;
    reg [255:0] chr_ac_zigzag_in;
    reg [255:0] i16_ac_zigzag_in;
    wire [255:0] zigzag_in_final = use_chr_ac_zigzag ? chr_ac_zigzag_in :
                                   use_i16_ac_zigzag ? i16_ac_zigzag_in : zigzag_in_mux;

    // CAVLC chroma mode signals
    reg         cavlc_is_chroma_dc;
    reg         cavlc_is_chroma_ac;
    reg         zz_chroma_ac_mode;
    reg         zz_chroma_dc_mode;
    reg         use_i16_dc_nc;

    // Extra chroma DC signals for 4:2:2 (8 DCs instead of 4)
    reg  signed [CW-1:0] chr_dc_in4, chr_dc_in5, chr_dc_in6, chr_dc_in7;
    wire signed [15:0] chr_dc_out4, chr_dc_out5, chr_dc_out6, chr_dc_out7;
    reg         i16_dc_start, i16_dc_inverse;
    wire        i16_dc_done;
    reg  [16*CW-1:0] i16_dc_in_flat;
    wire [255:0]     i16_dc_out_flat;

    h264_chroma_dc #(.BIT_DEPTH(BIT_DEPTH), .CHROMA_FORMAT_IDC(CHROMA_FORMAT_IDC)) u_chroma_dc (
        .clk(clk), .rst_n(rst_n), .start(chr_dc_start), .do_inverse(chr_dc_inverse), .done(chr_dc_done),
        .dc_in_0(chr_dc_in0), .dc_in_1(chr_dc_in1), .dc_in_2(chr_dc_in2), .dc_in_3(chr_dc_in3),
        .dc_in_4(chr_dc_in4), .dc_in_5(chr_dc_in5), .dc_in_6(chr_dc_in6), .dc_in_7(chr_dc_in7),
        .dc_out_0(chr_dc_out0), .dc_out_1(chr_dc_out1), .dc_out_2(chr_dc_out2), .dc_out_3(chr_dc_out3),
        .dc_out_4(chr_dc_out4), .dc_out_5(chr_dc_out5), .dc_out_6(chr_dc_out6), .dc_out_7(chr_dc_out7)
    );

    h264_luma_dc #(.BIT_DEPTH(BIT_DEPTH)) u_luma_dc (
        .clk(clk), .rst_n(rst_n), .start(i16_dc_start), .do_inverse(i16_dc_inverse), .done(i16_dc_done),
        .dc_in_flat(i16_dc_in_flat), .dc_out_flat(i16_dc_out_flat)
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
    reg [4:0] top_mb_nz_cb [0:CHR_TOP_NZ_COUNT-1];
    reg [4:0] top_mb_nz_cr [0:CHR_TOP_NZ_COUNT-1];

    // Deblocking metadata packed for the post-reconstruction in-loop filter.
    wire deblock_active_w = (DEBLOCK_ENABLE != 0) && (DISABLE_DEBLOCKING_FILTER_IDC[1:0] != 2'd1);
    wire [1:0] deblock_disable_idc_w = deblock_active_w ? DISABLE_DEBLOCKING_FILTER_IDC[1:0] : 2'd1;
    wire signed [3:0] deblock_alpha_off_w = 4'sd0;
    wire signed [3:0] deblock_beta_off_w  = 4'sd0;
    reg [15:0] deblock_nz_luma_flat;
    reg [2*CHR_BLOCKS_PER_PLANE-1:0] deblock_nz_chroma_flat;
    reg [3:0] deblock_left_nz_luma_flat;
    reg [3:0] deblock_top_nz_luma_flat;
    reg [CHR_BLOCK_ROWS-1:0] deblock_left_nz_chroma_cb_flat;
    reg [CHR_BLOCK_ROWS-1:0] deblock_left_nz_chroma_cr_flat;
    reg [CHR_BLOCK_COLS-1:0] deblock_top_nz_chroma_cb_flat;
    reg [CHR_BLOCK_COLS-1:0] deblock_top_nz_chroma_cr_flat;

    always @(*) begin : deblock_nz_pack
        integer dbi;
        for (dbi = 0; dbi < 16; dbi = dbi + 1)
            deblock_nz_luma_flat[dbi] = (use_ipcm_mb_reg || (nz_coeff[dbi] != 5'd0));
        for (dbi = 0; dbi < CHR_BLOCKS_PER_PLANE; dbi = dbi + 1) begin
            deblock_nz_chroma_flat[dbi] = use_ipcm_mb_reg || (nz_coeff[chroma_sub_blk_from_rc(1'b0, chroma_blk_row_from_idx(dbi[CHR_BLK_W-1:0]), chroma_blk_col_from_idx(dbi[CHR_BLK_W-1:0]))] != 5'd0);
            deblock_nz_chroma_flat[CHR_BLOCKS_PER_PLANE + dbi] = use_ipcm_mb_reg || (nz_coeff[chroma_sub_blk_from_rc(1'b1, chroma_blk_row_from_idx(dbi[CHR_BLK_W-1:0]), chroma_blk_col_from_idx(dbi[CHR_BLK_W-1:0]))] != 5'd0);
        end
        for (dbi = 0; dbi < 4; dbi = dbi + 1) begin
            deblock_left_nz_luma_flat[dbi] = (left_mb_nz[dbi] != 5'd0);
            deblock_top_nz_luma_flat[dbi] = (top_mb_nz[mb_x * 4 + dbi] != 5'd0);
        end
        for (dbi = 0; dbi < CHR_BLOCK_ROWS; dbi = dbi + 1) begin
            deblock_left_nz_chroma_cb_flat[dbi] = (left_mb_nz_cb[dbi] != 5'd0);
            deblock_left_nz_chroma_cr_flat[dbi] = (left_mb_nz_cr[dbi] != 5'd0);
        end
        for (dbi = 0; dbi < CHR_BLOCK_COLS; dbi = dbi + 1) begin
            deblock_top_nz_chroma_cb_flat[dbi] = (top_mb_nz_cb[mb_x * CHR_BLOCK_COLS + dbi] != 5'd0);
            deblock_top_nz_chroma_cr_flat[dbi] = (top_mb_nz_cr[mb_x * CHR_BLOCK_COLS + dbi] != 5'd0);
        end
    end

    reg [SUB_BLK_W-1:0] left_blk_idx, top_blk_idx;
    always @(*) begin
        left_blk_idx = {SUB_BLK_W{1'b0}};
        top_blk_idx  = {SUB_BLK_W{1'b0}};
        if (is_luma) begin
            if (sb_c > 0)
                left_blk_idx = luma_sub_blk_from_rc(sb_r, sb_c - 2'd1);
            if (sb_r > 0)
                top_blk_idx = luma_sub_blk_from_rc(sb_r - 2'd1, sb_c);
        end else if (is_cb) begin
            if (sb_c > 0)
                left_blk_idx = chroma_sub_blk_from_rc(1'b0, sb_r, sb_c - 2'd1);
            if (sb_r > 0)
                top_blk_idx = chroma_sub_blk_from_rc(1'b0, sb_r - 2'd1, sb_c);
        end else if (is_cr) begin
            if (sb_c > 0)
                left_blk_idx = chroma_sub_blk_from_rc(1'b1, sb_r, sb_c - 2'd1);
            if (sb_r > 0)
                top_blk_idx = chroma_sub_blk_from_rc(1'b1, sb_r - 2'd1, sb_c);
        end
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

    wire       intra_left_avail_w = (sb_c > 0) ? 1'b1 : mb_left_avail;
    wire       intra_top_avail_w  = (sb_r > 0) ? 1'b1 : mb_top_avail;
    wire [3:0] intra_left_mode_w =
        (sb_c > 0) ? intra_mode_cur[left_blk_idx[3:0]] :
        ((mb_left_avail && !left_is_inter) ? left_mb_mode[sb_r] : INTRA_MODE_DC);
    wire [3:0] intra_top_mode_w =
        (sb_r > 0) ? intra_mode_cur[top_blk_idx[3:0]] :
        ((mb_top_avail && !top_is_inter[mb_x]) ? top_mb_mode[mb_x * 4 + sb_c] : INTRA_MODE_DC);
    wire       intra_dc_pred_forced_w = !intra_left_avail_w || !intra_top_avail_w;
    wire [3:0] intra_mpm_w = intra_dc_pred_forced_w ? INTRA_MODE_DC :
        ((intra_left_mode_w < intra_top_mode_w) ? intra_left_mode_w : intra_top_mode_w);
    wire       intra_prev_flag_w = (pred_mode_w == intra_mpm_w);
    wire [3:0] intra_pred_minus1_w = pred_mode_w - 4'd1;
    wire [2:0] intra_rem_mode_w = (pred_mode_w < intra_mpm_w) ? pred_mode_w[2:0] : intra_pred_minus1_w[2:0];

    // Cross-MB chroma nC lookup
    wire [4:0] left_chr_nz = is_cb ? left_mb_nz_cb[sb_r] : left_mb_nz_cr[sb_r];
    wire [4:0] top_chr_nz  = is_cb ? top_mb_nz_cb[mb_x * CHR_BLOCK_COLS + sb_c] : top_mb_nz_cr[mb_x * CHR_BLOCK_COLS + sb_c];
    // Intra_16x16 luma DC uses the normal surrounding 4x4 nnz context for
    // coeff_token selection, not a separate neighbor luma-DC TotalCoeff path.
    wire [4:0] nA_val = (sb_c > 0) ? nz_coeff[left_blk_idx] :
                        (mb_left_avail ? (is_luma ? left_mb_nz[sb_r] : left_chr_nz) : 5'd0);
    wire [4:0] nB_val = (sb_r > 0) ? nz_coeff[top_blk_idx]  :
                        (mb_top_avail  ? (is_luma ? top_mb_nz[mb_x * 4 + sb_c] : top_chr_nz) : 5'd0);
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

    wire use_luma8_cavlc = (top_state == TS_LUMA8);
    wire [255:0] cavlc_scan_flat_mux = use_luma8_cavlc ? luma8_scan_flat : scan_flat;
    wire [4:0]  cavlc_total_coeffs_mux = use_luma8_cavlc ? luma8_total_coeffs : total_coeffs;
    wire [1:0]  cavlc_trailing_ones_mux = use_luma8_cavlc ? luma8_trailing_ones : trailing_ones;
    wire [3:0]  cavlc_last_nonzero_idx_mux = use_luma8_cavlc ? luma8_last_nonzero_idx : last_nonzero_idx;
    h264_cavlc u_cavlc (.clk(clk), .rst_n(rst_n), .start(cavlc_start), .done(cavlc_done), .scan_flat(cavlc_scan_flat_mux), .total_coeffs(cavlc_total_coeffs_mux), .trailing_ones(cavlc_trailing_ones_mux), .last_nonzero_idx(cavlc_last_nonzero_idx_mux), .nC(nC_val), .is_chroma_dc(cavlc_is_chroma_dc), .chroma_dc_422(chroma_dc_422_flag), .is_chroma_ac(cavlc_is_chroma_ac), .bits_out(cavlc_bits), .bits_count(cavlc_count), .bits_valid(cavlc_bits_valid));
    // IQ input mux: normally quant_out_flat, during chroma recon uses chr_iq_input
    reg         use_chr_iq_input;
    reg         use_i16_iq_input;
    reg [255:0] chr_iq_input;
    reg [255:0] i16_iq_input;
    wire [255:0] iq_in_mux = use_chr_iq_input ? chr_iq_input :
                             use_i16_iq_input ? i16_iq_input : quant_out_flat;
    h264_inverse_quant #(.BIT_DEPTH(BIT_DEPTH)) u_iq (.clk(clk), .rst_n(rst_n), .start(iq_start), .done(iq_done), .quant_flat(iq_in_mux), .dequant_flat(iq_out_flat));
    // IT input mux: normally iq_out_flat, during chroma recon patches DC with inverse Hadamard value
    reg         use_chr_it_input;
    reg         use_i16_it_input;
    reg signed [CW-1:0] chr_it_dc_patch;  // Inverse Hadamard DC to patch into IT input
    reg signed [CW-1:0] i16_it_dc_patch;
    wire [16*CW-1:0] it_in_mux = use_chr_it_input ? {iq_out_flat[16*CW-1:CW], chr_it_dc_patch} :
                                 use_i16_it_input ? {iq_out_flat[16*CW-1:CW], i16_it_dc_patch} : iq_out_flat;
    h264_inverse_transform #(.BIT_DEPTH(BIT_DEPTH)) u_it (.clk(clk), .rst_n(rst_n), .start(it_start), .done(it_done), .in_flat(it_in_mux), .out_flat(it_out_flat));

    wire use_luma8_recon = (top_state == TS_LUMA8) && (luma8_phase == 3'd6);
    wire [255:0] recon_resid_mux = use_luma8_recon ? luma8_recon_resid_flat :
                                   use_chr_it_input ? {iq_out_flat[16*CW-1:CW], chr_it_dc_patch} :
                                   use_i16_it_input ? {iq_out_flat[16*CW-1:CW], i16_it_dc_patch} :
                                   it_out_flat;
    h264_reconstruct #(.BIT_DEPTH(BIT_DEPTH)) u_recon (
        .clk(clk), .rst_n(rst_n), .start(recon_start), .done(recon_done), .sub_block_idx(sub_blk[3:0]),
        .pred_flat(pred_buf), .recon_resid_flat(recon_resid_mux), .recon_in(recon_buf), .recon_out(recon_out_w),
        .recon_top_row(recon_top_row_w), .recon_right_col(recon_right_col_w));

    wire [256*BIT_DEPTH-1:0] deblock_luma_post_w;
    wire [CHR_MB_PIXELS*BIT_DEPTH-1:0] deblock_cb_post_w;
    wire [CHR_MB_PIXELS*BIT_DEPTH-1:0] deblock_cr_post_w;
    wire [48*BIT_DEPTH-1:0] deblock_left_luma_patch_w;
    wire [48*BIT_DEPTH-1:0] deblock_top_luma_patch_w;
    wire [CHR_MB_HEIGHT*BIT_DEPTH-1:0] deblock_left_cb_patch_w;
    wire [CHR_MB_HEIGHT*BIT_DEPTH-1:0] deblock_left_cr_patch_w;
    wire [CHR_MB_WIDTH*BIT_DEPTH-1:0] deblock_top_cb_patch_w;
    wire [CHR_MB_WIDTH*BIT_DEPTH-1:0] deblock_top_cr_patch_w;
    wire [15:0] deblock_changed_count_w;
    wire [15:0] deblock_filtered_edge_count_w;
    wire        deblock_cur_has_l0_w = is_inter_mb_reg && (!is_b_frame || !is_b_l1_mb_reg || is_b_bi_mb_reg);
    wire        deblock_cur_has_l1_w = is_inter_mb_reg && is_b_frame && (is_b_l1_mb_reg || is_b_bi_mb_reg);
    wire        deblock_left_has_l0_w = left_is_inter;
    wire        deblock_left_has_l1_w = left_is_inter_l1;
    wire        deblock_top_has_l0_w = top_is_inter[mb_x];
    wire        deblock_top_has_l1_w = top_is_inter_l1[mb_x];
    wire        deblock_left_is_intra_w = !(left_is_inter || left_is_inter_l1);
    wire        deblock_top_is_intra_w = !(top_is_inter[mb_x] || top_is_inter_l1[mb_x]);
    wire signed [7:0] deblock_cur_mvx_l0_w = (is_b_frame && is_b_bi_mb_reg) ? me_best_mvx_l0 : me_best_mvx;
    wire signed [7:0] deblock_cur_mvy_l0_w = (is_b_frame && is_b_bi_mb_reg) ? me_best_mvy_l0 : me_best_mvy;
    wire signed [7:0] deblock_cur_mvx_l1_w = (is_b_frame && is_b_bi_mb_reg) ? me_best_mvx_l1 :
                                             ((is_b_frame && is_b_l1_mb_reg) ? me_best_mvx : 8'sd0);
    wire signed [7:0] deblock_cur_mvy_l1_w = (is_b_frame && is_b_bi_mb_reg) ? me_best_mvy_l1 :
                                             ((is_b_frame && is_b_l1_mb_reg) ? me_best_mvy : 8'sd0);
    wire [1:0]  deblock_cur_ref_idx_l0_w = mb_ref_idx_reg;
    wire [1:0]  deblock_cur_ref_idx_l1_w = is_b_l1_mb_reg ? mb_ref_idx_reg : mb_ref_idx_l1_reg;
    wire [15:0] deblock_patch_write_count_w =
        deblock_active_w ?
            ((mb_left_avail ? (16'd48 + (CHR_MB_HEIGHT << 1)) : 16'd0) +
             (mb_top_avail ? (16'd48 + (CHR_MB_WIDTH << 1)) : 16'd0)) :
            16'd0;
    wire [256*BIT_DEPTH-1:0] ref_luma_write_buf_w = deblock_active_w ? deblock_luma_post_w : luma_recon_buf;
    wire [CHR_MB_PIXELS*BIT_DEPTH-1:0] ref_cb_write_buf_w = deblock_active_w ? deblock_cb_post_w : chr_recon_cb;
    wire [CHR_MB_PIXELS*BIT_DEPTH-1:0] ref_cr_write_buf_w = deblock_active_w ? deblock_cr_post_w : chr_recon_cr;

    h264_deblock_mb #(
        .BIT_DEPTH(BIT_DEPTH),
        .CHROMA_FORMAT_IDC(CHROMA_FORMAT_IDC)
    ) u_deblock_mb (
        .deblock_enable(deblock_active_w),
        .disable_deblocking_filter_idc(deblock_disable_idc_w),
        .slice_alpha_c0_offset_div2(deblock_alpha_off_w),
        .slice_beta_offset_div2(deblock_beta_off_w),
        .mb_left_avail(mb_left_avail),
        .mb_top_avail(mb_top_avail),
        .cur_is_intra(!is_inter_mb_reg),
        .left_is_intra(deblock_left_is_intra_w),
        .top_is_intra(deblock_top_is_intra_w),
        .cur_has_l0(deblock_cur_has_l0_w),
        .cur_has_l1(deblock_cur_has_l1_w),
        .cur_ref_idx_l0(deblock_cur_ref_idx_l0_w),
        .cur_ref_idx_l1(deblock_cur_ref_idx_l1_w),
        .cur_mvx_l0(deblock_cur_mvx_l0_w),
        .cur_mvy_l0(deblock_cur_mvy_l0_w),
        .cur_mvx_l1(deblock_cur_mvx_l1_w),
        .cur_mvy_l1(deblock_cur_mvy_l1_w),
        .left_has_l0(deblock_left_has_l0_w),
        .left_has_l1(deblock_left_has_l1_w),
        .left_ref_idx_l0(left_ref_idx),
        .left_ref_idx_l1(left_ref_idx_l1),
        .left_mvx_l0(left_mvx),
        .left_mvy_l0(left_mvy),
        .left_mvx_l1(left_mvx_l1),
        .left_mvy_l1(left_mvy_l1),
        .top_has_l0(deblock_top_has_l0_w),
        .top_has_l1(deblock_top_has_l1_w),
        .top_ref_idx_l0(top_ref_idx[mb_x]),
        .top_ref_idx_l1(top_ref_idx_l1[mb_x]),
        .top_mvx_l0(top_mvx[mb_x]),
        .top_mvy_l0(top_mvy[mb_x]),
        .top_mvx_l1(top_mvx_l1[mb_x]),
        .top_mvy_l1(top_mvy_l1[mb_x]),
        .nz_luma_4x4(deblock_nz_luma_flat),
        .left_nz_luma_4x4(deblock_left_nz_luma_flat),
        .top_nz_luma_4x4(deblock_top_nz_luma_flat),
        .nz_chroma_4x4(deblock_nz_chroma_flat),
        .left_nz_chroma_cb(deblock_left_nz_chroma_cb_flat),
        .left_nz_chroma_cr(deblock_left_nz_chroma_cr_flat),
        .top_nz_chroma_cb(deblock_top_nz_chroma_cb_flat),
        .top_nz_chroma_cr(deblock_top_nz_chroma_cr_flat),
        .luma_pre(luma_recon_buf),
        .cb_pre(chr_recon_cb),
        .cr_pre(chr_recon_cr),
        .left_luma_p(deblock_left_luma_p_buf),
        .top_luma_p(deblock_top_luma_p_buf),
        .left_cb_p(deblock_left_cb_p_buf),
        .left_cr_p(deblock_left_cr_p_buf),
        .top_cb_p(deblock_top_cb_p_buf),
        .top_cr_p(deblock_top_cr_p_buf),
        .luma_post(deblock_luma_post_w),
        .cb_post(deblock_cb_post_w),
        .cr_post(deblock_cr_post_w),
        .left_luma_patch(deblock_left_luma_patch_w),
        .top_luma_patch(deblock_top_luma_patch_w),
        .left_cb_patch(deblock_left_cb_patch_w),
        .left_cr_patch(deblock_left_cr_patch_w),
        .top_cb_patch(deblock_top_cb_patch_w),
        .top_cr_patch(deblock_top_cr_patch_w),
        .changed_count(deblock_changed_count_w),
        .filtered_edge_count(deblock_filtered_edge_count_w)
    );

    h264_bitstream #(
        .MB_COLS(MB_COLS),
        .MB_ROWS(MB_ROWS),
        .BIT_DEPTH(BIT_DEPTH),
        .CHROMA_FORMAT_IDC(CHROMA_FORMAT_IDC),
        .FRAME_RATE(24)
    ) u_bitstream (
        .clk(clk), .rst_n(rst_n), .cmd_write_sps(bs_cmd_sps), .cmd_write_pps(bs_cmd_pps), .cmd_write_slice_hdr(bs_cmd_slice),
        .cmd_write_mb_header(bs_cmd_mb_hdr), .cmd_write_trailing(bs_cmd_trailing), .cmd_flush(bs_cmd_flush),
        .cmd_clear_fifo(bs_cmd_clear_fifo),
        .cavlc_valid(cavlc_bits_valid), .cavlc_bits(cavlc_bits), .cavlc_count(cavlc_count),
        .mb_qp_delta(8'd0), .mb_has_residual(mb_has_residual),
        .force_transform_8x8_in(force_transform_8x8_in),
        .cabac_feature_enable(cabac_feature_enable_w),
        .cabac_slice_enable(cabac_slice_enable_w),
        .cabac_skip_ctx(cabac_skip_ctx_reg),
        .is_p_slice(is_p_frame), .is_b_slice(is_b_frame), .is_b_ref_slice(is_b_ref_frame),
        .stream_has_b_slices(stream_has_b_slices_in), .frame_num(cur_frame_num),
        .pic_order_cnt_lsb(cur_pic_order_cnt_lsb),
        .is_inter_mb(is_inter_mb_reg), .is_skip_mb(is_skip_mb_reg),
        .is_b_direct_mb(is_b_direct_mb_reg),
        .is_b_l1_mb(is_b_l1_mb_reg), .is_b_bi_mb(is_b_bi_mb_reg),
        .direct_spatial_mv_pred_flag(direct_spatial_mv_pred_flag_w),
        .mb_ref_idx_l0(mb_ref_idx_reg), .mb_ref_idx_l1(mb_ref_idx_l1_reg),
        .mvd_x_l0(mvd_x_l0_w), .mvd_y_l0(mvd_y_l0_w),
        .mvd_x_l1(mvd_x_l1_w), .mvd_y_l1(mvd_y_l1_w),
        .cabac_mvd_ctx_x(cabac_mvd_ctx_x_w), .cabac_mvd_ctx_y(cabac_mvd_ctx_y_w),
        .cabac_cbp_luma_ctx0_sel(cabac_cbp_luma_ctx0_sel_w),
        .cabac_cbp_luma_ctx1_sel(cabac_cbp_luma_ctx1_sel_w),
        .cabac_cbp_luma_ctx2_sel(cabac_cbp_luma_ctx2_sel_w),
        .cabac_cbp_luma(cabac_cbp_luma_reg),
        // Chroma residual CABAC payload is still guarded at the top level;
        // keep the bitstream chroma-CBP bins dormant until the DC/AC payload
        // scheduler is connected, even though stable AC snapshots are now
        // captured alongside the luma payload.
        .cabac_cbp_chroma(2'd0),
        .cabac_chroma_scan_flat(cabac_chroma_scan_flat_reg),
        .cabac_chroma_nz_mask(cabac_chroma_nz_mask_reg),
        .cabac_luma_scan_flat(cabac_luma_scan_flat_reg),
        .cabac_luma_nz_mask(cabac_luma_nz_mask_reg),
        .slice_num_ref_idx_l0_active_minus1(slice_num_ref_idx_l0_active_minus1),
        .hold_fifo_drain(bs_hold_fifo_drain), .is_intra16_mb(is_intra16_mb_hdr), .is_ipcm_mb(is_ipcm_mb_hdr), .intra_mb_type_code_num(intra_mb_type_code_num),
        .intra_pred_bits(intra_pred_bits_mb), .intra_pred_count(intra_pred_count_mb),
        .ipcm_luma_flat(recon_buf), .ipcm_cb_flat(chr_recon_cb), .ipcm_cr_flat(chr_recon_cr),
        .weighted_pred_enable(weighted_pred_enable_cfg_w),
        .luma_log2_weight_denom(luma_log2_weight_denom_cfg_w),
        .luma_weight(luma_weight_cfg_w),
        .luma_offset(luma_offset_cfg_w),
        .chroma_log2_weight_denom(chroma_log2_weight_denom_cfg_w),
        .chroma_weight_cb(chroma_weight_cb_cfg_w),
        .chroma_offset_cb(chroma_offset_cb_cfg_w),
        .chroma_weight_cr(chroma_weight_cr_cfg_w),
        .chroma_offset_cr(chroma_offset_cr_cfg_w),
        .busy(bs_busy), .cmd_done(bs_cmd_done),
        .bs_mem_addr(bs_mem_addr), .bs_mem_data(bs_mem_data), .bs_mem_wr(bs_mem_wr), .bs_bytes_written(bs_bytes_written)
    );

    // ====================================================================
    // Main FSM
    // ====================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            top_state <= TS_IDLE; done <= 1'b0; mb_x <= 7'd0; mb_y <= 6'd0; sub_blk <= 5'd0; mb_count <= 12'd0;
            fetch_start <= 1'b0; pred_start <= 1'b0; intra16_start <= 1'b0; xform_start <= 1'b0; quant_start <= 1'b0; zz_start <= 1'b0; luma8_xform_start <= 1'b0; luma8_quant_start <= 1'b0; luma8_zz_start <= 1'b0; luma8_iq_start <= 1'b0; luma8_it_start <= 1'b0;
            cavlc_start <= 1'b0; iq_start <= 1'b0; it_start <= 1'b0; recon_start <= 1'b0; me_start <= 1'b0;
            bs_cmd_sps <= 1'b0; bs_cmd_pps <= 1'b0; bs_cmd_slice <= 1'b0; bs_cmd_mb_hdr <= 1'b0; bs_cmd_trailing <= 1'b0; bs_cmd_flush <= 1'b0; bs_cmd_clear_fifo <= 1'b0;
            mb_top_avail <= 1'b0; mb_left_avail <= 1'b0; mb_has_residual <= 1'b0; bs_hold_fifo_drain <= 1'b0;
            blk_state <= BS_PRED; blk_started <= 1'b0; iq_done_latched <= 1'b0;
            recon_buf <= {(256*BD){1'b0}}; luma_recon_buf <= {(256*BD){1'b0}}; top_ref_flat <= {(MB_COLS*16*BD){1'b0}}; left_ref_flat <= {(16*BD){1'b0}};
            top_pixels_flat <= {(16*BD){1'b0}}; left_pixels_flat <= {(16*BD){1'b0}}; flush_pending <= 1'b0; flush_accepted <= 1'b0;
            is_p_frame <= 1'b0; is_b_frame <= 1'b0; is_b_ref_frame <= 1'b0; is_inter_mb_reg <= 1'b0; is_skip_mb_reg <= 1'b0; is_b_l1_mb_reg <= 1'b0; is_b_bi_mb_reg <= 1'b0; is_b_direct_mb_reg <= 1'b0; is_b_direct_from_l1_reg <= 1'b0; use_intra16_mb_reg <= 1'b0; use_ipcm_mb_reg <= 1'b0; cur_frame_num <= 8'd0; cur_pic_order_cnt_lsb <= 9'd0; direct_temporal_slice_mode_reg <= 1'b0;
            cabac_skip_ctx_reg <= 2'd0;
            cabac_cbp_luma_reg <= 4'd0;
            cabac_luma_scan_flat_reg <= 4096'd0;
            cabac_luma_nz_mask_reg <= 16'd0;
            cabac_chroma_scan_flat_reg <= 4096'd0;
            cabac_chroma_nz_mask_reg <= 16'd0;
            me_best_mvx <= 8'sd0; me_best_mvy <= 8'sd0; me_best_mvx_l0 <= 8'sd0; me_best_mvy_l0 <= 8'sd0; me_best_mvx_l1 <= 8'sd0; me_best_mvy_l1 <= 8'sd0; me_best_sad <= 18'd0; me_fullpel_best_sad <= 18'd0;
            inter_pred_buf <= {(256*BD){1'b0}}; ref_wr_idx <= 9'd0;
            deblock_fetch_phase <= DBF_IDLE; deblock_wr_phase <= DBW_CUR_LUMA; deblock_fetch_idx <= 7'd0; deblock_fetch_started <= 1'b0;
            deblock_left_luma_p_buf <= {(64*BD){1'b0}}; deblock_top_luma_p_buf <= {(64*BD){1'b0}};
            deblock_left_cb_p_buf <= {(4*CHR_MB_HEIGHT*BD){1'b0}}; deblock_left_cr_p_buf <= {(4*CHR_MB_HEIGHT*BD){1'b0}};
            deblock_top_cb_p_buf <= {(4*CHR_MB_WIDTH*BD){1'b0}}; deblock_top_cr_p_buf <= {(4*CHR_MB_WIDTH*BD){1'b0}};
            intra16_pred_buf <= {(256*BD){1'b0}}; intra16_mode_mb <= 2'd2;
            ref_rd_bank_sel <= 3'd0; ref_wr_bank_sel <= 3'd0;
            ref_mem_wr_en <= 1'b0; ref_mem_wr_addr <= 20'd0; ref_mem_wr_data <= {BD{1'b0}};
            mvp_x <= 8'sd0; mvp_y <= 8'sd0; mvp_x_l0 <= 8'sd0; mvp_y_l0 <= 8'sd0; mvp_x_l1 <= 8'sd0; mvp_y_l1 <= 8'sd0;
            left_mvx <= 8'sd0; left_mvy <= 8'sd0; left_mvx_l1 <= 8'sd0; left_mvy_l1 <= 8'sd0;
            left_mvd_abs_x <= 7'd0; left_mvd_abs_y <= 7'd0;
            left_is_inter <= 1'b0; left_is_skip <= 1'b0; left_is_inter_l1 <= 1'b0; left_is_b_l1 <= 1'b0; left_is_i16 <= 1'b0; left_ref_idx <= 2'd0; left_ref_idx_l1 <= 2'd0; left_mb_i16dc_nz <= 5'd0;
            diag_mvx <= 8'sd0; diag_mvy <= 8'sd0; diag_mvx_l1 <= 8'sd0; diag_mvy_l1 <= 8'sd0; diag_is_inter <= 1'b0; diag_is_inter_l1 <= 1'b0; diag_is_b_l1 <= 1'b0; diag_ref_idx <= 2'd0; diag_ref_idx_l1 <= 2'd0;
            mb_ref_idx_reg <= 2'd0; mb_ref_idx_l1_reg <= 2'd0; me_search_pass <= 2'd0;
            valid_ref_count <= 3'd0; newest_ref_bank <= 3'd0; older_ref_bank <= 3'd1; oldest_ref_bank <= 3'd2; ancient_ref_bank <= 3'd3; next_write_bank <= 3'd0; current_write_bank <= 3'd0;
            slice_num_ref_idx_l0_active_minus1 <= 2'd0;
            me_pass0_mvx <= 8'sd0; me_pass0_mvy <= 8'sd0; me_pass0_sad <= 18'd0; me_pass0_ref_mb <= {(256*BD){1'b0}};
            me_pass0_ref_idx <= 2'd0;
            for (idx_rb = 0; idx_rb < 3; idx_rb = idx_rb + 1) begin
                b_l0_pass_valid[idx_rb] <= 1'b0;
                b_l0_pass_mvx[idx_rb] <= 8'sd0;
                b_l0_pass_mvy[idx_rb] <= 8'sd0;
                b_l0_pass_sad[idx_rb] <= 18'd0;
                b_l0_pass_ref_mb[idx_rb] <= {(256*BD){1'b0}};
            end
            for (idx_rb = 0; idx_rb < MB_COLS; idx_rb = idx_rb + 1) begin
                top_is_skip[idx_rb] <= 1'b0;
                top_mvd_abs_x[idx_rb] <= 7'd0;
                top_mvd_abs_y[idx_rb] <= 7'd0;
            end
            chr_dc_start <= 1'b0; chr_dc_inverse <= 1'b0;
            i16_dc_start <= 1'b0; i16_dc_inverse <= 1'b0;
            chr_phase <= 3'd0; chr_blk <= {CHR_BLK_W{1'b0}}; chr_is_cr <= 1'b0; luma16_phase <= 3'd0; luma16_blk <= 4'd0; luma8_phase <= 3'd0; luma8_group <= 2'd0; luma8_sub <= 2'd0; luma8_started <= 1'b0;
            use_chr_dc_zigzag <= 1'b0; use_chr_ac_zigzag <= 1'b0; use_i16_dc_zigzag <= 1'b0; use_i16_ac_zigzag <= 1'b0;
            cavlc_is_chroma_dc <= 1'b0; cavlc_is_chroma_ac <= 1'b0;
            zz_chroma_ac_mode <= 1'b0;
            zz_chroma_dc_mode <= 1'b0;
            use_i16_dc_nc <= 1'b0;
            chr_dc_in0 <= {CW{1'b0}}; chr_dc_in1 <= {CW{1'b0}};
            chr_dc_in2 <= {CW{1'b0}}; chr_dc_in3 <= {CW{1'b0}};
            chr_dc_in4 <= {CW{1'b0}}; chr_dc_in5 <= {CW{1'b0}};
            chr_dc_in6 <= {CW{1'b0}}; chr_dc_in7 <= {CW{1'b0}};
            chr_dc_zigzag_in <= 256'd0; chr_ac_zigzag_in <= 256'd0; i16_dc_zigzag_in <= 256'd0; i16_ac_zigzag_in <= 256'd0;
            chr_pred_mode <= 1'b0;
            left_chr_cb_nb <= {(CHR_MB_HEIGHT*BD){1'b0}}; left_chr_cr_nb <= {(CHR_MB_HEIGHT*BD){1'b0}};
            me_fullpel_mvx <= 8'sd0; me_fullpel_mvy <= 8'sd0;
            luma_fetch_started <= 1'b0; luma_fetch_cnt <= 9'd0; luma_f_row <= 5'd0; luma_f_col <= 5'd0;
            luma_raw <= {(LUMA_RAW_SAMPLES*BD){1'b0}};
            b_bi_luma_fetch_l1_phase <= 1'b0; b_bi_fullpel_ref_l1 <= {(256*BD){1'b0}}; b_bi_fullpel_sad_l1 <= 18'd0; b_bi_luma_pred_l0 <= {(256*BD){1'b0}}; b_bi_luma_sad_l0 <= 18'd0;
            b_direct_pending_valid <= 1'b0; b_direct_pending_use_l1 <= 1'b0; b_direct_pending_use_bi <= 1'b0; b_direct_pending_from_col_l1 <= 1'b0;
            b_direct_pending_ref_idx_l0 <= 2'd0; b_direct_pending_ref_idx_l1 <= 2'd0;
            b_direct_pending_mvx_l0 <= 8'sd0; b_direct_pending_mvy_l0 <= 8'sd0; b_direct_pending_mvx_l1 <= 8'sd0; b_direct_pending_mvy_l1 <= 8'sd0;
            b_direct_luma_pred_l0 <= {(256*BD){1'b0}}; b_direct_luma_sad_l0 <= 18'd0;
            b_bi_mvp_x_l0_reg <= 8'sd0; b_bi_mvp_y_l0_reg <= 8'sd0; b_bi_mvp_x_l1_reg <= 8'sd0; b_bi_mvp_y_l1_reg <= 8'sd0;
            inter_chr_pred_cb <= {(CHR_MB_PIXELS*BD){1'b0}}; inter_chr_pred_cr <= {(CHR_MB_PIXELS*BD){1'b0}};
            b_bi_chr_pred_cb_l0 <= {(CHR_MB_PIXELS*BD){1'b0}}; b_bi_chr_pred_cr_l0 <= {(CHR_MB_PIXELS*BD){1'b0}};
            inter_chr_mode <= 1'b0;
            chr_fetch_cnt <= {CHR_FETCH_W{1'b0}}; chr_fetch_started <= 1'b0; b_bi_chr_fetch_l1_phase <= 1'b0;
            skip_probe_pending <= 1'b0; inter_chr_prefetched_valid <= 1'b0;
            chr_raw_cb <= {(CHR_RAW_SAMPLES*BD){1'b0}}; chr_raw_cr <= {(CHR_RAW_SAMPLES*BD){1'b0}};
            chr_frac_x <= 3'd0; chr_frac_y <= 3'd0;
            chr_fetch_rows <= CHR_MB_HEIGHT[4:0]; chr_fetch_cols <= CHR_MB_WIDTH[CHR_FETCH_COL_W-1:0];
            chr_f_row <= 5'd0; chr_f_col <= {CHR_FETCH_COL_W{1'b0}};
            chr_cb_ref_rd_addr <= 18'd0; chr_cb_ref_wr_en <= 1'b0;
            chr_cb_ref_wr_addr <= 18'd0; chr_cb_ref_wr_data <= {BD{1'b0}};
            chr_cr_ref_rd_addr <= 18'd0; chr_cr_ref_wr_en <= 1'b0;
            chr_cr_ref_wr_addr <= 18'd0; chr_cr_ref_wr_data <= {BD{1'b0}};
            use_chr_iq_input <= 1'b0; use_i16_iq_input <= 1'b0; chr_iq_input <= 256'd0; i16_iq_input <= 256'd0;
            use_chr_it_input <= 1'b0; use_i16_it_input <= 1'b0; chr_it_dc_patch <= {CW{1'b0}}; i16_it_dc_patch <= {CW{1'b0}};
            i16_dc_in_flat <= {(16*CW){1'b0}};
            chr_recon_blk <= {CHR_BLK_W{1'b0}};
            intra_pred_bits_mb <= 64'd0;
            intra_pred_count_mb <= 7'd0;
            is_intra16_mb_hdr <= 1'b0; is_ipcm_mb_hdr <= 1'b0; intra_mb_type_code_num <= 6'd0;
            i16_dc_total_coeff <= 5'd0; i16_luma_ac_nonzero <= 1'b0; i16_chroma_dc_nonzero <= 1'b0; i16_chroma_ac_nonzero <= 1'b0; i16_cbp_chroma <= 2'd0;
            pskip_syntax_eligible_reg <= 1'b0;
            bskip_syntax_eligible_reg <= 1'b0;
            frame_skip_mb_count <= 16'd0;
            frame_b_l1_mb_count <= 16'd0;
            frame_b_bi_mb_count <= 16'd0;
            frame_b_direct_mb_count <= 16'd0;
            frame_b_l0_nonzero_ref_mb_count <= 16'd0;
            frame_b_direct_nonzero_ref_mb_count <= 16'd0;
            frame_b_direct_from_l1_mb_count <= 16'd0;
            frame_cabac_p16x16_mb_count <= 16'd0;
            for (meta_bank_i = 0; meta_bank_i < 5; meta_bank_i = meta_bank_i + 1) begin
                for (meta_mb_i = 0; meta_mb_i < TOTAL_MBS; meta_mb_i = meta_mb_i + 1) begin
                    refmeta_is_intra[meta_bank_i][meta_mb_i] = 1'b1;
                    refmeta_has_l0[meta_bank_i][meta_mb_i] = 1'b0;
                    refmeta_has_l1[meta_bank_i][meta_mb_i] = 1'b0;
                    refmeta_ref_idx_l0[meta_bank_i][meta_mb_i] = 2'd0;
                    refmeta_ref_idx_l1[meta_bank_i][meta_mb_i] = 2'd0;
                    refmeta_mvx_l0[meta_bank_i][meta_mb_i] = 8'sd0;
                    refmeta_mvy_l0[meta_bank_i][meta_mb_i] = 8'sd0;
                    refmeta_mvx_l1[meta_bank_i][meta_mb_i] = 8'sd0;
                    refmeta_mvy_l1[meta_bank_i][meta_mb_i] = 8'sd0;
                end
                refbank_poc_lsb[meta_bank_i] = 9'd0;
                refbank_has_l0_ref0[meta_bank_i] = 1'b0;
                refbank_l0_ref0_bank[meta_bank_i] = 3'd0;
                refbank_has_l0_ref1[meta_bank_i] = 1'b0;
                refbank_l0_ref1_bank[meta_bank_i] = 3'd0;
                refbank_has_l0_ref2[meta_bank_i] = 1'b0;
                refbank_l0_ref2_bank[meta_bank_i] = 3'd0;
                refbank_has_l1_ref0[meta_bank_i] = 1'b0;
                refbank_l1_ref0_bank[meta_bank_i] = 3'd0;
            end
        end else begin
            fetch_start <= 1'b0; pred_start <= 1'b0; intra16_start <= 1'b0; xform_start <= 1'b0; quant_start <= 1'b0; zz_start <= 1'b0; luma8_xform_start <= 1'b0; luma8_quant_start <= 1'b0; luma8_zz_start <= 1'b0; luma8_iq_start <= 1'b0; luma8_it_start <= 1'b0;
            cavlc_start <= 1'b0; iq_start <= 1'b0; it_start <= 1'b0; recon_start <= 1'b0; me_start <= 1'b0;
            bs_cmd_sps <= 1'b0; bs_cmd_pps <= 1'b0; bs_cmd_slice <= 1'b0; bs_cmd_mb_hdr <= 1'b0; bs_cmd_trailing <= 1'b0; bs_cmd_flush <= 1'b0; bs_cmd_clear_fifo <= 1'b0;
            done <= 1'b0;
            ref_mem_wr_en <= 1'b0;
            chr_cb_ref_wr_en <= 1'b0; chr_cr_ref_wr_en <= 1'b0;
            chr_dc_start <= 1'b0;
            i16_dc_start <= 1'b0;

            case (top_state)
                TS_IDLE: if (start) begin
                    cur_frame_num <= frame_num_in;
                    cur_pic_order_cnt_lsb <= pic_order_cnt_lsb_in;
                    is_p_frame <= ~is_idr_in && !is_b_in;
                    is_b_frame <= ~is_idr_in && is_b_in;
                    is_b_ref_frame <= ~is_idr_in && is_b_in && is_bref_in;
                    direct_temporal_slice_mode_reg <= direct_temporal_slice_mode_next(is_b_in, is_idr_in, pic_order_cnt_lsb_in);
                    mb_x <= 7'd0; mb_y <= 6'd0; mb_count <= 12'd0;
                    me_search_pass <= 2'd0;
                    mb_ref_idx_reg <= 2'd0;
                    mb_ref_idx_l1_reg <= 2'd0;
                    frame_skip_mb_count <= 16'd0;
                    frame_b_l1_mb_count <= 16'd0;
                    frame_b_bi_mb_count <= 16'd0;
                    frame_b_direct_mb_count <= 16'd0;
                    frame_b_l0_nonzero_ref_mb_count <= 16'd0;
                    frame_b_direct_nonzero_ref_mb_count <= 16'd0;
                    frame_b_direct_from_l1_mb_count <= 16'd0;
                    frame_cabac_p16x16_mb_count <= 16'd0;
                    left_is_skip <= 1'b0;
                    cabac_skip_ctx_reg <= 2'd0;
                    for (idx_rb = 0; idx_rb < MB_COLS; idx_rb = idx_rb + 1)
                        top_is_skip[idx_rb] <= 1'b0;
                    if (is_idr_in) begin
                        valid_ref_count <= 3'd0;
                        newest_ref_bank <= 3'd0;
                        older_ref_bank <= 3'd1;
                        oldest_ref_bank <= 3'd2;
                        ancient_ref_bank <= 3'd3;
                        current_write_bank <= 3'd0;
                        next_write_bank <= 3'd1;
                        ref_rd_bank_sel <= 3'd0;
                        ref_wr_bank_sel <= 3'd0;
                        slice_num_ref_idx_l0_active_minus1 <= 2'd0;
                        top_state <= TS_WRITE_SPS;  // IDR: write SPS+PPS
                    end else begin
                        current_write_bank <= next_write_bank;
                        ref_wr_bank_sel <= next_write_bank;
                        ref_rd_bank_sel <= is_b_in && (valid_ref_count >= 3'd2) ? older_ref_bank : newest_ref_bank;
                        if (is_b_in)
                            slice_num_ref_idx_l0_active_minus1 <= b_slice_num_ref_idx_l0_active_minus1_w;
                        else
                            slice_num_ref_idx_l0_active_minus1 <= (valid_ref_count == 3'd0) ? 2'd0 : (valid_ref_count[1:0] - 2'd1);
                        top_state <= TS_WRITE_SLICE; // P-frame: skip SPS/PPS
                    end
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
                    use_intra16_mb_reg <= 1'b0;
                    use_ipcm_mb_reg <= 1'b0;
                    is_skip_mb_reg <= 1'b0;
                    is_b_l1_mb_reg <= 1'b0;
                    is_b_bi_mb_reg <= 1'b0;
                    is_b_direct_mb_reg <= 1'b0;
                    is_b_direct_from_l1_reg <= 1'b0;
                    b_direct_pending_valid <= 1'b0;
                    b_direct_pending_use_l1 <= 1'b0;
                    b_direct_pending_use_bi <= 1'b0;
                    b_direct_pending_from_col_l1 <= 1'b0;
                    b_direct_pending_ref_idx_l0 <= 2'd0;
                    b_direct_pending_ref_idx_l1 <= 2'd0;
                    b_direct_pending_mvx_l0 <= 8'sd0;
                    b_direct_pending_mvy_l0 <= 8'sd0;
                    b_direct_pending_mvx_l1 <= 8'sd0;
                    b_direct_pending_mvy_l1 <= 8'sd0;
                    b_direct_luma_pred_l0 <= {(256*BD){1'b0}};
                    b_direct_luma_sad_l0 <= 18'd0;
                    b_bi_luma_fetch_l1_phase <= 1'b0;
                    b_bi_luma_sad_l0 <= 18'd0;
                    b_bi_mvp_x_l0_reg <= 8'sd0; b_bi_mvp_y_l0_reg <= 8'sd0; b_bi_mvp_x_l1_reg <= 8'sd0; b_bi_mvp_y_l1_reg <= 8'sd0;
                    for (idx_rb = 0; idx_rb < 3; idx_rb = idx_rb + 1) begin
                        b_l0_pass_valid[idx_rb] <= 1'b0;
                        b_l0_pass_mvx[idx_rb] <= 8'sd0;
                        b_l0_pass_mvy[idx_rb] <= 8'sd0;
                        b_l0_pass_sad[idx_rb] <= 18'd0;
                        b_l0_pass_ref_mb[idx_rb] <= {(256*BD){1'b0}};
                    end
                    skip_probe_pending <= 1'b0;
                    inter_chr_prefetched_valid <= 1'b0;
                    mb_has_residual <= 1'b0;
                    pskip_syntax_eligible_reg <= 1'b0;
                    bskip_syntax_eligible_reg <= 1'b0;
                    is_intra16_mb_hdr <= 1'b0;
                    is_ipcm_mb_hdr <= 1'b0;
                    top_state <= TS_WAIT_FETCH;
                end
                TS_WAIT_FETCH: if (fetch_done) begin
                    if (is_p_frame || is_b_frame) begin
                        me_search_pass <= 2'd0;
                        ref_rd_bank_sel <= b_l0_ref_bank_w;
                        top_state <= TS_ME_START;
                    end else begin
                        is_inter_mb_reg <= 1'b0;
                        if (allow_idr_intra16_w)
                            top_state <= TS_I16_PRED;
                        else
                            top_state <= TS_MB_HDR;
                    end
                end

                // Motion estimation for P-frames
                TS_ME_START: begin
                    me_start <= 1'b1;
                    top_state <= TS_WAIT_ME;
                end
                TS_WAIT_ME: if (me_done) begin
                    if (is_b_frame && b_multi_ref_l0_enable_w && (valid_ref_count >= 3'd2) && (me_search_pass == 2'd0) && (valid_ref_count >= 3'd3)) begin
                        b_l0_pass_valid[0] <= 1'b1;
                        b_l0_pass_mvx[0] <= me_mvx_w;
                        b_l0_pass_mvy[0] <= me_mvy_w;
                        b_l0_pass_sad[0] <= me_sad_w;
                        b_l0_pass_ref_mb[0] <= me_ref_mb_w;
                        me_pass0_mvx <= me_mvx_w;
                        me_pass0_mvy <= me_mvy_w;
                        me_pass0_sad <= me_sad_w;
                        me_pass0_ref_mb <= me_ref_mb_w;
                        me_pass0_ref_idx <= 2'd0;
                        me_search_pass <= 2'd1;
                        ref_rd_bank_sel <= oldest_ref_bank;
                        top_state <= TS_ME_START;
                    end else if (is_b_frame && b_multi_ref_l0_enable_w && (valid_ref_count >= 3'd3) && (me_search_pass == 2'd1) && (valid_ref_count >= 3'd4)) begin
                        b_l0_pass_valid[1] <= 1'b1;
                        b_l0_pass_mvx[1] <= me_mvx_w;
                        b_l0_pass_mvy[1] <= me_mvy_w;
                        b_l0_pass_sad[1] <= me_sad_w;
                        b_l0_pass_ref_mb[1] <= me_ref_mb_w;
                        if (me_sad_w < me_pass0_sad) begin
                            me_pass0_mvx <= me_mvx_w;
                            me_pass0_mvy <= me_mvy_w;
                            me_pass0_sad <= me_sad_w;
                            me_pass0_ref_mb <= me_ref_mb_w;
                            me_pass0_ref_idx <= 2'd1;
                        end
                        me_search_pass <= 2'd2;
                        ref_rd_bank_sel <= ancient_ref_bank;
                        top_state <= TS_ME_START;
                    end else if (is_b_frame && b_multi_ref_l0_enable_w && (valid_ref_count >= 3'd3) && (me_search_pass == 2'd1)) begin
                        b_l0_pass_valid[1] <= 1'b1;
                        b_l0_pass_mvx[1] <= me_mvx_w;
                        b_l0_pass_mvy[1] <= me_mvy_w;
                        b_l0_pass_sad[1] <= me_sad_w;
                        b_l0_pass_ref_mb[1] <= me_ref_mb_w;
                        if (me_sad_w < me_pass0_sad) begin
                            me_pass0_mvx <= me_mvx_w;
                            me_pass0_mvy <= me_mvy_w;
                            me_pass0_sad <= me_sad_w;
                            me_pass0_ref_mb <= me_ref_mb_w;
                            me_pass0_ref_idx <= 2'd1;
                        end
                        me_search_pass <= b_l1_search_pass_w;
                        ref_rd_bank_sel <= newest_ref_bank;
                        top_state <= TS_ME_START;
                    end else if (is_b_frame && b_multi_ref_l0_enable_w && (valid_ref_count >= 3'd4) && (me_search_pass == 2'd2)) begin
                        b_l0_pass_valid[2] <= 1'b1;
                        b_l0_pass_mvx[2] <= me_mvx_w;
                        b_l0_pass_mvy[2] <= me_mvy_w;
                        b_l0_pass_sad[2] <= me_sad_w;
                        b_l0_pass_ref_mb[2] <= me_ref_mb_w;
                        if (me_sad_w < me_pass0_sad) begin
                            me_pass0_mvx <= me_mvx_w;
                            me_pass0_mvy <= me_mvy_w;
                            me_pass0_sad <= me_sad_w;
                            me_pass0_ref_mb <= me_ref_mb_w;
                            me_pass0_ref_idx <= 2'd2;
                        end
                        me_search_pass <= b_l1_search_pass_w;
                        ref_rd_bank_sel <= newest_ref_bank;
                        top_state <= TS_ME_START;
                    end else if (is_b_frame && (valid_ref_count >= 3'd2) && (me_search_pass == 2'd0)) begin
                        b_l0_pass_valid[0] <= 1'b1;
                        b_l0_pass_mvx[0] <= me_mvx_w;
                        b_l0_pass_mvy[0] <= me_mvy_w;
                        b_l0_pass_sad[0] <= me_sad_w;
                        b_l0_pass_ref_mb[0] <= me_ref_mb_w;
                        me_pass0_mvx <= me_mvx_w;
                        me_pass0_mvy <= me_mvy_w;
                        me_pass0_sad <= me_sad_w;
                        me_pass0_ref_mb <= me_ref_mb_w;
                        me_pass0_ref_idx <= 2'd0;
                        me_search_pass <= b_l1_search_pass_w;
                        ref_rd_bank_sel <= newest_ref_bank;
                        top_state <= TS_ME_START;
                    end else if (is_p_frame && (valid_ref_count >= 3'd2) && (me_search_pass == 2'd0)) begin
                        me_pass0_mvx <= me_mvx_w;
                        me_pass0_mvy <= me_mvy_w;
                        me_pass0_sad <= me_sad_w;
                        me_pass0_ref_mb <= me_ref_mb_w;
                        me_pass0_ref_idx <= 2'd0;
                        me_search_pass <= 2'd1;
                        ref_rd_bank_sel <= older_ref_bank;
                        top_state <= TS_ME_START;
                    end else if (is_p_frame && (valid_ref_count >= 3'd3) && (me_search_pass == 2'd1)) begin
                        if (me_sad_w < me_pass0_sad) begin
                            me_pass0_mvx <= me_mvx_w;
                            me_pass0_mvy <= me_mvy_w;
                            me_pass0_sad <= me_sad_w;
                            me_pass0_ref_mb <= me_ref_mb_w;
                            me_pass0_ref_idx <= 2'd1;
                        end
                        me_search_pass <= 2'd2;
                        ref_rd_bank_sel <= oldest_ref_bank;
                        top_state <= TS_ME_START;
                    end else if (is_p_frame && (valid_ref_count >= 3'd4) && (me_search_pass == 2'd2)) begin
                        if (me_sad_w < me_pass0_sad) begin
                            me_pass0_mvx <= me_mvx_w;
                            me_pass0_mvy <= me_mvy_w;
                            me_pass0_sad <= me_sad_w;
                            me_pass0_ref_mb <= me_ref_mb_w;
                            me_pass0_ref_idx <= 2'd2;
                        end
                        me_search_pass <= 2'd3;
                        ref_rd_bank_sel <= ancient_ref_bank;
                        top_state <= TS_ME_START;
                    end else begin : me_finalize
                        reg signed [7:0] sel_fullpel_mvx, sel_fullpel_mvy;
                        reg [17:0] sel_sad;
                        reg [256*BIT_DEPTH-1:0] sel_ref_mb;
                        reg [1:0] sel_ref_idx;
                        reg sel_is_b_l1;
                        reg sel_is_b_bi;
                        reg direct_candidate_active;
                        reg direct_force_active;
                        reg direct_use_l1;
                        reg direct_use_bi;
                        reg direct_from_col_l1;
                        reg [1:0] direct_ref_idx_l0;
                        reg [1:0] direct_ref_idx_l1;
                        reg signed [7:0] direct_mvx_l0, direct_mvy_l0;
                        reg signed [7:0] direct_mvx_l1, direct_mvy_l1;
                        integer bi_idx, bi_pred_sample, bi_orig_sample, bi_sad_i;
                        integer bi_pass_idx, bi_candidate_sad_i;
                        reg [256*BIT_DEPTH-1:0] bi_pred_buf_i;
                        reg [256*BIT_DEPTH-1:0] bi_candidate_buf_i;
                        reg signed [7:0] bi_mvp_x_l0, bi_mvp_y_l0, bi_mvp_x_l1, bi_mvp_y_l1;
                        reg signed [7:0] ax, ay, bx, by, cx, cy;
                        reg a_avail, b_avail, c_avail, d_avail;
                        reg a_match, b_match, c_match;
                        reg [1:0] match_cnt;
                        reg signed [7:0] med_x, med_y;

                        sel_is_b_l1 = 1'b0;
                        sel_is_b_bi = 1'b0;
                        direct_candidate_active = 1'b0;
                        direct_force_active = 1'b0;
                        direct_use_l1 = 1'b0;
                        direct_use_bi = 1'b0;
                        direct_from_col_l1 = 1'b0;
                        direct_ref_idx_l0 = 2'd0;
                        direct_ref_idx_l1 = 2'd0;
                        direct_mvx_l0 = 8'sd0;
                        direct_mvy_l0 = 8'sd0;
                        direct_mvx_l1 = 8'sd0;
                        direct_mvy_l1 = 8'sd0;
                        bi_pred_buf_i = {(256*BD){1'b0}};
                        bi_candidate_buf_i = {(256*BD){1'b0}};
                        bi_sad_i = 32'h7fffffff;
                        if (is_b_frame && !force_b_l0_in && (valid_ref_count >= 3'd2) && (me_search_pass == b_l1_search_pass_w)) begin
                            sel_fullpel_mvx = me_pass0_mvx;
                            sel_fullpel_mvy = me_pass0_mvy;
                            sel_sad = me_pass0_sad;
                            sel_ref_mb = me_pass0_ref_mb;
                            sel_ref_idx = me_pass0_ref_idx;
                            sel_is_b_l1 = 1'b0;
                            sel_is_b_bi = 1'b1;
                            ref_rd_bank_sel <= b_l0_ref_bank_from_idx(me_pass0_ref_idx);
                            for (bi_pass_idx = 0; bi_pass_idx < 3; bi_pass_idx = bi_pass_idx + 1) begin
                                if (b_l0_pass_valid[bi_pass_idx]) begin
                                    bi_candidate_sad_i = 0;
                                    bi_candidate_buf_i = {(256*BD){1'b0}};
                                    for (bi_idx = 0; bi_idx < 256; bi_idx = bi_idx + 1) begin
                                        bi_pred_sample = use_weighted_pred_w ?
                                            apply_luma_bi_weight(b_l0_pass_ref_mb[bi_pass_idx][bi_idx*BD +: BD],
                                                                 me_ref_mb_w[bi_idx*BD +: BD]) :
                                            ((b_l0_pass_ref_mb[bi_pass_idx][bi_idx*BD +: BD] +
                                              me_ref_mb_w[bi_idx*BD +: BD] + 1) >> 1);
                                        bi_candidate_buf_i[bi_idx*BD +: BD] = bi_pred_sample[BD-1:0];
                                        bi_orig_sample = fetched_luma[bi_idx*BD +: BD];
                                        if (bi_orig_sample >= bi_pred_sample)
                                            bi_candidate_sad_i = bi_candidate_sad_i + (bi_orig_sample - bi_pred_sample);
                                        else
                                            bi_candidate_sad_i = bi_candidate_sad_i + (bi_pred_sample - bi_orig_sample);
                                    end
                                    if (bi_candidate_sad_i < bi_sad_i) begin
                                        bi_sad_i = bi_candidate_sad_i;
                                        bi_pred_buf_i = bi_candidate_buf_i;
                                        sel_fullpel_mvx = b_l0_pass_mvx[bi_pass_idx];
                                        sel_fullpel_mvy = b_l0_pass_mvy[bi_pass_idx];
                                        sel_sad = b_l0_pass_sad[bi_pass_idx];
                                        sel_ref_mb = b_l0_pass_ref_mb[bi_pass_idx];
                                        sel_ref_idx = bi_pass_idx[1:0];
                                        ref_rd_bank_sel <= b_l0_ref_bank_from_idx(bi_pass_idx[1:0]);
                                    end
                                end
                            end
                        end else if (!force_b_l0_in && (valid_ref_count >= 3'd4) && (me_search_pass == 2'd3) && (me_sad_w < me_pass0_sad)) begin
                            sel_fullpel_mvx = me_mvx_w;
                            sel_fullpel_mvy = me_mvy_w;
                            sel_sad = me_sad_w;
                            sel_ref_mb = me_ref_mb_w;
                            sel_ref_idx = 2'd3;
                            ref_rd_bank_sel <= ancient_ref_bank;
                        end else if (!force_b_l0_in && (valid_ref_count >= 3'd3) && (me_search_pass == 2'd2) && (me_sad_w < me_pass0_sad)) begin
                            sel_fullpel_mvx = me_mvx_w;
                            sel_fullpel_mvy = me_mvy_w;
                            sel_sad = me_sad_w;
                            sel_ref_mb = me_ref_mb_w;
                            sel_ref_idx = 2'd2;
                            ref_rd_bank_sel <= oldest_ref_bank;
                        end else if (!force_b_l0_in && (valid_ref_count >= 3'd2) && (me_search_pass == 2'd1) && (me_sad_w < me_pass0_sad)) begin
                            sel_fullpel_mvx = me_mvx_w;
                            sel_fullpel_mvy = me_mvy_w;
                            sel_sad = me_sad_w;
                            sel_ref_mb = me_ref_mb_w;
                            sel_ref_idx = 2'd1;
                            ref_rd_bank_sel <= older_ref_bank;
                        end else if ((valid_ref_count >= 3'd2) && (me_search_pass != 2'd0)) begin
                            sel_fullpel_mvx = me_pass0_mvx;
                            sel_fullpel_mvy = me_pass0_mvy;
                            sel_sad = me_pass0_sad;
                            sel_ref_mb = me_pass0_ref_mb;
                            sel_ref_idx = me_pass0_ref_idx;
                            ref_rd_bank_sel <= (me_pass0_ref_idx == 2'd0) ? newest_ref_bank :
                                               (me_pass0_ref_idx == 2'd1) ? older_ref_bank :
                                               (me_pass0_ref_idx == 2'd2) ? oldest_ref_bank :
                                                                            ancient_ref_bank;
                        end else begin
                            sel_fullpel_mvx = me_mvx_w;
                            sel_fullpel_mvy = me_mvy_w;
                            sel_sad = me_sad_w;
                            sel_ref_mb = me_ref_mb_w;
                            sel_ref_idx = 2'd0;
                            ref_rd_bank_sel <= b_l0_ref_bank_w;
                        end

                        if (is_b_frame && (valid_ref_count >= 3'd2) && !force_b_l0_in) begin
                            if (direct_temporal_slice_mode_reg) begin
                                calc_b_direct16x16_temporal(
                                    direct_candidate_active,
                                    direct_use_l1, direct_use_bi,
                                    direct_from_col_l1,
                                    direct_ref_idx_l0, direct_ref_idx_l1,
                                    direct_mvx_l0, direct_mvy_l0,
                                    direct_mvx_l1, direct_mvy_l1
                                );
                            end else begin
                                direct_candidate_active = 1'b1;
                                calc_b_direct16x16(
                                    direct_use_l1, direct_use_bi,
                                    direct_ref_idx_l0, direct_ref_idx_l1,
                                    direct_mvx_l0, direct_mvy_l0,
                                    direct_mvx_l1, direct_mvy_l1
                                );
                            end
                            direct_force_active = force_b_direct_in && direct_candidate_active;
                        end

                        me_fullpel_mvx <= sel_fullpel_mvx;
                        me_fullpel_mvy <= sel_fullpel_mvy;
                        me_fullpel_best_sad <= sel_sad;
                        inter_pred_buf <= sel_ref_mb;
                        mb_ref_idx_reg <= sel_ref_idx;
                        mb_ref_idx_l1_reg <= 2'd0;
                        is_b_l1_mb_reg <= sel_is_b_l1;
                        is_b_bi_mb_reg <= sel_is_b_bi;
                        is_b_direct_mb_reg <= 1'b0;
                        is_b_direct_from_l1_reg <= 1'b0;
                        b_direct_pending_valid <= direct_candidate_active;
                        b_direct_pending_use_l1 <= direct_use_l1;
                        b_direct_pending_use_bi <= direct_use_bi;
                        b_direct_pending_from_col_l1 <= direct_from_col_l1;
                        b_direct_pending_ref_idx_l0 <= direct_ref_idx_l0;
                        b_direct_pending_ref_idx_l1 <= direct_ref_idx_l1;
                        b_direct_pending_mvx_l0 <= direct_mvx_l0;
                        b_direct_pending_mvy_l0 <= direct_mvy_l0;
                        b_direct_pending_mvx_l1 <= direct_mvx_l1;
                        b_direct_pending_mvy_l1 <= direct_mvy_l1;
                        b_direct_luma_pred_l0 <= {(256*BD){1'b0}};
                        b_direct_luma_sad_l0 <= 18'd0;
                        if (direct_force_active) begin
                            is_b_direct_mb_reg <= 1'b1;
                            is_b_direct_from_l1_reg <= direct_from_col_l1;
                            is_b_l1_mb_reg <= direct_use_l1;
                            is_b_bi_mb_reg <= direct_use_bi;
                            luma_fetch_started <= 1'b0;
                            luma_fetch_cnt <= 9'd0;
                            luma_f_row <= 5'd0;
                            luma_f_col <= 5'd0;
                            b_bi_luma_fetch_l1_phase <= 1'b0;
                            if (direct_use_bi) begin
                                mb_ref_idx_reg <= direct_ref_idx_l0;
                                mb_ref_idx_l1_reg <= direct_ref_idx_l1;
                                me_best_mvx <= direct_mvx_l0;
                                me_best_mvy <= direct_mvy_l0;
                                me_best_mvx_l0 <= direct_mvx_l0;
                                me_best_mvy_l0 <= direct_mvy_l0;
                                me_best_mvx_l1 <= direct_mvx_l1;
                                me_best_mvy_l1 <= direct_mvy_l1;
                                me_best_sad <= 18'd0;
                                me_fullpel_mvx <= $signed(direct_mvx_l0) >>> 2;
                                me_fullpel_mvy <= $signed(direct_mvy_l0) >>> 2;
                                me_fullpel_best_sad <= 18'd0;
                                mvp_x <= direct_mvx_l0;
                                mvp_y <= direct_mvy_l0;
                                mvp_x_l0 <= direct_mvx_l0;
                                mvp_y_l0 <= direct_mvy_l0;
                                mvp_x_l1 <= direct_mvx_l1;
                                mvp_y_l1 <= direct_mvy_l1;
                                ref_rd_bank_sel <= b_l0_ref_bank_from_idx(direct_ref_idx_l0);
                            end else if (direct_use_l1) begin
                                mb_ref_idx_reg <= direct_ref_idx_l1;
                                mb_ref_idx_l1_reg <= 2'd0;
                                me_best_mvx <= direct_mvx_l1;
                                me_best_mvy <= direct_mvy_l1;
                                me_best_mvx_l0 <= 8'sd0;
                                me_best_mvy_l0 <= 8'sd0;
                                me_best_mvx_l1 <= direct_mvx_l1;
                                me_best_mvy_l1 <= direct_mvy_l1;
                                me_best_sad <= 18'd0;
                                me_fullpel_mvx <= $signed(direct_mvx_l1) >>> 2;
                                me_fullpel_mvy <= $signed(direct_mvy_l1) >>> 2;
                                me_fullpel_best_sad <= 18'd0;
                                mvp_x <= direct_mvx_l1;
                                mvp_y <= direct_mvy_l1;
                                mvp_x_l0 <= 8'sd0;
                                mvp_y_l0 <= 8'sd0;
                                mvp_x_l1 <= direct_mvx_l1;
                                mvp_y_l1 <= direct_mvy_l1;
                                ref_rd_bank_sel <= newest_ref_bank;
                            end else begin
                                mb_ref_idx_reg <= direct_ref_idx_l0;
                                mb_ref_idx_l1_reg <= 2'd0;
                                me_best_mvx <= direct_mvx_l0;
                                me_best_mvy <= direct_mvy_l0;
                                me_best_mvx_l0 <= direct_mvx_l0;
                                me_best_mvy_l0 <= direct_mvy_l0;
                                me_best_mvx_l1 <= 8'sd0;
                                me_best_mvy_l1 <= 8'sd0;
                                me_best_sad <= 18'd0;
                                me_fullpel_mvx <= $signed(direct_mvx_l0) >>> 2;
                                me_fullpel_mvy <= $signed(direct_mvy_l0) >>> 2;
                                me_fullpel_best_sad <= 18'd0;
                                mvp_x <= direct_mvx_l0;
                                mvp_y <= direct_mvy_l0;
                                mvp_x_l0 <= direct_mvx_l0;
                                mvp_y_l0 <= direct_mvy_l0;
                                mvp_x_l1 <= 8'sd0;
                                mvp_y_l1 <= 8'sd0;
                                ref_rd_bank_sel <= b_l0_ref_bank_from_idx(direct_ref_idx_l0);
                            end
                            top_state <= TS_LUMA_FETCH;
                        end else if (sel_is_b_bi) begin
                            calc_inter_mvp(1'b0, sel_ref_idx, bi_mvp_x_l0, bi_mvp_y_l0);
                            calc_inter_mvp(1'b1, 2'd0, bi_mvp_x_l1, bi_mvp_y_l1);
                            me_best_mvx <= (sel_fullpel_mvx <<< 2);
                            me_best_mvy <= (sel_fullpel_mvy <<< 2);
                            me_best_mvx_l0 <= (sel_fullpel_mvx <<< 2);
                            me_best_mvy_l0 <= (sel_fullpel_mvy <<< 2);
                            me_best_mvx_l1 <= (me_mvx_w <<< 2);
                            me_best_mvy_l1 <= (me_mvy_w <<< 2);
                            me_best_sad <= bi_sad_i[17:0];
                            b_bi_fullpel_ref_l1 <= me_ref_mb_w;
                            b_bi_fullpel_sad_l1 <= me_sad_w;
                            b_bi_luma_fetch_l1_phase <= 1'b0;
                            mvp_x <= bi_mvp_x_l0;
                            mvp_y <= bi_mvp_y_l0;
                            mvp_x_l0 <= bi_mvp_x_l0;
                            mvp_y_l0 <= bi_mvp_y_l0;
                            mvp_x_l1 <= bi_mvp_x_l1;
                            mvp_y_l1 <= bi_mvp_y_l1;
                            b_bi_mvp_x_l0_reg <= bi_mvp_x_l0;
                            b_bi_mvp_y_l0_reg <= bi_mvp_y_l0;
                            b_bi_mvp_x_l1_reg <= bi_mvp_x_l1;
                            b_bi_mvp_y_l1_reg <= bi_mvp_y_l1;
                            luma_fetch_started <= 1'b0;
                            luma_fetch_cnt <= 9'd0;
                            luma_f_row <= 5'd0;
                            luma_f_col <= 5'd0;
                            me_fullpel_mvx <= sel_fullpel_mvx;
                            me_fullpel_mvy <= sel_fullpel_mvy;
                            me_fullpel_best_sad <= sel_sad;
                            inter_pred_buf <= sel_ref_mb;
                            ref_rd_bank_sel <= b_l0_ref_bank_from_idx(sel_ref_idx);
                            top_state <= TS_LUMA_FETCH;
                        end else begin
                            luma_fetch_started <= 1'b0;
                            luma_fetch_cnt <= 9'd0;
                            luma_f_row <= 5'd0;
                            luma_f_col <= 5'd0;
                            top_state <= TS_LUMA_FETCH;
                        end
                    end
                end

                TS_LUMA_FETCH: begin
                    if (!luma_fetch_started) begin
                        luma_fetch_started <= 1'b1;
                    end else if (luma_f_row < LUMA_RAW_ROWS[4:0]) begin
                        luma_raw[luma_fetch_cnt*BD +: BD] <= ref_mem_rd_data;
                        luma_fetch_cnt <= luma_fetch_cnt + 9'd1;
                        if (luma_f_col + 5'd1 >= LUMA_RAW_COLS[4:0]) begin
                            luma_f_col <= 5'd0;
                            luma_f_row <= luma_f_row + 5'd1;
                        end else begin
                            luma_f_col <= luma_f_col + 5'd1;
                        end
                    end else begin : luma_refine
                        integer cand_dx, cand_dy, px, py;
                        integer cand_sad, pred_sample, comp_sample, ref1_sample, ref2_sample, orig_sample, pskip_idx;
                        integer best_sad_i, best_dx_i, best_dy_i;
                        integer bi_final_idx, bi_final_sample, bi_final_orig_sample, bi_final_sad_i;
                        integer direct_sad_i;
                        integer direct_final_sad_i;
                        integer direct_auto_bias_i;
                        integer direct_final_idx, direct_final_sample, direct_final_orig_sample;
                        integer frac_x_i, frac_y_i, base_x_i, base_y_i;
                        reg [3:0] qpel_idx_i;
                        reg [1:0] ref0_plane_i, ref1_plane_i;
                        reg [256*BIT_DEPTH-1:0] best_pred_buf_i;
                        reg [256*BIT_DEPTH-1:0] cand_pred_buf_i;
                        reg [256*BIT_DEPTH-1:0] bi_final_pred_buf_i;
                        reg [256*BIT_DEPTH-1:0] direct_pred_buf_i;
                        reg [256*BIT_DEPTH-1:0] direct_final_pred_buf_i;
                        reg signed [7:0] ax, ay, bx, by, cx, cy;
                        reg a_avail, b_avail, c_avail, d_avail;
                        reg a_match, b_match, c_match;
                        reg [1:0] match_cnt;
                        reg signed [7:0] med_x, med_y;
                        reg signed [7:0] sel_mvp_x, sel_mvp_y;
                        reg signed [7:0] pskip_x, pskip_y;
                        reg pskip_a_match, pskip_b_match, pskip_c_match, pskip_luma_exact;
                        reg [1:0] pskip_match_cnt;
                        reg signed [7:0] pskip_med_x, pskip_med_y;

                        best_sad_i = me_fullpel_best_sad;
                        best_dx_i = 0;
                        best_dy_i = 0;
                        best_pred_buf_i = inter_pred_buf;

                        for (cand_dy = -2; cand_dy <= 2; cand_dy = cand_dy + 1) begin
                            for (cand_dx = -2; cand_dx <= 2; cand_dx = cand_dx + 1) begin
                                frac_x_i = cand_dx & 3;
                                frac_y_i = cand_dy & 3;
                                base_x_i = 3 + (cand_dx >>> 2);
                                base_y_i = 3 + (cand_dy >>> 2);
                                qpel_idx_i = ((frac_y_i & 3) << 2) | (frac_x_i & 3);
                                ref0_plane_i = qpel_ref0_plane(qpel_idx_i);
                                ref1_plane_i = qpel_ref1_plane(qpel_idx_i);
                                cand_sad = 0;
                                cand_pred_buf_i = {(256*BD){1'b0}};

                                for (py = 0; py < 16; py = py + 1) begin
                                    for (px = 0; px < 16; px = px + 1) begin
                                        ref1_sample = qpel_plane_sample(
                                            ref0_plane_i,
                                            base_x_i + px,
                                            base_y_i + py + ((frac_y_i == 3) ? 1 : 0)
                                        );
                                        if (qpel_idx_i & 4'b0101) begin
                                            ref2_sample = qpel_plane_sample(
                                                ref1_plane_i,
                                                base_x_i + px + ((frac_x_i == 3) ? 1 : 0),
                                                base_y_i + py
                                            );
                                            pred_sample = (ref1_sample + ref2_sample + 1) >>> 1;
                                        end else begin
                                            pred_sample = ref1_sample;
                                        end
                                        cand_pred_buf_i[((py*16)+px)*BD +: BD] = pred_sample[BD-1:0];
                                        comp_sample = use_post_weighted_pred_w ? apply_luma_weight(pred_sample[BD-1:0]) : pred_sample;
                                        orig_sample = fetched_luma[((py*16)+px)*BD +: BD];
                                        if (orig_sample >= comp_sample)
                                            cand_sad = cand_sad + (orig_sample - comp_sample);
                                        else
                                            cand_sad = cand_sad + (comp_sample - orig_sample);
                                    end
                                end

                                if (cand_sad < best_sad_i) begin
                                    best_sad_i = cand_sad;
                                    best_dx_i = cand_dx;
                                    best_dy_i = cand_dy;
                                    best_pred_buf_i = cand_pred_buf_i;
                                end
                            end
                        end

                        // The current CABAC P_L0_16x16 subset owns zero-MVD syntax.
                        // Keep that path on the full-pel predictor so nonzero residuals
                        // can exercise CABAC CBP/residual bins without falling into the
                        // still-unimplemented nonzero CABAC MVD lane.
                        if ((ENABLE_CABAC_P16X16_FULLPEL_ONLY != 0) &&
                            cabac_p16x16_enable_w && is_p_frame && !use_weighted_pred_w &&
                            (slice_num_ref_idx_l0_active_minus1 == 2'd0) &&
                            (mb_ref_idx_reg == 2'd0)) begin
                            best_sad_i = me_fullpel_best_sad;
                            best_dx_i = 0;
                            best_dy_i = 0;
                            best_pred_buf_i = inter_pred_buf;
                        end

                        me_best_mvx <= (me_fullpel_mvx <<< 2) + best_dx_i;
                        me_best_mvy <= (me_fullpel_mvy <<< 2) + best_dy_i;
                        me_best_sad <= best_sad_i;
                        inter_pred_buf <= best_pred_buf_i;
                        is_inter_mb_reg <= (best_sad_i < INTER_SAD_THRESHOLD);
                        if (is_b_frame && is_b_direct_mb_reg) begin
                            if (is_b_bi_mb_reg) begin
                                if (!b_bi_luma_fetch_l1_phase) begin
                                    build_exact_luma_pred(me_best_mvx_l0, me_best_mvy_l0, direct_pred_buf_i, direct_sad_i);
                                    b_bi_luma_pred_l0 <= direct_pred_buf_i;
                                    b_bi_luma_sad_l0 <= direct_sad_i[17:0];
                                    me_fullpel_mvx <= $signed(me_best_mvx_l1) >>> 2;
                                    me_fullpel_mvy <= $signed(me_best_mvy_l1) >>> 2;
                                    b_bi_luma_fetch_l1_phase <= 1'b1;
                                    luma_fetch_started <= 1'b0;
                                    luma_fetch_cnt <= 9'd0;
                                    luma_f_row <= 5'd0;
                                    luma_f_col <= 5'd0;
                                    ref_rd_bank_sel <= newest_ref_bank;
                                    top_state <= TS_LUMA_FETCH;
                                end else begin
                                    build_exact_luma_pred(me_best_mvx_l1, me_best_mvy_l1, direct_pred_buf_i, direct_sad_i);
                                    bi_final_sad_i = 0;
                                    bi_final_pred_buf_i = {(256*BD){1'b0}};
                                    for (bi_final_idx = 0; bi_final_idx < 256; bi_final_idx = bi_final_idx + 1) begin
                                        bi_final_sample = use_weighted_pred_w ?
                                            apply_luma_bi_weight(b_bi_luma_pred_l0[bi_final_idx*BD +: BD],
                                                                 direct_pred_buf_i[bi_final_idx*BD +: BD]) :
                                            ((b_bi_luma_pred_l0[bi_final_idx*BD +: BD] +
                                              direct_pred_buf_i[bi_final_idx*BD +: BD] + 1) >>> 1);
                                        bi_final_pred_buf_i[bi_final_idx*BD +: BD] = bi_final_sample[BD-1:0];
                                        bi_final_orig_sample = fetched_luma[bi_final_idx*BD +: BD];
                                        if (bi_final_orig_sample >= bi_final_sample)
                                            bi_final_sad_i = bi_final_sad_i + (bi_final_orig_sample - bi_final_sample);
                                        else
                                            bi_final_sad_i = bi_final_sad_i + (bi_final_sample - bi_final_orig_sample);
                                    end
                                    b_bi_luma_fetch_l1_phase <= 1'b0;
                                    me_best_mvx <= me_best_mvx_l0;
                                    me_best_mvy <= me_best_mvy_l0;
                                    me_best_sad <= bi_final_sad_i[17:0];
                                    inter_pred_buf <= bi_final_pred_buf_i;
                                    is_inter_mb_reg <= 1'b1;
                                    is_b_l1_mb_reg <= 1'b0;
                                    is_b_bi_mb_reg <= 1'b1;
                                    is_b_direct_mb_reg <= 1'b1;
                                    bskip_syntax_eligible_reg <= 1'b1;
                                    mvp_x <= me_best_mvx_l0;
                                    mvp_y <= me_best_mvy_l0;
                                    mvp_x_l0 <= me_best_mvx_l0;
                                    mvp_y_l0 <= me_best_mvy_l0;
                                    mvp_x_l1 <= me_best_mvx_l1;
                                    mvp_y_l1 <= me_best_mvy_l1;
                                    ref_rd_bank_sel <= b_l0_ref_bank_from_idx(mb_ref_idx_reg);
                                    use_intra16_mb_reg <= 1'b0;
                                    use_ipcm_mb_reg <= 1'b0;
                                    if (bi_final_sad_i == 0) begin
                                        skip_probe_pending <= 1'b1;
                                        chr_fetch_cnt <= {CHR_FETCH_W{1'b0}};
                                        chr_fetch_started <= 1'b0;
                                        chr_raw_cb <= {(CHR_RAW_SAMPLES*BD){1'b0}};
                                        chr_raw_cr <= {(CHR_RAW_SAMPLES*BD){1'b0}};
                                        chr_f_row <= 5'd0;
                                        chr_f_col <= {CHR_FETCH_COL_W{1'b0}};
                                        b_bi_chr_fetch_l1_phase <= 1'b0;
                                        chr_frac_x <= me_best_mvx_l0[2:0];
                                        chr_frac_y <= me_best_mvy_l0[2:0];
                                        chr_fetch_cols <= (me_best_mvx_l0[2:0] != 3'd0) ? (CHR_MB_WIDTH[CHR_FETCH_COL_W-1:0] + {{(CHR_FETCH_COL_W-1){1'b0}}, 1'b1}) : CHR_MB_WIDTH[CHR_FETCH_COL_W-1:0];
                                        chr_fetch_rows <= (me_best_mvy_l0[2:0] != 3'd0) ? (CHR_MB_HEIGHT[4:0] + 5'd1) : CHR_MB_HEIGHT[4:0];
                                        top_state <= TS_CHR_FETCH;
                                    end else begin
                                        top_state <= TS_MB_HDR;
                                    end
                                end
                            end else begin
                                build_exact_luma_pred(me_best_mvx, me_best_mvy, direct_pred_buf_i, direct_sad_i);
                                if (is_b_l1_mb_reg) begin
                                    me_best_mvx <= me_best_mvx_l1;
                                    me_best_mvy <= me_best_mvy_l1;
                                    mvp_x <= me_best_mvx_l1;
                                    mvp_y <= me_best_mvy_l1;
                                    mvp_x_l1 <= me_best_mvx_l1;
                                    mvp_y_l1 <= me_best_mvy_l1;
                                end else begin
                                    me_best_mvx <= me_best_mvx_l0;
                                    me_best_mvy <= me_best_mvy_l0;
                                    mvp_x <= me_best_mvx_l0;
                                    mvp_y <= me_best_mvy_l0;
                                    mvp_x_l0 <= me_best_mvx_l0;
                                    mvp_y_l0 <= me_best_mvy_l0;
                                end
                                me_best_sad <= direct_sad_i[17:0];
                                inter_pred_buf <= direct_pred_buf_i;
                                is_inter_mb_reg <= 1'b1;
                                is_b_direct_mb_reg <= 1'b1;
                                bskip_syntax_eligible_reg <= 1'b1;
                                if (is_b_l1_mb_reg)
                                    ref_rd_bank_sel <= newest_ref_bank;
                                else
                                    ref_rd_bank_sel <= b_l0_ref_bank_from_idx(mb_ref_idx_reg);
                                use_intra16_mb_reg <= 1'b0;
                                use_ipcm_mb_reg <= 1'b0;
                                if (direct_sad_i == 0) begin
                                    skip_probe_pending <= 1'b1;
                                    chr_fetch_cnt <= {CHR_FETCH_W{1'b0}};
                                    chr_fetch_started <= 1'b0;
                                    chr_raw_cb <= {(CHR_RAW_SAMPLES*BD){1'b0}};
                                    chr_raw_cr <= {(CHR_RAW_SAMPLES*BD){1'b0}};
                                    chr_f_row <= 5'd0;
                                    chr_f_col <= {CHR_FETCH_COL_W{1'b0}};
                                    b_bi_chr_fetch_l1_phase <= 1'b0;
                                    chr_frac_x <= is_b_l1_mb_reg ? me_best_mvx_l1[2:0] : me_best_mvx_l0[2:0];
                                    chr_frac_y <= is_b_l1_mb_reg ? me_best_mvy_l1[2:0] : me_best_mvy_l0[2:0];
                                    chr_fetch_cols <= ((is_b_l1_mb_reg ? me_best_mvx_l1[2:0] : me_best_mvx_l0[2:0]) != 3'd0) ? (CHR_MB_WIDTH[CHR_FETCH_COL_W-1:0] + {{(CHR_FETCH_COL_W-1){1'b0}}, 1'b1}) : CHR_MB_WIDTH[CHR_FETCH_COL_W-1:0];
                                    chr_fetch_rows <= ((is_b_l1_mb_reg ? me_best_mvy_l1[2:0] : me_best_mvy_l0[2:0]) != 3'd0) ? (CHR_MB_HEIGHT[4:0] + 5'd1) : CHR_MB_HEIGHT[4:0];
                                    top_state <= TS_CHR_FETCH;
                                end else begin
                                    top_state <= TS_MB_HDR;
                                end
                            end
                        end else if (is_b_frame && is_b_bi_mb_reg) begin
                            if (!b_bi_luma_fetch_l1_phase) begin
                                me_best_mvx_l0 <= (me_fullpel_mvx <<< 2) + best_dx_i;
                                me_best_mvy_l0 <= (me_fullpel_mvy <<< 2) + best_dy_i;
                                b_bi_luma_pred_l0 <= best_pred_buf_i;
                                b_bi_luma_sad_l0 <= best_sad_i;
                                if (b_direct_pending_valid && !b_direct_pending_use_l1) begin
                                    build_exact_luma_pred(b_direct_pending_mvx_l0, b_direct_pending_mvy_l0, direct_pred_buf_i, direct_sad_i);
                                    b_direct_luma_pred_l0 <= direct_pred_buf_i;
                                    b_direct_luma_sad_l0 <= direct_sad_i[17:0];
                                end else begin
                                    b_direct_luma_pred_l0 <= {(256*BD){1'b0}};
                                    b_direct_luma_sad_l0 <= 18'h3ffff;
                                end
                                me_fullpel_mvx <= $signed(me_best_mvx_l1) >>> 2;
                                me_fullpel_mvy <= $signed(me_best_mvy_l1) >>> 2;
                                me_fullpel_best_sad <= b_bi_fullpel_sad_l1;
                                inter_pred_buf <= b_bi_fullpel_ref_l1;
                                b_bi_luma_fetch_l1_phase <= 1'b1;
                                luma_fetch_started <= 1'b0;
                                luma_fetch_cnt <= 9'd0;
                                luma_f_row <= 5'd0;
                                luma_f_col <= 5'd0;
                                ref_rd_bank_sel <= newest_ref_bank;
                                top_state <= TS_LUMA_FETCH;
                            end else begin
                                bi_final_sad_i = 0;
                                bi_final_pred_buf_i = {(256*BD){1'b0}};
                                for (bi_final_idx = 0; bi_final_idx < 256; bi_final_idx = bi_final_idx + 1) begin
                                    bi_final_sample = use_weighted_pred_w ?
                                        apply_luma_bi_weight(b_bi_luma_pred_l0[bi_final_idx*BD +: BD],
                                                             best_pred_buf_i[bi_final_idx*BD +: BD]) :
                                        ((b_bi_luma_pred_l0[bi_final_idx*BD +: BD] +
                                          best_pred_buf_i[bi_final_idx*BD +: BD] + 1) >>> 1);
                                    bi_final_pred_buf_i[bi_final_idx*BD +: BD] = bi_final_sample[BD-1:0];
                                    bi_final_orig_sample = fetched_luma[bi_final_idx*BD +: BD];
                                    if (bi_final_orig_sample >= bi_final_sample)
                                        bi_final_sad_i = bi_final_sad_i + (bi_final_orig_sample - bi_final_sample);
                                    else
                                        bi_final_sad_i = bi_final_sad_i + (bi_final_sample - bi_final_orig_sample);
                                end

                                b_bi_luma_fetch_l1_phase <= 1'b0;
                                direct_final_sad_i = 32'h7fffffff;
                                direct_auto_bias_i = 0;
                                direct_final_pred_buf_i = {(256*BD){1'b0}};
                                if (b_direct_pending_valid) begin
                                    if (b_direct_pending_use_bi) begin
                                        build_exact_luma_pred(b_direct_pending_mvx_l1, b_direct_pending_mvy_l1, direct_pred_buf_i, direct_sad_i);
                                        direct_final_sad_i = 0;
                                        for (direct_final_idx = 0; direct_final_idx < 256; direct_final_idx = direct_final_idx + 1) begin
                                            direct_final_sample = use_weighted_pred_w ?
                                                apply_luma_bi_weight(b_direct_luma_pred_l0[direct_final_idx*BD +: BD],
                                                                     direct_pred_buf_i[direct_final_idx*BD +: BD]) :
                                                ((b_direct_luma_pred_l0[direct_final_idx*BD +: BD] +
                                                  direct_pred_buf_i[direct_final_idx*BD +: BD] + 1) >>> 1);
                                            direct_final_pred_buf_i[direct_final_idx*BD +: BD] = direct_final_sample[BD-1:0];
                                            direct_final_orig_sample = fetched_luma[direct_final_idx*BD +: BD];
                                            if (direct_final_orig_sample >= direct_final_sample)
                                                direct_final_sad_i = direct_final_sad_i + (direct_final_orig_sample - direct_final_sample);
                                            else
                                                direct_final_sad_i = direct_final_sad_i + (direct_final_sample - direct_final_orig_sample);
                                        end
                                    end else if (b_direct_pending_use_l1) begin
                                        build_exact_luma_pred(b_direct_pending_mvx_l1, b_direct_pending_mvy_l1, direct_final_pred_buf_i, direct_final_sad_i);
                                    end else begin
                                        direct_final_pred_buf_i = b_direct_luma_pred_l0;
                                        direct_final_sad_i = b_direct_luma_sad_l0;
                                    end
                                    if (direct_temporal_slice_mode_reg &&
                                        b_direct_pending_use_bi &&
                                        (b_direct_pending_ref_idx_l0 != 2'd0))
                                        direct_auto_bias_i = (INTER_SAD_THRESHOLD << 1);
                                end

                                if (b_direct_pending_valid &&
                                    (direct_final_sad_i < (INTER_SAD_THRESHOLD + direct_auto_bias_i)) &&
                                    (direct_final_sad_i <= (bi_final_sad_i + direct_auto_bias_i)) &&
                                    (direct_final_sad_i <= (best_sad_i + direct_auto_bias_i)) &&
                                    (direct_final_sad_i <= (b_bi_luma_sad_l0 + direct_auto_bias_i))) begin
                                    if (b_direct_pending_use_bi) begin
                                        me_best_mvx <= b_direct_pending_mvx_l0;
                                        me_best_mvy <= b_direct_pending_mvy_l0;
                                        me_best_mvx_l0 <= b_direct_pending_mvx_l0;
                                        me_best_mvy_l0 <= b_direct_pending_mvy_l0;
                                        me_best_mvx_l1 <= b_direct_pending_mvx_l1;
                                        me_best_mvy_l1 <= b_direct_pending_mvy_l1;
                                        mb_ref_idx_reg <= b_direct_pending_ref_idx_l0;
                                        mb_ref_idx_l1_reg <= b_direct_pending_ref_idx_l1;
                                        mvp_x <= b_direct_pending_mvx_l0;
                                        mvp_y <= b_direct_pending_mvy_l0;
                                        mvp_x_l0 <= b_direct_pending_mvx_l0;
                                        mvp_y_l0 <= b_direct_pending_mvy_l0;
                                        mvp_x_l1 <= b_direct_pending_mvx_l1;
                                        mvp_y_l1 <= b_direct_pending_mvy_l1;
                                        ref_rd_bank_sel <= b_l0_ref_bank_from_idx(b_direct_pending_ref_idx_l0);
                                    end else if (b_direct_pending_use_l1) begin
                                        me_best_mvx <= b_direct_pending_mvx_l1;
                                        me_best_mvy <= b_direct_pending_mvy_l1;
                                        me_best_mvx_l0 <= 8'sd0;
                                        me_best_mvy_l0 <= 8'sd0;
                                        me_best_mvx_l1 <= b_direct_pending_mvx_l1;
                                        me_best_mvy_l1 <= b_direct_pending_mvy_l1;
                                        mb_ref_idx_reg <= b_direct_pending_ref_idx_l1;
                                        mb_ref_idx_l1_reg <= 2'd0;
                                        mvp_x <= b_direct_pending_mvx_l1;
                                        mvp_y <= b_direct_pending_mvy_l1;
                                        mvp_x_l0 <= 8'sd0;
                                        mvp_y_l0 <= 8'sd0;
                                        mvp_x_l1 <= b_direct_pending_mvx_l1;
                                        mvp_y_l1 <= b_direct_pending_mvy_l1;
                                        ref_rd_bank_sel <= newest_ref_bank;
                                    end else begin
                                        me_best_mvx <= b_direct_pending_mvx_l0;
                                        me_best_mvy <= b_direct_pending_mvy_l0;
                                        me_best_mvx_l0 <= b_direct_pending_mvx_l0;
                                        me_best_mvy_l0 <= b_direct_pending_mvy_l0;
                                        me_best_mvx_l1 <= 8'sd0;
                                        me_best_mvy_l1 <= 8'sd0;
                                        mb_ref_idx_reg <= b_direct_pending_ref_idx_l0;
                                        mb_ref_idx_l1_reg <= 2'd0;
                                        mvp_x <= b_direct_pending_mvx_l0;
                                        mvp_y <= b_direct_pending_mvy_l0;
                                        mvp_x_l0 <= b_direct_pending_mvx_l0;
                                        mvp_y_l0 <= b_direct_pending_mvy_l0;
                                        mvp_x_l1 <= 8'sd0;
                                        mvp_y_l1 <= 8'sd0;
                                        ref_rd_bank_sel <= b_l0_ref_bank_from_idx(b_direct_pending_ref_idx_l0);
                                    end
                                    me_best_sad <= direct_final_sad_i[17:0];
                                    inter_pred_buf <= direct_final_pred_buf_i;
                                    is_inter_mb_reg <= 1'b1;
                                    is_b_l1_mb_reg <= b_direct_pending_use_l1;
                                    is_b_bi_mb_reg <= b_direct_pending_use_bi;
                                    is_b_direct_mb_reg <= 1'b1;
                                    is_b_direct_from_l1_reg <= b_direct_pending_from_col_l1;
                                    bskip_syntax_eligible_reg <= 1'b1;
                                    b_direct_pending_valid <= 1'b0;
                                    use_intra16_mb_reg <= 1'b0;
                                    use_ipcm_mb_reg <= 1'b0;
                                    if (direct_final_sad_i == 0) begin
                                        skip_probe_pending <= 1'b1;
                                        chr_fetch_cnt <= {CHR_FETCH_W{1'b0}};
                                        chr_fetch_started <= 1'b0;
                                        chr_raw_cb <= {(CHR_RAW_SAMPLES*BD){1'b0}};
                                        chr_raw_cr <= {(CHR_RAW_SAMPLES*BD){1'b0}};
                                        chr_f_row <= 5'd0;
                                        chr_f_col <= {CHR_FETCH_COL_W{1'b0}};
                                        b_bi_chr_fetch_l1_phase <= 1'b0;
                                        chr_frac_x <= b_direct_pending_use_bi ? b_direct_pending_mvx_l0[2:0] :
                                                      (b_direct_pending_use_l1 ? b_direct_pending_mvx_l1[2:0] : b_direct_pending_mvx_l0[2:0]);
                                        chr_frac_y <= b_direct_pending_use_bi ? b_direct_pending_mvy_l0[2:0] :
                                                      (b_direct_pending_use_l1 ? b_direct_pending_mvy_l1[2:0] : b_direct_pending_mvy_l0[2:0]);
                                        chr_fetch_cols <= ((b_direct_pending_use_bi ? b_direct_pending_mvx_l0[2:0] :
                                                           (b_direct_pending_use_l1 ? b_direct_pending_mvx_l1[2:0] : b_direct_pending_mvx_l0[2:0])) != 3'd0) ? (CHR_MB_WIDTH[CHR_FETCH_COL_W-1:0] + {{(CHR_FETCH_COL_W-1){1'b0}}, 1'b1}) : CHR_MB_WIDTH[CHR_FETCH_COL_W-1:0];
                                        chr_fetch_rows <= ((b_direct_pending_use_bi ? b_direct_pending_mvy_l0[2:0] :
                                                           (b_direct_pending_use_l1 ? b_direct_pending_mvy_l1[2:0] : b_direct_pending_mvy_l0[2:0])) != 3'd0) ? (CHR_MB_HEIGHT[4:0] + 5'd1) : CHR_MB_HEIGHT[4:0];
                                        top_state <= TS_CHR_FETCH;
                                    end else begin
                                        top_state <= TS_MB_HDR;
                                    end
                                end else if (!force_b_l0_in && !force_b_l1_in &&
                                               (force_b_bi_in || ((bi_final_sad_i <= b_bi_luma_sad_l0) && (bi_final_sad_i <= best_sad_i)))) begin
                                    me_best_mvx <= me_best_mvx_l0;
                                    me_best_mvy <= me_best_mvy_l0;
                                    me_best_mvx_l1 <= (me_fullpel_mvx <<< 2) + best_dx_i;
                                    me_best_mvy_l1 <= (me_fullpel_mvy <<< 2) + best_dy_i;
                                    me_best_sad <= bi_final_sad_i;
                                    inter_pred_buf <= bi_final_pred_buf_i;
                                    is_inter_mb_reg <= (bi_final_sad_i < INTER_SAD_THRESHOLD);
                                    is_b_l1_mb_reg <= 1'b0;
                                    is_b_bi_mb_reg <= 1'b1;
                                    is_b_direct_mb_reg <= 1'b0;
                                    is_b_direct_from_l1_reg <= 1'b0;
                                    mvp_x <= b_bi_mvp_x_l0_reg;
                                    mvp_y <= b_bi_mvp_y_l0_reg;
                                    mvp_x_l0 <= b_bi_mvp_x_l0_reg;
                                    mvp_y_l0 <= b_bi_mvp_y_l0_reg;
                                    mvp_x_l1 <= b_bi_mvp_x_l1_reg;
                                    mvp_y_l1 <= b_bi_mvp_y_l1_reg;
                                    ref_rd_bank_sel <= b_l0_ref_bank_from_idx(mb_ref_idx_reg);
                                    b_direct_pending_valid <= 1'b0;
                                    if (bi_final_sad_i < INTER_SAD_THRESHOLD) begin
                                        use_intra16_mb_reg <= 1'b0;
                                        use_ipcm_mb_reg <= 1'b0;
                                        top_state <= TS_MB_HDR;
                                    end else begin
                                        is_b_bi_mb_reg <= 1'b0;
                                        use_intra16_mb_reg <= 1'b0;
                                        use_ipcm_mb_reg <= (ENABLE_P_IPCM != 0);
                                        top_state <= TS_MB_HDR;
                                    end
                                end else if (!force_b_l0_in && (force_b_l1_in || (best_sad_i < b_bi_luma_sad_l0))) begin
                                    mb_ref_idx_reg <= 2'd0;
                                    mb_ref_idx_l1_reg <= 2'd0;
                                    me_best_mvx <= (me_fullpel_mvx <<< 2) + best_dx_i;
                                    me_best_mvy <= (me_fullpel_mvy <<< 2) + best_dy_i;
                                    me_best_mvx_l0 <= 8'sd0;
                                    me_best_mvy_l0 <= 8'sd0;
                                    me_best_mvx_l1 <= (me_fullpel_mvx <<< 2) + best_dx_i;
                                    me_best_mvy_l1 <= (me_fullpel_mvy <<< 2) + best_dy_i;
                                    me_best_sad <= best_sad_i;
                                    inter_pred_buf <= best_pred_buf_i;
                                    is_inter_mb_reg <= (best_sad_i < INTER_SAD_THRESHOLD);
                                    is_b_l1_mb_reg <= 1'b1;
                                    is_b_bi_mb_reg <= 1'b0;
                                    is_b_direct_mb_reg <= 1'b0;
                                    is_b_direct_from_l1_reg <= 1'b0;
                                    mvp_x <= b_bi_mvp_x_l1_reg;
                                    mvp_y <= b_bi_mvp_y_l1_reg;
                                    mvp_x_l0 <= 8'sd0;
                                    mvp_y_l0 <= 8'sd0;
                                    mvp_x_l1 <= b_bi_mvp_x_l1_reg;
                                    mvp_y_l1 <= b_bi_mvp_y_l1_reg;
                                    ref_rd_bank_sel <= newest_ref_bank;
                                    b_direct_pending_valid <= 1'b0;
                                    if (best_sad_i < INTER_SAD_THRESHOLD) begin
                                        use_intra16_mb_reg <= 1'b0;
                                        use_ipcm_mb_reg <= 1'b0;
                                        top_state <= TS_MB_HDR;
                                    end else begin
                                        is_b_l1_mb_reg <= 1'b0;
                                        use_intra16_mb_reg <= 1'b0;
                                        use_ipcm_mb_reg <= (ENABLE_P_IPCM != 0);
                                        top_state <= TS_MB_HDR;
                                    end
                                end else begin
                                    me_best_mvx <= me_best_mvx_l0;
                                    me_best_mvy <= me_best_mvy_l0;
                                    me_best_mvx_l1 <= 8'sd0;
                                    me_best_mvy_l1 <= 8'sd0;
                                    me_best_sad <= b_bi_luma_sad_l0;
                                    inter_pred_buf <= b_bi_luma_pred_l0;
                                    is_inter_mb_reg <= (b_bi_luma_sad_l0 < INTER_SAD_THRESHOLD);
                                    is_b_l1_mb_reg <= 1'b0;
                                    is_b_bi_mb_reg <= 1'b0;
                                    is_b_direct_mb_reg <= 1'b0;
                                    is_b_direct_from_l1_reg <= 1'b0;
                                    mvp_x <= b_bi_mvp_x_l0_reg;
                                    mvp_y <= b_bi_mvp_y_l0_reg;
                                    mvp_x_l0 <= b_bi_mvp_x_l0_reg;
                                    mvp_y_l0 <= b_bi_mvp_y_l0_reg;
                                    mvp_x_l1 <= 8'sd0;
                                    mvp_y_l1 <= 8'sd0;
                                    ref_rd_bank_sel <= b_l0_ref_bank_from_idx(mb_ref_idx_reg);
                                    b_direct_pending_valid <= 1'b0;
                                    if (b_bi_luma_sad_l0 < INTER_SAD_THRESHOLD) begin
                                        use_intra16_mb_reg <= 1'b0;
                                        use_ipcm_mb_reg <= 1'b0;
                                        top_state <= TS_MB_HDR;
                                    end else begin
                                        use_intra16_mb_reg <= 1'b0;
                                        use_ipcm_mb_reg <= (ENABLE_P_IPCM != 0);
                                        top_state <= TS_MB_HDR;
                                    end
                                end
                            end
                        end else begin
                            a_avail = (mb_x > 7'd0);
                            b_avail = (mb_y > 6'd0);
                            c_avail = (mb_y > 6'd0) && (mb_x < MB_COLS[6:0] - 7'd1);
                            d_avail = (mb_y > 6'd0) && (mb_x > 7'd0);

                            if (is_b_frame && is_b_l1_mb_reg) begin
                                ax = a_avail ? left_mvx_l1 : 8'sd0;
                                ay = a_avail ? left_mvy_l1 : 8'sd0;
                                a_match = a_avail && left_is_inter_l1 &&
                                          (left_ref_idx_l1 == mb_ref_idx_reg);

                                bx = b_avail ? top_mvx_l1[mb_x] : 8'sd0;
                                by = b_avail ? top_mvy_l1[mb_x] : 8'sd0;
                                b_match = b_avail && top_is_inter_l1[mb_x] &&
                                          (top_ref_idx_l1[mb_x] == mb_ref_idx_reg);

                                if (c_avail) begin
                                    cx = top_mvx_l1[mb_x + 7'd1];
                                    cy = top_mvy_l1[mb_x + 7'd1];
                                    c_match = top_is_inter_l1[mb_x + 7'd1] &&
                                              (top_ref_idx_l1[mb_x + 7'd1] == mb_ref_idx_reg);
                                end else if (d_avail) begin
                                    cx = diag_mvx_l1;
                                    cy = diag_mvy_l1;
                                    c_match = diag_is_inter_l1 &&
                                              (diag_ref_idx_l1 == mb_ref_idx_reg);
                                end else begin
                                    cx = 8'sd0;
                                    cy = 8'sd0;
                                    c_match = 1'b0;
                                end
                            end else begin
                                ax = a_avail ? left_mvx : 8'sd0;
                                ay = a_avail ? left_mvy : 8'sd0;
                                a_match = a_avail && left_is_inter &&
                                          (left_ref_idx == mb_ref_idx_reg);

                                bx = b_avail ? top_mvx[mb_x] : 8'sd0;
                                by = b_avail ? top_mvy[mb_x] : 8'sd0;
                                b_match = b_avail && top_is_inter[mb_x] &&
                                          (top_ref_idx[mb_x] == mb_ref_idx_reg);

                                if (c_avail) begin
                                    cx = top_mvx[mb_x + 7'd1];
                                    cy = top_mvy[mb_x + 7'd1];
                                    c_match = top_is_inter[mb_x + 7'd1] &&
                                              (top_ref_idx[mb_x + 7'd1] == mb_ref_idx_reg);
                                end else if (d_avail) begin
                                    cx = diag_mvx;
                                    cy = diag_mvy;
                                    c_match = diag_is_inter &&
                                              (diag_ref_idx == mb_ref_idx_reg);
                                end else begin
                                    cx = 8'sd0;
                                    cy = 8'sd0;
                                    c_match = 1'b0;
                                end
                            end

                            if (!b_avail && !c_avail && !d_avail) begin
                                bx = ax; by = ay; b_match = a_match;
                                cx = ax; cy = ay; c_match = a_match;
                            end

                            match_cnt = {1'b0, a_match} + {1'b0, b_match} + {1'b0, c_match};
                            med_x = (ax > bx && ax > cx) ? ((bx > cx) ? bx : cx) :
                                    (ax < bx && ax < cx) ? ((bx < cx) ? bx : cx) : ax;
                            med_y = (ay > by && ay > cy) ? ((by > cy) ? by : cy) :
                                    (ay < by && ay < cy) ? ((by < cy) ? by : cy) : ay;

                            if (match_cnt == 2'd1) begin
                                if (a_match)      begin sel_mvp_x = ax; sel_mvp_y = ay; end
                                else if (b_match) begin sel_mvp_x = bx; sel_mvp_y = by; end
                                else              begin sel_mvp_x = cx; sel_mvp_y = cy; end
                            end else begin
                                sel_mvp_x = med_x;
                                sel_mvp_y = med_y;
                            end
                            mvp_x <= sel_mvp_x;
                            mvp_y <= sel_mvp_y;
                            if (is_b_frame && is_b_l1_mb_reg) begin
                                mvp_x_l0 <= 8'sd0;
                                mvp_y_l0 <= 8'sd0;
                                me_best_mvx_l0 <= 8'sd0;
                                me_best_mvy_l0 <= 8'sd0;
                                mvp_x_l1 <= sel_mvp_x;
                                mvp_y_l1 <= sel_mvp_y;
                                me_best_mvx_l1 <= (me_fullpel_mvx <<< 2) + best_dx_i;
                                me_best_mvy_l1 <= (me_fullpel_mvy <<< 2) + best_dy_i;
                            end else begin
                                mvp_x_l0 <= sel_mvp_x;
                                mvp_y_l0 <= sel_mvp_y;
                                me_best_mvx_l0 <= (me_fullpel_mvx <<< 2) + best_dx_i;
                                me_best_mvy_l0 <= (me_fullpel_mvy <<< 2) + best_dy_i;
                                mvp_x_l1 <= 8'sd0;
                                mvp_y_l1 <= 8'sd0;
                                me_best_mvx_l1 <= 8'sd0;
                                me_best_mvy_l1 <= 8'sd0;
                            end

                            pskip_luma_exact = 1'b1;
                            for (pskip_idx = 0; pskip_idx < 256; pskip_idx = pskip_idx + 1) begin
                                if (fetched_luma[pskip_idx*BD +: BD] != best_pred_buf_i[pskip_idx*BD +: BD])
                                    pskip_luma_exact = 1'b0;
                            end

                            if (!a_avail || !b_avail ||
                                (a_avail && left_is_inter && (left_ref_idx == 2'd0) &&
                                 (left_mvx == 8'sd0) && (left_mvy == 8'sd0)) ||
                                (b_avail && top_is_inter[mb_x] && (top_ref_idx[mb_x] == 2'd0) &&
                                 (top_mvx[mb_x] == 8'sd0) && (top_mvy[mb_x] == 8'sd0))) begin
                                pskip_x = 8'sd0;
                                pskip_y = 8'sd0;
                            end else begin
                                pskip_a_match = a_avail && left_is_inter && (left_ref_idx == 2'd0);
                                pskip_b_match = b_avail && top_is_inter[mb_x] && (top_ref_idx[mb_x] == 2'd0);
                                if (c_avail) begin
                                    pskip_c_match = top_is_inter[mb_x + 7'd1] && (top_ref_idx[mb_x + 7'd1] == 2'd0);
                                end else if (d_avail) begin
                                    pskip_c_match = diag_is_inter && (diag_ref_idx == 2'd0);
                                end else begin
                                    pskip_c_match = 1'b0;
                                end

                                pskip_match_cnt = {1'b0, pskip_a_match} + {1'b0, pskip_b_match} + {1'b0, pskip_c_match};
                                pskip_med_x = (ax > bx && ax > cx) ? ((bx > cx) ? bx : cx) :
                                              (ax < bx && ax < cx) ? ((bx < cx) ? bx : cx) : ax;
                                pskip_med_y = (ay > by && ay > cy) ? ((by > cy) ? by : cy) :
                                              (ay < by && ay < cy) ? ((by < cy) ? by : cy) : ay;
                                if (pskip_match_cnt == 2'd1) begin
                                    if (pskip_a_match)      begin pskip_x = ax; pskip_y = ay; end
                                    else if (pskip_b_match) begin pskip_x = bx; pskip_y = by; end
                                    else                    begin pskip_x = cx; pskip_y = cy; end
                                end else begin
                                    pskip_x = pskip_med_x;
                                    pskip_y = pskip_med_y;
                                end
                            end
                            pskip_syntax_eligible_reg <= is_p_frame && !use_weighted_pred_w && (mb_ref_idx_reg == 2'd0) &&
                                                         ($signed((me_fullpel_mvx <<< 2) + best_dx_i) == pskip_x) &&
                                                         ($signed((me_fullpel_mvy <<< 2) + best_dy_i) == pskip_y);
                            /* verilator lint_off WIDTH */
                            if (dbg_target_mb) begin
                                $display("[SUBPEL] F%0d MB%0d mbx=%0d mby=%0d ref=%0d fullsad=%0d bestsad=%0d dxq=%0d dyq=%0d mv=(%0d,%0d)",
                                    dbg_frame_cnt, mb_count, mb_x, mb_y, mb_ref_idx_reg,
                                    me_fullpel_best_sad, best_sad_i, best_dx_i, best_dy_i,
                                    $signed((me_fullpel_mvx <<< 2) + best_dx_i),
                                    $signed((me_fullpel_mvy <<< 2) + best_dy_i));
                            end
                            if (dbg_target_mb) begin
                                $display("[MVP] F%0d MB%0d mbx=%0d mby=%0d ref=%0d A(%0d,%0d,m=%0d) B(%0d,%0d,m=%0d) C(%0d,%0d,m=%0d) match=%0d med(%0d,%0d) sad=%0d inter=%0d",
                                    dbg_frame_cnt, mb_count, mb_x, mb_y, mb_ref_idx_reg,
                                    $signed(ax), $signed(ay), a_match,
                                    $signed(bx), $signed(by), b_match,
                                    $signed(cx), $signed(cy), c_match,
                                    match_cnt, $signed(med_x), $signed(med_y),
                                    best_sad_i, (best_sad_i < INTER_SAD_THRESHOLD));
                            end
                            /* verilator lint_on WIDTH */

                            if (best_sad_i < INTER_SAD_THRESHOLD) begin
                                use_intra16_mb_reg <= 1'b0;
                                use_ipcm_mb_reg <= 1'b0;
                                if (is_p_frame && !use_weighted_pred_w && (mb_ref_idx_reg == 2'd0) &&
                                    pskip_luma_exact &&
                                    ($signed((me_fullpel_mvx <<< 2) + best_dx_i) == pskip_x) &&
                                    ($signed((me_fullpel_mvy <<< 2) + best_dy_i) == pskip_y)) begin
                                    skip_probe_pending <= 1'b1;
                                    chr_fetch_cnt <= {CHR_FETCH_W{1'b0}};
                                    chr_fetch_started <= 1'b0;
                                    chr_raw_cb <= {(CHR_RAW_SAMPLES*BD){1'b0}};
                                    chr_raw_cr <= {(CHR_RAW_SAMPLES*BD){1'b0}};
                                    chr_f_row <= 5'd0;
                                    chr_f_col <= {CHR_FETCH_COL_W{1'b0}};
                                    b_bi_chr_fetch_l1_phase <= 1'b0;
                                    chr_frac_x <= (me_fullpel_mvx <<< 2) + best_dx_i;
                                    chr_frac_y <= (me_fullpel_mvy <<< 2) + best_dy_i;
                                    chr_fetch_cols <= ((((me_fullpel_mvx <<< 2) + best_dx_i) & 8'sd7) != 8'sd0) ? (CHR_MB_WIDTH[CHR_FETCH_COL_W-1:0] + {{(CHR_FETCH_COL_W-1){1'b0}}, 1'b1}) : CHR_MB_WIDTH[CHR_FETCH_COL_W-1:0];
                                    chr_fetch_rows <= ((((me_fullpel_mvy <<< 2) + best_dy_i) & 8'sd7) != 8'sd0) ? (CHR_MB_HEIGHT[4:0] + 5'd1) : CHR_MB_HEIGHT[4:0];
                                    top_state <= TS_CHR_FETCH;
                                end else begin
                                    top_state <= TS_MB_HDR;
                                end
                            end else begin
                                use_intra16_mb_reg <= 1'b0;
                                use_ipcm_mb_reg <= (ENABLE_P_IPCM != 0);
                                top_state <= TS_MB_HDR;
                            end
                        end
                    end
                end

                TS_I16_PRED: begin
                    if (!blk_started) begin
                        intra16_start <= 1'b1;
                        blk_started <= 1'b1;
                    end else if (intra16_done) begin
                        intra16_pred_buf <= intra16_pred_w;
                        intra16_mode_mb <= intra16_mode_w;
                        if (allow_ipcm_w && (intra16_sad_w >= IPCM_SAD_THRESHOLD)) begin
                            use_intra16_mb_reg <= 1'b0;
                            use_ipcm_mb_reg <= 1'b1;
                        end else begin
                            use_intra16_mb_reg <= 1'b1;
                            use_ipcm_mb_reg <= 1'b0;
                        end
                        blk_started <= 1'b0;
                        top_state <= TS_MB_HDR;
                    end
                end

                TS_MB_HDR: if (!bs_busy) begin
                    cabac_cbp_luma_reg <= 4'd0;
                    cabac_luma_scan_flat_reg <= 4096'd0;
                    cabac_luma_nz_mask_reg <= 16'd0;
                    cabac_chroma_scan_flat_reg <= 4096'd0;
                    cabac_chroma_nz_mask_reg <= 16'd0;
                    if (use_ipcm_mb_reg) begin
                        mb_has_residual <= 1'b0;
                        sub_blk <= 5'd0;
                        blk_started <= 1'b0;
                        recon_buf <= fetched_luma;
                        luma_recon_buf <= fetched_luma;
                        chr_recon_cb <= fetched_cb;
                        chr_recon_cr <= fetched_cr;
                        chr_pred_mode <= 1'b0;
                        intra_pred_bits_mb <= 64'd0;
                        intra_pred_count_mb <= 7'd0;
                        is_intra16_mb_hdr <= 1'b0;
                        is_ipcm_mb_hdr <= 1'b1;
                        intra_mb_type_code_num <= intra_ipcm_type_code;
                        i16_dc_total_coeff <= 5'd0;
                        i16_luma_ac_nonzero <= 1'b0;
                        i16_chroma_dc_nonzero <= 1'b0;
                        i16_chroma_ac_nonzero <= 1'b0;
                        i16_cbp_chroma <= 2'd0;
                        bs_hold_fifo_drain <= 1'b0;
                        top_state <= TS_DEFER_MB_HDR;
                    end else begin
                        if (force_transform_8x8_in && is_inter_mb_reg) begin
                            mb_has_residual <= 1'b0;
                            sub_blk <= 5'd0;
                            blk_started <= 1'b0;
                            recon_buf <= {(256*BD){1'b0}};
                            luma_recon_buf <= {(256*BD){1'b0}};
                            chr_pred_mode <= 1'b0;
                            intra_pred_bits_mb <= 64'd0;
                            intra_pred_count_mb <= 7'd0;
                            is_intra16_mb_hdr <= 1'b0;
                            is_ipcm_mb_hdr <= 1'b0;
                            intra_mb_type_code_num <= intra_i4_type_code;
                            i16_dc_total_coeff <= 5'd0;
                            i16_luma_ac_nonzero <= 1'b0;
                            i16_chroma_dc_nonzero <= 1'b0;
                            i16_chroma_ac_nonzero <= 1'b0;
                            i16_cbp_chroma <= 2'd0;
                            bs_hold_fifo_drain <= 1'b1;
                            luma8_group <= 2'd0;
                            luma8_sub <= 2'd0;
                            luma8_phase <= 3'd0;
                            luma8_started <= 1'b0;
                            top_state <= TS_LUMA8;
                        end else if (force_transform_8x8_in && use_intra16_mb_reg) begin
                            mb_has_residual <= 1'b1;
                            sub_blk <= 5'd0;
                            blk_started <= 1'b0;
                            recon_buf <= {(256*BD){1'b0}};
                            luma_recon_buf <= {(256*BD){1'b0}};
                            chr_pred_mode <= 1'b0;
                            intra_pred_bits_mb <= 64'd0;
                            intra_pred_count_mb <= 7'd0;
                            is_intra16_mb_hdr <= use_intra16_mb_reg;
                            is_ipcm_mb_hdr <= 1'b0;
                            intra_mb_type_code_num <= intra_i4_type_code;
                            i16_dc_total_coeff <= 5'd0;
                            i16_luma_ac_nonzero <= 1'b0;
                            i16_chroma_dc_nonzero <= 1'b0;
                            i16_chroma_ac_nonzero <= 1'b0;
                            i16_cbp_chroma <= 2'd0;
                            bs_hold_fifo_drain <= 1'b1;
                            top_state <= TS_LUMA16;
                            luma16_phase <= 3'd0;
                            luma16_blk <= 4'd0;
                        end else begin
                            mb_has_residual <= is_inter_mb_reg ? 1'b0 : 1'b1;
                            sub_blk <= 5'd0;
                            blk_state <= is_inter_mb_reg ? BS_XFORM : (use_intra16_mb_reg ? BS_XFORM : BS_PRED);
                            blk_started <= 1'b0;
                            recon_buf <= {(256*BD){1'b0}};
                            luma_recon_buf <= {(256*BD){1'b0}};
                            chr_pred_mode <= 1'b0;
                            intra_pred_bits_mb <= 64'd0;
                            intra_pred_count_mb <= 7'd0;
                            is_intra16_mb_hdr <= use_intra16_mb_reg;
                            is_ipcm_mb_hdr <= 1'b0;
                            intra_mb_type_code_num <= intra_i4_type_code;
                            i16_dc_total_coeff <= 5'd0;
                            i16_luma_ac_nonzero <= 1'b0;
                            i16_chroma_dc_nonzero <= 1'b0;
                            i16_chroma_ac_nonzero <= 1'b0;
                            i16_cbp_chroma <= 2'd0;
                            bs_hold_fifo_drain <= 1'b1;
                            top_state <= TS_ENCODE_SBLK;
                        end
                    end
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
                        BS_QUANT:  if (!blk_started) begin
                                       quant_start <= 1'b1; blk_started <= 1'b1;
                                   end else if (quant_done) begin
                                       if (use_intra16_mb_reg && is_luma) begin
                                           i16_dc_buf[mb_blk_idx] <= $signed(xform_out_flat[CW-1:0]);
                                           i16_quant_buf[sub_blk[3:0]] <= {quant_out_flat[255:16], 16'd0};
                                           if (sub_blk == 5'd15) begin
                                               top_state <= TS_LUMA16;
                                               luma16_phase <= 3'd0;
                                               luma16_blk <= 4'd0;
                                               blk_state <= BS_PRED;
                                               blk_started <= 1'b0;
                                           end else begin
                                               sub_blk <= sub_blk + 5'd1;
                                               blk_state <= BS_XFORM;
                                               blk_started <= 1'b0;
                                           end
                                       end else begin
                                           blk_state <= BS_ZIGZAG;
                                           blk_started <= 1'b0;
                                       end
                                   end
                        BS_ZIGZAG: if (!blk_started) begin zz_start <= 1'b1; iq_start <= 1'b1; blk_started <= 1'b1; iq_done_latched <= 1'b0; end
                                   else begin if (iq_done) iq_done_latched <= 1'b1; if (zz_done) begin
                                       nz_coeff[sub_blk] <= total_coeffs;
                                       if (is_luma) begin
                                           cabac_luma_scan_flat_reg[sub_blk[3:0] * 256 +: 256] <= scan_flat;
                                           cabac_luma_nz_mask_reg[sub_blk[3:0]] <= (total_coeffs != 5'd0);
                                           if (total_coeffs != 5'd0)
                                               cabac_cbp_luma_reg[sub_blk[3:2]] <= 1'b1;
                                       end
                                       blk_state <= BS_CAVLC; blk_started <= 1'b0;
                                   end end
                        BS_CAVLC:  if (!blk_started && !bs_busy) begin cavlc_start <= 1'b1; blk_started <= 1'b1; end
                                   else begin if (iq_done) iq_done_latched <= 1'b1; if (cavlc_done) begin blk_state <= BS_IQ; blk_started <= 1'b0; end end
                        BS_IQ:     if (iq_done || iq_done_latched) begin blk_state <= BS_IT; blk_started <= 1'b0; end else if (iq_done) iq_done_latched <= 1'b1;
                        BS_IT:     if (!blk_started) begin it_start <= 1'b1; blk_started <= 1'b1; end else if (it_done) begin blk_state <= BS_RECON; blk_started <= 1'b0; end
                        BS_RECON:  if (!blk_started) begin recon_start <= 1'b1; blk_started <= 1'b1; end else if (recon_done) begin
                                       recon_buf <= recon_out_w;
                                       if (sub_blk == 5'd15) begin
                                           luma_recon_buf <= recon_out_w;
                                           // Luma done
                                           if (is_inter_mb_reg) begin
                                               blk_started <= 1'b0;
                                               chr_recon_cb <= {(CHR_MB_PIXELS*BD){1'b0}};
                                               chr_recon_cr <= {(CHR_MB_PIXELS*BD){1'b0}};
                                               if (inter_chr_prefetched_valid) begin
                                                   top_state <= TS_CHROMA;
                                                   chr_phase <= 3'd0;
                                                   chr_blk <= {CHR_BLK_W{1'b0}};
                                                   chr_is_cr <= 1'b0;
                                                   recon_buf <= {(256*BD){1'b0}};
                                                   blk_state <= BS_PRED;
                                                   inter_chr_mode <= 1'b1;
                                                   use_chr_dc_zigzag <= 1'b0;
                                                   use_chr_ac_zigzag <= 1'b0;
                                                   cavlc_is_chroma_dc <= 1'b0;
                                                   cavlc_is_chroma_ac <= 1'b0;
                                                   zz_chroma_ac_mode <= 1'b0;
                                                   zz_chroma_dc_mode <= 1'b0;
                                               end else begin
                                                   // Inter MBs: fetch chroma prediction from reference
                                                   top_state <= TS_CHR_FETCH;
                                                   chr_fetch_cnt <= {CHR_FETCH_W{1'b0}};
                                                   chr_fetch_started <= 1'b0;
                                                   chr_raw_cb <= {(CHR_RAW_SAMPLES*BD){1'b0}};
                                                   chr_raw_cr <= {(CHR_RAW_SAMPLES*BD){1'b0}};
                                                   chr_f_row <= 5'd0;
                                                   chr_f_col <= {CHR_FETCH_COL_W{1'b0}};
                                                   b_bi_chr_fetch_l1_phase <= 1'b0;
                                                   // Chroma 1/8-pel fraction from pre-computed wires
                                                   chr_frac_x <= chr_frac_x_w;
                                                   chr_frac_y <= chr_frac_y_w;
                                                   chr_fetch_cols <= (chr_frac_x_w != 3'd0) ? (CHR_MB_WIDTH[CHR_FETCH_COL_W-1:0] + {{(CHR_FETCH_COL_W-1){1'b0}}, 1'b1}) : CHR_MB_WIDTH[CHR_FETCH_COL_W-1:0];
                                                   chr_fetch_rows <= (chr_frac_y_w != 3'd0) ? (CHR_MB_HEIGHT[4:0] + 5'd1) : CHR_MB_HEIGHT[4:0];
                                               end
                                           end else begin
                                           // Intra: enter chroma processing with 8x8 DC prediction
                                           top_state <= TS_CHROMA;
                                           chr_phase <= 3'd0;
                                           chr_blk <= {CHR_BLK_W{1'b0}};
                                           chr_is_cr <= 1'b0;
                                           recon_buf <= {(256*BD){1'b0}};
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

                TS_LUMA16: begin
                    case (luma16_phase)
                        3'd0: begin
                            if (!blk_started) begin
                                i16_dc_in_flat <= {i16_dc_buf[15], i16_dc_buf[14], i16_dc_buf[13], i16_dc_buf[12],
                                                   i16_dc_buf[11], i16_dc_buf[10], i16_dc_buf[9], i16_dc_buf[8],
                                                   i16_dc_buf[7], i16_dc_buf[6], i16_dc_buf[5], i16_dc_buf[4],
                                                   i16_dc_buf[3], i16_dc_buf[2], i16_dc_buf[1], i16_dc_buf[0]};
                                i16_dc_inverse <= 1'b0;
                                i16_dc_start <= 1'b1;
                                blk_started <= 1'b1;
                            end else if (i16_dc_done) begin
                                begin : pack_i16_inv_input
                                    integer di;
                                    for (di = 0; di < 16; di = di + 1) begin
                                        i16_dc_q[di] <= $signed(i16_dc_out_flat[di*16 +: 16]);
                                        i16_dc_in_flat[di*CW +: CW] <= {{(CW-16){i16_dc_out_flat[di*16 + 15]}}, i16_dc_out_flat[di*16 +: 16]};
                                    end
                                end
                                i16_dc_inverse <= 1'b1;
                                i16_dc_start <= 1'b1;
                                luma16_phase <= 3'd1;
                                blk_started <= 1'b0;
                            end
                        end

                        3'd1: begin
                            if (!blk_started) begin
                                blk_started <= 1'b1;
                            end else if (i16_dc_done) begin
                                begin : capture_i16_inv_dc
                                    integer di;
                                    for (di = 0; di < 16; di = di + 1)
                                        i16_inv_dc[di] <= $signed(i16_dc_out_flat[di*16 +: 16]);
                                end
                                i16_dc_inverse <= 1'b0;
                                if (force_transform_8x8_in) begin
                                    top_state <= TS_LUMA8;
                                    luma8_phase <= 3'd0;
                                    luma8_group <= 2'd0;
                                    luma8_sub <= 2'd0;
                                    luma8_started <= 1'b0;
                                end else begin
                                    luma16_phase <= 3'd2;
                                    sub_blk <= 5'd0;
                                    blk_state <= BS_PRED;
                                    blk_started <= 1'b0;
                                end
                            end
                        end

                        3'd2: begin
                            sub_blk <= 5'd0;
                            case (blk_state)
                                BS_PRED: begin
                                    i16_dc_zigzag_in <= {i16_dc_q[15], i16_dc_q[14], i16_dc_q[13], i16_dc_q[12],
                                                         i16_dc_q[11], i16_dc_q[10], i16_dc_q[9], i16_dc_q[8],
                                                         i16_dc_q[7], i16_dc_q[6], i16_dc_q[5], i16_dc_q[4],
                                                         i16_dc_q[3], i16_dc_q[2], i16_dc_q[1], i16_dc_q[0]};
                                    use_i16_dc_zigzag <= 1'b1;
                                    use_i16_ac_zigzag <= 1'b0;
                                    use_i16_dc_nc <= 1'b1;
                                    zz_chroma_dc_mode <= 1'b0;
                                    zz_chroma_ac_mode <= 1'b0;
                                    cavlc_is_chroma_dc <= 1'b0;
                                    cavlc_is_chroma_ac <= 1'b0;
                                    zz_start <= 1'b1;
                                    blk_state <= BS_ZIGZAG;
                                end
                                BS_ZIGZAG: if (zz_done) begin
                                    i16_dc_total_coeff <= total_coeffs;
                                    if (!bs_busy) begin
                                        cavlc_start <= 1'b1;
                                        blk_state <= BS_CAVLC;
                                    end else begin
                                        blk_state <= BS_IQ;
                                    end
                                end
                                BS_IQ: if (!bs_busy) begin
                                    cavlc_start <= 1'b1;
                                    blk_state <= BS_CAVLC;
                                end
                                BS_CAVLC: if (cavlc_done) begin
                                    use_i16_dc_zigzag <= 1'b0;
                                    use_i16_dc_nc <= 1'b0;
                                    luma16_phase <= 3'd3;
                                    luma16_blk <= 4'd0;
                                    sub_blk <= 5'd0;
                                    blk_state <= BS_PRED;
                                end
                                default: blk_state <= BS_PRED;
                            endcase
                        end

                        3'd3: begin
                            sub_blk <= {1'b0, luma16_blk};
                            case (blk_state)
                                BS_PRED: begin
                                    i16_ac_zigzag_in <= i16_quant_buf[luma16_blk];
                                    use_i16_ac_zigzag <= 1'b1;
                                    use_i16_dc_zigzag <= 1'b0;
                                    zz_chroma_dc_mode <= 1'b0;
                                    // Intra_16x16 luma AC residual blocks have maxNumCoeff=15
                                    // (the DC coefficient is carried by the separate luma DC block).
                                    // Reuse the AC scan/CAVLC path so last_nonzero_idx and total_zeros
                                    // are coded in the decoder's 15-coefficient coordinate space.
                                    zz_chroma_ac_mode <= 1'b1;
                                    cavlc_is_chroma_dc <= 1'b0;
                                    cavlc_is_chroma_ac <= 1'b1;
                                    zz_start <= 1'b1;
                                    blk_state <= BS_ZIGZAG;
                                end
                                BS_ZIGZAG: if (zz_done) begin
                                    nz_coeff[{1'b0, luma16_blk}] <= total_coeffs;
                                    if (total_coeffs != 5'd0)
                                        i16_luma_ac_nonzero <= 1'b1;
                                    if (!bs_busy) begin
                                        cavlc_start <= 1'b1;
                                        blk_state <= BS_CAVLC;
                                    end else begin
                                        blk_state <= BS_IQ;
                                    end
                                end
                                BS_IQ: if (!bs_busy) begin
                                    cavlc_start <= 1'b1;
                                    blk_state <= BS_CAVLC;
                                end
                                BS_CAVLC: if (cavlc_done) begin
                                    if (luma16_blk == 4'd15) begin
                                        use_i16_ac_zigzag <= 1'b0;
                                        cavlc_is_chroma_ac <= 1'b0;
                                        zz_chroma_ac_mode <= 1'b0;
                                        luma16_phase <= 3'd4;
                                        luma16_blk <= 4'd0;
                                        sub_blk <= 5'd0;
                                        blk_state <= BS_PRED;
                                        blk_started <= 1'b0;
                                    end else begin
                                        luma16_blk <= luma16_blk + 4'd1;
                                        sub_blk <= {1'b0, luma16_blk + 4'd1};
                                        blk_state <= BS_PRED;
                                    end
                                end
                                default: blk_state <= BS_PRED;
                            endcase
                        end

                        3'd4: begin
                            sub_blk <= {1'b0, luma16_blk};
                            case (blk_state)
                                BS_PRED: begin
                                    i16_iq_input <= i16_quant_buf[luma16_blk];
                                    use_i16_iq_input <= 1'b1;
                                    iq_start <= 1'b1;
                                    blk_state <= BS_ZIGZAG;
                                    iq_done_latched <= 1'b0;
                                end
                                BS_ZIGZAG: begin
                                    if (iq_done || iq_done_latched) begin
                                        use_i16_it_input <= 1'b1;
                                        i16_it_dc_patch <= {{(CW-16){i16_inv_dc[mb_blk_idx][15]}}, i16_inv_dc[mb_blk_idx]};
                                        blk_state <= BS_IT;
                                        blk_started <= 1'b0;
                                    end else if (iq_done) begin
                                        iq_done_latched <= 1'b1;
                                    end
                                end
                                BS_IT: begin
                                    if (!blk_started) begin
                                        it_start <= 1'b1;
                                        blk_started <= 1'b1;
                                    end else if (it_done) begin
                                        blk_state <= BS_RECON;
                                        blk_started <= 1'b0;
                                    end
                                end
                                BS_RECON: begin
                                    if (!blk_started) begin
                                        recon_start <= 1'b1;
                                        blk_started <= 1'b1;
                                    end else if (recon_done) begin
                                        recon_buf <= recon_out_w;
                                        use_i16_iq_input <= 1'b0;
                                        use_i16_it_input <= 1'b0;
                                        if (luma16_blk == 4'd15) begin
                                            luma_recon_buf <= recon_out_w;
                                            top_state <= TS_CHROMA;
                                            chr_phase <= 3'd0;
                                            chr_blk <= {CHR_BLK_W{1'b0}};
                                            chr_is_cr <= 1'b0;
                                            recon_buf <= {(256*BD){1'b0}};
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
                                        end else begin
                                            luma16_blk <= luma16_blk + 4'd1;
                                            sub_blk <= {1'b0, luma16_blk + 4'd1};
                                            blk_state <= BS_PRED;
                                            blk_started <= 1'b0;
                                        end
                                    end
                                end
                                default: blk_state <= BS_PRED;
                            endcase
                        end

                        default: luma16_phase <= 3'd0;
                    endcase
                end

                TS_LUMA8: begin
                    case (luma8_phase)
                        3'd0: begin
                            if (!luma8_started) begin
                                luma8_xform_start <= 1'b1;
                                luma8_started <= 1'b1;
                            end else if (luma8_xform_done) begin
                                luma8_started <= 1'b0;
                                luma8_phase <= 3'd1;
                            end
                        end

                        3'd1: begin
                            if (!luma8_started) begin
                                luma8_quant_start <= 1'b1;
                                luma8_started <= 1'b1;
                            end else if (luma8_quant_done) begin
                                luma8_started <= 1'b0;
                                luma8_sub <= 2'd0;
                                luma8_phase <= 3'd2;
                            end
                        end

                        3'd2: begin
                            sub_blk <= {luma8_group, luma8_sub};
                            if (!luma8_started) begin
                                luma8_zz_start <= 1'b1;
                                luma8_started <= 1'b1;
                            end else if (luma8_zz_done) begin
                                nz_coeff[{luma8_group, luma8_sub}] <= luma8_total_coeffs;
                                if (luma8_total_coeffs != 5'd0)
                                    i16_luma_ac_nonzero <= 1'b1;
                                luma8_started <= 1'b0;
                                luma8_phase <= 3'd3;
                            end
                        end

                        3'd3: begin
                            sub_blk <= {luma8_group, luma8_sub};
                            if (!luma8_started && !bs_busy) begin
                                cavlc_start <= 1'b1;
                                luma8_started <= 1'b1;
                            end else if (cavlc_done) begin
                                luma8_started <= 1'b0;
                                if (luma8_sub == 2'd3) begin
                                    luma8_sub <= 2'd0;
                                    luma8_phase <= 3'd4;
                                end else begin
                                    luma8_sub <= luma8_sub + 2'd1;
                                    luma8_phase <= 3'd2;
                                end
                            end
                        end

                        3'd4: begin
                            if (!luma8_started) begin
                                luma8_iq_start <= 1'b1;
                                luma8_started <= 1'b1;
                            end else if (luma8_iq_done) begin
                                luma8_started <= 1'b0;
                                luma8_phase <= 3'd5;
                            end
                        end

                        3'd5: begin
                            if (!luma8_started) begin
                                luma8_it_start <= 1'b1;
                                luma8_started <= 1'b1;
                            end else if (luma8_it_done) begin
                                luma8_started <= 1'b0;
                                luma8_sub <= 2'd0;
                                luma8_phase <= 3'd6;
                            end
                        end

                        3'd6: begin
                            sub_blk <= {luma8_group, luma8_sub};
                            if (!luma8_started) begin
                                recon_start <= 1'b1;
                                luma8_started <= 1'b1;
                            end else if (recon_done) begin
                                recon_buf <= recon_out_w;
                                luma8_started <= 1'b0;
                                if (luma8_group == 2'd3 && luma8_sub == 2'd3) begin
                                    luma_recon_buf <= recon_out_w;
                                    if (is_inter_mb_reg) begin
                                        blk_started <= 1'b0;
                                        chr_recon_cb <= {(CHR_MB_PIXELS*BD){1'b0}};
                                        chr_recon_cr <= {(CHR_MB_PIXELS*BD){1'b0}};
                                        if (inter_chr_prefetched_valid) begin
                                            top_state <= TS_CHROMA;
                                            chr_phase <= 3'd0;
                                            chr_blk <= {CHR_BLK_W{1'b0}};
                                            chr_is_cr <= 1'b0;
                                            recon_buf <= {(256*BD){1'b0}};
                                            blk_state <= BS_PRED;
                                            inter_chr_mode <= 1'b1;
                                            use_chr_dc_zigzag <= 1'b0;
                                            use_chr_ac_zigzag <= 1'b0;
                                            cavlc_is_chroma_dc <= 1'b0;
                                            cavlc_is_chroma_ac <= 1'b0;
                                            zz_chroma_ac_mode <= 1'b0;
                                            zz_chroma_dc_mode <= 1'b0;
                                        end else begin
                                            top_state <= TS_CHR_FETCH;
                                            chr_fetch_cnt <= {CHR_FETCH_W{1'b0}};
                                            chr_fetch_started <= 1'b0;
                                            chr_raw_cb <= {(CHR_RAW_SAMPLES*BD){1'b0}};
                                            chr_raw_cr <= {(CHR_RAW_SAMPLES*BD){1'b0}};
                                            chr_f_row <= 5'd0;
                                            chr_f_col <= {CHR_FETCH_COL_W{1'b0}};
                                            b_bi_chr_fetch_l1_phase <= 1'b0;
                                            chr_frac_x <= chr_frac_x_w;
                                            chr_frac_y <= chr_frac_y_w;
                                            chr_fetch_cols <= (chr_frac_x_w != 3'd0) ? (CHR_MB_WIDTH[CHR_FETCH_COL_W-1:0] + {{(CHR_FETCH_COL_W-1){1'b0}}, 1'b1}) : CHR_MB_WIDTH[CHR_FETCH_COL_W-1:0];
                                            chr_fetch_rows <= (chr_frac_y_w != 3'd0) ? (CHR_MB_HEIGHT[4:0] + 5'd1) : CHR_MB_HEIGHT[4:0];
                                            chr_recon_cb <= {(CHR_MB_PIXELS*BD){1'b0}};
                                            chr_recon_cr <= {(CHR_MB_PIXELS*BD){1'b0}};
                                            blk_state <= BS_PRED;
                                            inter_chr_mode <= 1'b1;
                                            use_chr_dc_zigzag <= 1'b0;
                                            use_chr_ac_zigzag <= 1'b0;
                                            cavlc_is_chroma_dc <= 1'b0;
                                            cavlc_is_chroma_ac <= 1'b0;
                                            zz_chroma_ac_mode <= 1'b0;
                                            zz_chroma_dc_mode <= 1'b0;
                                        end
                                    end else begin
                                        top_state <= TS_CHROMA;
                                        chr_phase <= 3'd0;
                                        chr_blk <= {CHR_BLK_W{1'b0}};
                                        chr_is_cr <= 1'b0;
                                        recon_buf <= {(256*BD){1'b0}};
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
                                    end
                                end else if (luma8_sub == 2'd3) begin
                                    luma8_group <= luma8_group + 2'd1;
                                    luma8_sub <= 2'd0;
                                    luma8_phase <= 3'd0;
                                end else begin
                                    luma8_sub <= luma8_sub + 2'd1;
                                    luma8_phase <= 3'd2;
                                end
                            end
                        end

                        default: luma8_phase <= 3'd0;
                    endcase
                end

                TS_DEFER_MB_HDR: if (!bs_busy) begin
                    cabac_skip_ctx_reg <= {1'b0, left_is_skip} + {1'b0, top_is_skip[mb_x]};
                    if (cabac_slice_enable_w && !is_skip_mb_reg && !cabac_non_skip_subset_ok_w) begin
                        `ifndef SYNTHESIS
                        $fatal(1,
                               "[CABAC_PSUBSET] Unsupported non-skip MB at frame_num=%0d mb=(%0d,%0d) inter=%0d residual=%0d skip=%0d pskip_eligible=%0d bskip_eligible=%0d ref=%0d mv=(%0d,%0d) mvd=(%0d,%0d) fullpel_mv=(%0d,%0d) refs=%0d",
                               cur_frame_num, mb_x, mb_y,
                               is_inter_mb_reg, mb_has_residual, is_skip_mb_reg,
                               pskip_syntax_eligible_reg, bskip_syntax_eligible_reg,
                               mb_ref_idx_reg, me_best_mvx_l0, me_best_mvy_l0,
                               $signed(mvd_x_l0_w), $signed(mvd_y_l0_w),
                               me_fullpel_mvx, me_fullpel_mvy,
                               slice_num_ref_idx_l0_active_minus1 + 2'd1);
                        `endif
                        end
                    // Emit the buffered macroblock header while FIFO drain is
                    // still held so the header stays ahead of this MB's
                    // deferred residual payload.
                    bs_cmd_mb_hdr <= 1'b1;
                    top_state <= TS_DEFER_DRAIN;
                end

                TS_DEFER_DRAIN: begin
                    if (bs_hold_fifo_drain) begin
                        // After the header command is accepted, release the
                        // deferred residual FIFO and wait for the bitstream
                        // writer to drain fully idle before advancing.
                        bs_hold_fifo_drain <= 1'b0;
                    end else if (!bs_busy) begin
                        top_state <= TS_NEXT_MB;
                    end
                end

                TS_SKIP_CLR_FIFO: if (!bs_busy) begin
                    bs_cmd_clear_fifo <= 1'b1;
                    top_state <= is_skip_mb_reg ? TS_SKIP_MB_HDR : TS_DEFER_MB_HDR;
                end

                TS_SKIP_MB_HDR: if (!bs_busy) begin
                    cabac_skip_ctx_reg <= {1'b0, left_is_skip} + {1'b0, top_is_skip[mb_x]};
                    bs_hold_fifo_drain <= 1'b0;
                    bs_cmd_mb_hdr <= 1'b1;
                    top_state <= TS_NEXT_MB;
                end

                TS_NEXT_MB: begin
                    if (use_ipcm_mb_reg) begin
                        left_mb_nz[0] <= 5'd16; left_mb_nz[1] <= 5'd16; left_mb_nz[2] <= 5'd16; left_mb_nz[3] <= 5'd16;
                        top_mb_nz[mb_x * 4 + 0] <= 5'd16; top_mb_nz[mb_x * 4 + 1] <= 5'd16; top_mb_nz[mb_x * 4 + 2] <= 5'd16; top_mb_nz[mb_x * 4 + 3] <= 5'd16;
                    end else if (is_inter_mb_reg && !mb_has_residual) begin
                        left_mb_nz[0] <= 5'd0; left_mb_nz[1] <= 5'd0; left_mb_nz[2] <= 5'd0; left_mb_nz[3] <= 5'd0;
                        top_mb_nz[mb_x * 4 + 0] <= 5'd0; top_mb_nz[mb_x * 4 + 1] <= 5'd0; top_mb_nz[mb_x * 4 + 2] <= 5'd0; top_mb_nz[mb_x * 4 + 3] <= 5'd0;
                    end else begin
                        left_mb_nz[0] <= nz_coeff[5]; left_mb_nz[1] <= nz_coeff[7]; left_mb_nz[2] <= nz_coeff[13]; left_mb_nz[3] <= nz_coeff[15];
                        top_mb_nz[mb_x * 4 + 0] <= nz_coeff[10]; top_mb_nz[mb_x * 4 + 1] <= nz_coeff[11]; top_mb_nz[mb_x * 4 + 2] <= nz_coeff[14]; top_mb_nz[mb_x * 4 + 3] <= nz_coeff[15];
                    end
                    if (use_intra16_mb_reg || use_ipcm_mb_reg) begin
                        left_mb_mode[0] <= INTRA_MODE_DC; left_mb_mode[1] <= INTRA_MODE_DC;
                        left_mb_mode[2] <= INTRA_MODE_DC; left_mb_mode[3] <= INTRA_MODE_DC;
                        top_mb_mode[mb_x * 4 + 0] <= INTRA_MODE_DC;
                        top_mb_mode[mb_x * 4 + 1] <= INTRA_MODE_DC;
                        top_mb_mode[mb_x * 4 + 2] <= INTRA_MODE_DC;
                        top_mb_mode[mb_x * 4 + 3] <= INTRA_MODE_DC;
                    end else begin
                        left_mb_mode[0] <= intra_mode_cur[5]; left_mb_mode[1] <= intra_mode_cur[7];
                        left_mb_mode[2] <= intra_mode_cur[13]; left_mb_mode[3] <= intra_mode_cur[15];
                        top_mb_mode[mb_x * 4 + 0] <= intra_mode_cur[10];
                        top_mb_mode[mb_x * 4 + 1] <= intra_mode_cur[11];
                        top_mb_mode[mb_x * 4 + 2] <= intra_mode_cur[14];
                        top_mb_mode[mb_x * 4 + 3] <= intra_mode_cur[15];
                    end
                    left_mb_i16dc_nz <= use_intra16_mb_reg ? i16_dc_total_coeff : 5'd0;
                    top_mb_i16dc_nz[mb_x] <= use_intra16_mb_reg ? i16_dc_total_coeff : 5'd0;
                    // Chroma nC neighbors (parameterized for 4:2:0 and 4:2:2)
                    begin : chr_nz_save
                        integer nr;
                        integer nc;
                        for (nr = 0; nr < CHR_BLOCK_ROWS; nr = nr + 1) begin
                            left_mb_nz_cb[nr] <= use_ipcm_mb_reg ? 5'd16 : ((is_inter_mb_reg && !mb_has_residual) ? 5'd0 : nz_coeff[chroma_sub_blk_from_rc(1'b0, nr[1:0], CHR_BLOCK_COLS - 1)]);
                            left_mb_nz_cr[nr] <= use_ipcm_mb_reg ? 5'd16 : ((is_inter_mb_reg && !mb_has_residual) ? 5'd0 : nz_coeff[chroma_sub_blk_from_rc(1'b1, nr[1:0], CHR_BLOCK_COLS - 1)]);
                        end
                        for (nc = 0; nc < CHR_BLOCK_COLS; nc = nc + 1) begin
                            top_mb_nz_cb[mb_x * CHR_BLOCK_COLS + nc] <= use_ipcm_mb_reg ? 5'd16 : ((is_inter_mb_reg && !mb_has_residual) ? 5'd0 : nz_coeff[chroma_sub_blk_from_rc(1'b0, CHR_BLOCK_ROWS - 1, nc[1:0])]);
                            top_mb_nz_cr[mb_x * CHR_BLOCK_COLS + nc] <= use_ipcm_mb_reg ? 5'd16 : ((is_inter_mb_reg && !mb_has_residual) ? 5'd0 : nz_coeff[chroma_sub_blk_from_rc(1'b1, CHR_BLOCK_ROWS - 1, nc[1:0])]);
                        end
                    end
                    top_ref_flat[mb_x * 16 * BD +: 16*BD] <= recon_top_row_buf_w; left_ref_flat <= recon_right_col_buf_w; mb_count <= mb_count + 12'd1;
                    if (is_skip_mb_reg)
                        frame_skip_mb_count <= frame_skip_mb_count + 16'd1;
                    if (is_b_frame && is_inter_mb_reg && is_b_l1_mb_reg)
                        frame_b_l1_mb_count <= frame_b_l1_mb_count + 16'd1;
                    if (is_b_frame && is_inter_mb_reg && is_b_bi_mb_reg)
                        frame_b_bi_mb_count <= frame_b_bi_mb_count + 16'd1;
                    if (is_b_frame && is_inter_mb_reg && is_b_direct_mb_reg)
                        frame_b_direct_mb_count <= frame_b_direct_mb_count + 16'd1;
                    if (is_b_frame && is_inter_mb_reg && !is_b_l1_mb_reg && (mb_ref_idx_reg != 2'd0))
                        frame_b_l0_nonzero_ref_mb_count <= frame_b_l0_nonzero_ref_mb_count + 16'd1;
                    if (is_b_frame && is_inter_mb_reg && is_b_direct_mb_reg && !is_b_l1_mb_reg && (mb_ref_idx_reg != 2'd0))
                        frame_b_direct_nonzero_ref_mb_count <= frame_b_direct_nonzero_ref_mb_count + 16'd1;
                    if (is_b_frame && is_inter_mb_reg && is_b_direct_mb_reg && is_b_direct_from_l1_reg)
                        frame_b_direct_from_l1_mb_count <= frame_b_direct_from_l1_mb_count + 16'd1;
                    if (cabac_non_skip_subset_ok_w)
                        frame_cabac_p16x16_mb_count <= frame_cabac_p16x16_mb_count + 16'd1;
                    top_is_skip[mb_x] <= is_skip_mb_reg;
                    left_is_skip <= is_skip_mb_reg;
                    if (is_inter_mb_reg && !is_b_frame && !is_skip_mb_reg) begin
                        top_mvd_abs_x[mb_x] <= cap_abs_mvd(mvd_x_l0_w);
                        top_mvd_abs_y[mb_x] <= cap_abs_mvd(mvd_y_l0_w);
                        left_mvd_abs_x <= cap_abs_mvd(mvd_x_l0_w);
                        left_mvd_abs_y <= cap_abs_mvd(mvd_y_l0_w);
                    end else begin
                        top_mvd_abs_x[mb_x] <= 7'd0;
                        top_mvd_abs_y[mb_x] <= 7'd0;
                        left_mvd_abs_x <= 7'd0;
                        left_mvd_abs_y <= 7'd0;
                    end
                    refmeta_is_intra[current_write_bank][mb_count] <= !is_inter_mb_reg;
                    refmeta_has_l0[current_write_bank][mb_count] <= is_inter_mb_reg &&
                                                                  (!is_b_frame || !is_b_l1_mb_reg || is_b_bi_mb_reg);
                    refmeta_has_l1[current_write_bank][mb_count] <= is_inter_mb_reg &&
                                                                  is_b_frame &&
                                                                  (is_b_l1_mb_reg || is_b_bi_mb_reg);
                    refmeta_ref_idx_l0[current_write_bank][mb_count] <= mb_ref_idx_reg;
                    refmeta_ref_idx_l1[current_write_bank][mb_count] <= is_b_l1_mb_reg ? mb_ref_idx_reg : mb_ref_idx_l1_reg;
                    refmeta_mvx_l0[current_write_bank][mb_count] <= is_b_frame && is_b_bi_mb_reg ? me_best_mvx_l0 : me_best_mvx;
                    refmeta_mvy_l0[current_write_bank][mb_count] <= is_b_frame && is_b_bi_mb_reg ? me_best_mvy_l0 : me_best_mvy;
                    refmeta_mvx_l1[current_write_bank][mb_count] <= is_b_frame && is_b_bi_mb_reg ? me_best_mvx_l1 :
                                                                    ((is_b_frame && is_b_l1_mb_reg) ? me_best_mvx : 8'sd0);
                    refmeta_mvy_l1[current_write_bank][mb_count] <= is_b_frame && is_b_bi_mb_reg ? me_best_mvy_l1 :
                                                                    ((is_b_frame && is_b_l1_mb_reg) ? me_best_mvy : 8'sd0);
                    // Save top-left diagonal before overwriting (for D neighbor)
                    diag_mvx <= top_mvx[mb_x];
                    diag_mvy <= top_mvy[mb_x];
                    diag_mvx_l1 <= top_mvx_l1[mb_x];
                    diag_mvy_l1 <= top_mvy_l1[mb_x];
                    diag_is_inter <= top_is_inter[mb_x];
                    diag_is_inter_l1 <= top_is_inter_l1[mb_x];
                    diag_is_b_l1 <= top_is_b_l1[mb_x];
                    diag_ref_idx <= top_ref_idx[mb_x];
                    diag_ref_idx_l1 <= top_ref_idx_l1[mb_x];
                    // Store MV and inter status for neighbor prediction
                    if (is_inter_mb_reg) begin
                        if (is_b_frame && is_b_bi_mb_reg) begin
                            top_mvx[mb_x] <= me_best_mvx_l0;
                            top_mvy[mb_x] <= me_best_mvy_l0;
                            top_is_inter[mb_x] <= 1'b1;
                            top_ref_idx[mb_x] <= mb_ref_idx_reg;
                            top_mvx_l1[mb_x] <= me_best_mvx_l1;
                            top_mvy_l1[mb_x] <= me_best_mvy_l1;
                            top_is_inter_l1[mb_x] <= 1'b1;
                            top_ref_idx_l1[mb_x] <= mb_ref_idx_l1_reg;
                        end else if (is_b_frame && is_b_l1_mb_reg) begin
                            top_mvx[mb_x] <= 8'sd0;
                            top_mvy[mb_x] <= 8'sd0;
                            top_is_inter[mb_x] <= 1'b0;
                            top_ref_idx[mb_x] <= 2'd0;
                            top_mvx_l1[mb_x] <= me_best_mvx;
                            top_mvy_l1[mb_x] <= me_best_mvy;
                            top_is_inter_l1[mb_x] <= 1'b1;
                            top_ref_idx_l1[mb_x] <= mb_ref_idx_reg;
                        end else begin
                            top_mvx[mb_x] <= me_best_mvx;
                            top_mvy[mb_x] <= me_best_mvy;
                            top_is_inter[mb_x] <= 1'b1;
                            top_ref_idx[mb_x] <= mb_ref_idx_reg;
                            top_mvx_l1[mb_x] <= 8'sd0;
                            top_mvy_l1[mb_x] <= 8'sd0;
                            top_is_inter_l1[mb_x] <= 1'b0;
                            top_ref_idx_l1[mb_x] <= 2'd0;
                        end
                        top_is_b_l1[mb_x] <= is_b_frame && is_b_l1_mb_reg;
                        top_is_i16[mb_x] <= 1'b0;
                        if (is_b_frame && is_b_bi_mb_reg) begin
                            left_mvx <= me_best_mvx_l0;
                            left_mvy <= me_best_mvy_l0;
                            left_is_inter <= 1'b1;
                            left_ref_idx <= mb_ref_idx_reg;
                            left_mvx_l1 <= me_best_mvx_l1;
                            left_mvy_l1 <= me_best_mvy_l1;
                            left_is_inter_l1 <= 1'b1;
                            left_ref_idx_l1 <= mb_ref_idx_l1_reg;
                        end else if (is_b_frame && is_b_l1_mb_reg) begin
                            left_mvx <= 8'sd0;
                            left_mvy <= 8'sd0;
                            left_is_inter <= 1'b0;
                            left_ref_idx <= 2'd0;
                            left_mvx_l1 <= me_best_mvx;
                            left_mvy_l1 <= me_best_mvy;
                            left_is_inter_l1 <= 1'b1;
                            left_ref_idx_l1 <= mb_ref_idx_reg;
                        end else begin
                            left_mvx <= me_best_mvx;
                            left_mvy <= me_best_mvy;
                            left_is_inter <= 1'b1;
                            left_ref_idx <= mb_ref_idx_reg;
                            left_mvx_l1 <= 8'sd0;
                            left_mvy_l1 <= 8'sd0;
                            left_is_inter_l1 <= 1'b0;
                            left_ref_idx_l1 <= 2'd0;
                        end
                        left_is_b_l1 <= is_b_frame && is_b_l1_mb_reg;
                        left_is_i16 <= 1'b0;
                    end else begin
                        top_mvx[mb_x] <= 8'sd0;
                        top_mvy[mb_x] <= 8'sd0;
                        top_is_inter[mb_x] <= 1'b0;
                        top_is_b_l1[mb_x] <= 1'b0;
                        top_ref_idx[mb_x] <= 2'd0;
                        top_mvx_l1[mb_x] <= 8'sd0;
                        top_mvy_l1[mb_x] <= 8'sd0;
                        top_is_inter_l1[mb_x] <= 1'b0;
                        top_ref_idx_l1[mb_x] <= 2'd0;
                        top_is_i16[mb_x] <= use_intra16_mb_reg;
                        left_mvx <= 8'sd0;
                        left_mvy <= 8'sd0;
                        left_is_inter <= 1'b0;
                        left_is_b_l1 <= 1'b0;
                        left_ref_idx <= 2'd0;
                        left_mvx_l1 <= 8'sd0;
                        left_mvy_l1 <= 8'sd0;
                        left_is_inter_l1 <= 1'b0;
                        left_ref_idx_l1 <= 2'd0;
                        left_is_i16 <= use_intra16_mb_reg;
                    end
                    // Store chroma neighbors for next MB's intra chroma prediction.
                    // Bottom row → top neighbor for MB below.
                    // Right column → left neighbor for MB to the right.
                    begin : chr_top_nb_save
                        integer nb_c;
                        for (nb_c = 0; nb_c < CHR_MB_WIDTH; nb_c = nb_c + 1) begin
                            top_chr_cb_nb[mb_x][nb_c*BD +: BD] <= chr_recon_cb[((CHR_MB_HEIGHT-1)*CHR_MB_WIDTH+nb_c)*BD +: BD];
                            top_chr_cr_nb[mb_x][nb_c*BD +: BD] <= chr_recon_cr[((CHR_MB_HEIGHT-1)*CHR_MB_WIDTH+nb_c)*BD +: BD];
                        end
                    end
                    begin : chr_nb_save
                        integer nb_r;
                        for (nb_r = 0; nb_r < CHR_MB_HEIGHT; nb_r = nb_r + 1) begin
                            left_chr_cb_nb[nb_r*BD +: BD] <= chr_recon_cb[(nb_r*CHR_MB_WIDTH + (CHR_MB_WIDTH-1))*BD +: BD];
                            left_chr_cr_nb[nb_r*BD +: BD] <= chr_recon_cr[(nb_r*CHR_MB_WIDTH + (CHR_MB_WIDTH-1))*BD +: BD];
                        end
                    end
                    `ifndef SYNTHESIS
                    if (deblock_active_w && (deblock_changed_count_w != 16'd0)) begin
                        $display("[DEBLOCK] frame=%0d mb=(%0d,%0d) idc=%0d changed_samples=%0d filtered_edges=%0d patch_writes=%0d pre_luma0=%0d post_luma0=%0d",
                                 cur_frame_num, mb_x, mb_y, deblock_disable_idc_w,
                                 deblock_changed_count_w, deblock_filtered_edge_count_w, deblock_patch_write_count_w,
                                 luma_recon_buf[0 +: BD], ref_luma_write_buf_w[0 +: BD]);
                    end
                    `endif
                    ref_wr_idx <= 9'd0;
                    deblock_fetch_idx <= 7'd0;
                    deblock_fetch_started <= 1'b0;
                    deblock_fetch_phase <= deblock_first_fetch_phase_fn(mb_left_avail, mb_top_avail);
                    deblock_wr_phase <= deblock_first_write_phase_fn(mb_left_avail, mb_top_avail, deblock_active_w);
                    if (deblock_patch_write_count_w != 16'd0) begin
                        ref_rd_bank_sel <= current_write_bank;
                        top_state <= TS_DEBLOCK_MB;
                    end else begin
                        top_state <= TS_REF_WR;
                    end
                end

                TS_DEBLOCK_MB: begin
                    if (deblock_fetch_phase != DBF_IDLE) begin
                        ref_rd_bank_sel <= current_write_bank;
                        case (deblock_fetch_phase)
                            DBF_LEFT_LUMA: begin
                                if (!deblock_fetch_started) begin
                                    deblock_fetch_started <= 1'b1;
                                end else begin
`ifndef SYNTHESIS
                                    if ((cur_frame_num == 8'd0) && (mb_x == 7'd1) && (mb_y == 6'd0) && (deblock_fetch_idx < 7'd4))
                                        $display("[DBG_DEBLOCK_FETCH] idx=%0d addr=%0d data=%0d bank=%0d", deblock_fetch_idx, ref_mem_rd_addr, ref_mem_rd_data, current_write_bank);
`endif
                                    deblock_left_luma_p_buf[deblock_fetch_idx*BD +: BD] <= ref_mem_rd_data;
                                    if (deblock_fetch_idx == 7'd63) begin
                                        deblock_fetch_phase <= deblock_next_fetch_phase_fn(deblock_fetch_phase, mb_left_avail, mb_top_avail);
                                        deblock_fetch_idx <= 7'd0;
                                        deblock_fetch_started <= 1'b0;
                                    end else begin
                                        deblock_fetch_idx <= deblock_fetch_idx + 7'd1;
                                    end
                                end
                            end
                            DBF_TOP_LUMA: begin
                                if (!deblock_fetch_started) begin
                                    deblock_fetch_started <= 1'b1;
                                end else begin
                                    deblock_top_luma_p_buf[deblock_fetch_idx*BD +: BD] <= ref_mem_rd_data;
                                    if (deblock_fetch_idx == 7'd63) begin
                                        deblock_fetch_phase <= deblock_next_fetch_phase_fn(deblock_fetch_phase, mb_left_avail, mb_top_avail);
                                        deblock_fetch_idx <= 7'd0;
                                        deblock_fetch_started <= 1'b0;
                                    end else begin
                                        deblock_fetch_idx <= deblock_fetch_idx + 7'd1;
                                    end
                                end
                            end
                            DBF_LEFT_CHROMA: begin
                                if (!deblock_fetch_started) begin
                                    chr_cb_ref_rd_addr <= cur_chroma_addr_fn(mb_x - 7'd1, mb_y, deblock_fetch_idx[6:2], (CHR_MB_WIDTH - 4) + deblock_fetch_idx[1:0]);
                                    chr_cr_ref_rd_addr <= cur_chroma_addr_fn(mb_x - 7'd1, mb_y, deblock_fetch_idx[6:2], (CHR_MB_WIDTH - 4) + deblock_fetch_idx[1:0]);
                                    deblock_fetch_started <= 1'b1;
                                end else begin
                                    deblock_left_cb_p_buf[deblock_fetch_idx*BD +: BD] <= chr_cb_ref_rd_data;
                                    deblock_left_cr_p_buf[deblock_fetch_idx*BD +: BD] <= chr_cr_ref_rd_data;
                                    if (deblock_fetch_idx + 7'd1 >= (4 * CHR_MB_HEIGHT)) begin
                                        deblock_fetch_phase <= deblock_next_fetch_phase_fn(deblock_fetch_phase, mb_left_avail, mb_top_avail);
                                        deblock_fetch_idx <= 7'd0;
                                        deblock_fetch_started <= 1'b0;
                                    end else begin
                                        deblock_fetch_idx <= deblock_fetch_idx + 7'd1;
                                        chr_cb_ref_rd_addr <= cur_chroma_addr_fn(mb_x - 7'd1, mb_y, (deblock_fetch_idx + 7'd1) / 4, (CHR_MB_WIDTH - 4) + ((deblock_fetch_idx + 7'd1) % 4));
                                        chr_cr_ref_rd_addr <= cur_chroma_addr_fn(mb_x - 7'd1, mb_y, (deblock_fetch_idx + 7'd1) / 4, (CHR_MB_WIDTH - 4) + ((deblock_fetch_idx + 7'd1) % 4));
                                    end
                                end
                            end
                            default: begin
                                if (!deblock_fetch_started) begin
                                    if (CHR_MB_WIDTH == 16) begin
                                        chr_cb_ref_rd_addr <= cur_chroma_addr_fn(mb_x, mb_y - 6'd1, (CHR_MB_HEIGHT - 4) + deblock_fetch_idx[5:4], deblock_fetch_idx[3:0]);
                                        chr_cr_ref_rd_addr <= cur_chroma_addr_fn(mb_x, mb_y - 6'd1, (CHR_MB_HEIGHT - 4) + deblock_fetch_idx[5:4], deblock_fetch_idx[3:0]);
                                    end else begin
                                        chr_cb_ref_rd_addr <= cur_chroma_addr_fn(mb_x, mb_y - 6'd1, (CHR_MB_HEIGHT - 4) + deblock_fetch_idx[4:3], {1'b0, deblock_fetch_idx[2:0]});
                                        chr_cr_ref_rd_addr <= cur_chroma_addr_fn(mb_x, mb_y - 6'd1, (CHR_MB_HEIGHT - 4) + deblock_fetch_idx[4:3], {1'b0, deblock_fetch_idx[2:0]});
                                    end
                                    deblock_fetch_started <= 1'b1;
                                end else begin
                                    deblock_top_cb_p_buf[deblock_fetch_idx*BD +: BD] <= chr_cb_ref_rd_data;
                                    deblock_top_cr_p_buf[deblock_fetch_idx*BD +: BD] <= chr_cr_ref_rd_data;
                                    if (deblock_fetch_idx + 7'd1 >= (4 * CHR_MB_WIDTH)) begin
                                        deblock_fetch_phase <= deblock_next_fetch_phase_fn(deblock_fetch_phase, mb_left_avail, mb_top_avail);
                                        deblock_fetch_idx <= 7'd0;
                                        deblock_fetch_started <= 1'b0;
                                    end else begin
                                        deblock_fetch_idx <= deblock_fetch_idx + 7'd1;
                                        if (CHR_MB_WIDTH == 16) begin
                                            chr_cb_ref_rd_addr <= cur_chroma_addr_fn(mb_x, mb_y - 6'd1, (CHR_MB_HEIGHT - 4) + ((deblock_fetch_idx + 7'd1) / 16), (deblock_fetch_idx + 7'd1) % 16);
                                            chr_cr_ref_rd_addr <= cur_chroma_addr_fn(mb_x, mb_y - 6'd1, (CHR_MB_HEIGHT - 4) + ((deblock_fetch_idx + 7'd1) / 16), (deblock_fetch_idx + 7'd1) % 16);
                                        end else begin
                                            chr_cb_ref_rd_addr <= cur_chroma_addr_fn(mb_x, mb_y - 6'd1, (CHR_MB_HEIGHT - 4) + ((deblock_fetch_idx + 7'd1) / 8), (deblock_fetch_idx + 7'd1) % 8);
                                            chr_cr_ref_rd_addr <= cur_chroma_addr_fn(mb_x, mb_y - 6'd1, (CHR_MB_HEIGHT - 4) + ((deblock_fetch_idx + 7'd1) / 8), (deblock_fetch_idx + 7'd1) % 8);
                                        end
                                    end
                                end
                            end
                        endcase
                    end else begin
                        case (deblock_wr_phase)
                            DBW_LEFT_LUMA: begin
                                ref_mem_wr_en <= 1'b1;
                                ref_mem_wr_addr <= cur_luma_addr_fn(mb_x - 7'd1, mb_y, ref_wr_idx / 3, 13 + (ref_wr_idx % 3));
                                ref_mem_wr_data <= deblock_left_luma_patch_w[ref_wr_idx*BD +: BD];
                                if (ref_wr_idx == 9'd47) begin
                                    ref_wr_idx <= 9'd0;
                                    deblock_wr_phase <= deblock_next_write_phase_fn(deblock_wr_phase, mb_left_avail, mb_top_avail);
                                end else begin
                                    ref_wr_idx <= ref_wr_idx + 9'd1;
                                end
                            end
                            DBW_TOP_LUMA: begin
                                ref_mem_wr_en <= 1'b1;
                                ref_mem_wr_addr <= cur_luma_addr_fn(mb_x, mb_y - 6'd1, 13 + (ref_wr_idx / 16), ref_wr_idx % 16);
                                ref_mem_wr_data <= deblock_top_luma_patch_w[ref_wr_idx*BD +: BD];
                                if (ref_wr_idx == 9'd47) begin
                                    ref_wr_idx <= 9'd0;
                                    deblock_wr_phase <= deblock_next_write_phase_fn(deblock_wr_phase, mb_left_avail, mb_top_avail);
                                end else begin
                                    ref_wr_idx <= ref_wr_idx + 9'd1;
                                end
                            end
                            DBW_LEFT_CHROMA: begin
                                chr_cb_ref_wr_en <= 1'b1;
                                chr_cr_ref_wr_en <= 1'b1;
                                chr_cb_ref_wr_addr <= cur_chroma_addr_fn(mb_x - 7'd1, mb_y, ref_wr_idx, CHR_MB_WIDTH - 1);
                                chr_cr_ref_wr_addr <= cur_chroma_addr_fn(mb_x - 7'd1, mb_y, ref_wr_idx, CHR_MB_WIDTH - 1);
                                chr_cb_ref_wr_data <= deblock_left_cb_patch_w[ref_wr_idx*BD +: BD];
                                chr_cr_ref_wr_data <= deblock_left_cr_patch_w[ref_wr_idx*BD +: BD];
                                if (ref_wr_idx + 9'd1 >= CHR_MB_HEIGHT) begin
                                    ref_wr_idx <= 9'd0;
                                    deblock_wr_phase <= deblock_next_write_phase_fn(deblock_wr_phase, mb_left_avail, mb_top_avail);
                                end else begin
                                    ref_wr_idx <= ref_wr_idx + 9'd1;
                                end
                            end
                            DBW_TOP_CHROMA: begin
                                chr_cb_ref_wr_en <= 1'b1;
                                chr_cr_ref_wr_en <= 1'b1;
                                chr_cb_ref_wr_addr <= cur_chroma_addr_fn(mb_x, mb_y - 6'd1, CHR_MB_HEIGHT - 1, ref_wr_idx);
                                chr_cr_ref_wr_addr <= cur_chroma_addr_fn(mb_x, mb_y - 6'd1, CHR_MB_HEIGHT - 1, ref_wr_idx);
                                chr_cb_ref_wr_data <= deblock_top_cb_patch_w[ref_wr_idx*BD +: BD];
                                chr_cr_ref_wr_data <= deblock_top_cr_patch_w[ref_wr_idx*BD +: BD];
                                if (ref_wr_idx + 9'd1 >= CHR_MB_WIDTH) begin
                                    ref_wr_idx <= 9'd0;
                                    deblock_wr_phase <= deblock_next_write_phase_fn(deblock_wr_phase, mb_left_avail, mb_top_avail);
                                end else begin
                                    ref_wr_idx <= ref_wr_idx + 9'd1;
                                end
                            end
                            default: begin
                                ref_wr_idx <= 9'd0;
                                top_state <= TS_REF_WR;
                            end
                        endcase
                    end
                end

                // Write reconstructed luma (256 bytes) back to reference frame memory
                TS_REF_WR: begin
                    if (ref_wr_idx < 9'd256) begin
                        // Write luma (256 pixels)
                        ref_mem_wr_en <= 1'b1;
                        ref_mem_wr_addr <= ({mb_y, 4'd0} + {6'd0, ref_wr_idx[7:4]}) * FRAME_WIDTH[10:0]
                                         + {mb_x, 4'd0} + {7'd0, ref_wr_idx[3:0]};
                        ref_mem_wr_data <= ref_luma_write_buf_w[ref_wr_idx[7:0]*BD +: BD];
                        ref_wr_idx <= ref_wr_idx + 9'd1;
                    end else if (ref_wr_idx < (9'd256 + CHR_MB_PIXELS[8:0])) begin
                        // Write chroma Cb and Cr simultaneously (CHR_MB_PIXELS each)
                        // Chroma pixel index = ref_wr_idx - 256 (0..CHR_MB_PIXELS-1)
                        begin : chr_wr_calc
                            reg [8:0] ci;
                            reg [17:0] ca;
                            ci = ref_wr_idx - 9'd256; // 0..CHR_MB_PIXELS-1
                            // Address = (mb_y*CHR_MB_HEIGHT + row) * CHR_WIDTH + mb_x*CHR_MB_WIDTH + col
                            if (CHR_MB_WIDTH == 16) begin
                                ca = ({14'd0, mb_y} * CHR_MB_HEIGHT[4:0] + {11'd0, ci[7:4]}) * CHR_WIDTH[10:0]
                                   + ({11'd0, mb_x} * CHR_MB_WIDTH[10:0]) + {14'd0, ci[3:0]};
                            end else begin
                                ca = ({14'd0, mb_y} * CHR_MB_HEIGHT[4:0] + {11'd0, ci[6:3]}) * CHR_WIDTH[10:0]
                                   + ({11'd0, mb_x} * CHR_MB_WIDTH[10:0]) + {15'd0, ci[2:0]};
                            end
                            chr_cb_ref_wr_en <= 1'b1;
                            chr_cb_ref_wr_addr <= ca;
                            chr_cb_ref_wr_data <= ref_cb_write_buf_w[ci*BD +: BD];
                            chr_cr_ref_wr_en <= 1'b1;
                            chr_cr_ref_wr_addr <= ca;
                            chr_cr_ref_wr_data <= ref_cr_write_buf_w[ci*BD +: BD];
                        end
                        ref_wr_idx <= ref_wr_idx + 9'd1;
                    end else begin
                        // Done writing this MB to reference, advance to next MB
                        if (mb_x == MB_COLS[6:0] - 7'd1) begin
                            mb_x <= 7'd0;
                            left_is_skip <= 1'b0;
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
                            chr_f_col <= {CHR_FETCH_COL_W{1'b0}};
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
                            integer bi_chr_idx;
                            reg [7:0] src_idx, src_r_idx, src_b_idx, src_br_idx;
                            reg [BD+8:0] interp_sum;
                            reg [3:0] stride; // 8 or 9
                            reg [6:0] wA, wB, wC, wD; // weights (max 64, need 7 bits)
                            reg [6:0] e_dx, e_dy, fx, fy;
                            reg [CHR_MB_PIXELS*BD-1:0] interp_cb_i, interp_cr_i;
                            reg skip_chroma_exact_i;
                            reg [BD-1:0] pred_cb_i, pred_cr_i;
                            reg [BD-1:0] bi_cb_i, bi_cr_i;
                            stride = chr_fetch_cols;
                            interp_cb_i = {(CHR_MB_PIXELS*BD){1'b0}};
                            interp_cr_i = {(CHR_MB_PIXELS*BD){1'b0}};
                            skip_chroma_exact_i = 1'b1;
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
                                for (ic = 0; ic < CHR_MB_WIDTH; ic = ic + 1) begin
                                    src_idx = ir[4:0] * stride + ic[3:0];
                                    if (chr_frac_x == 3'd0 && chr_frac_y == 3'd0) begin
                                        // No interpolation: direct copy
                                        pred_cb_i = chr_raw_cb[src_idx*BD +: BD];
                                        pred_cr_i = chr_raw_cr[src_idx*BD +: BD];
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
                                        pred_cb_i = interp_sum[BD+5:6];
                                        // Cr
                                        interp_sum = wA * {{(BD-2){1'b0}}, chr_raw_cr[src_idx*BD +: BD]}
                                                   + wB * {{(BD-2){1'b0}}, chr_raw_cr[src_r_idx*BD +: BD]}
                                                   + wC * {{(BD-2){1'b0}}, chr_raw_cr[src_b_idx*BD +: BD]}
                                                   + wD * {{(BD-2){1'b0}}, chr_raw_cr[src_br_idx*BD +: BD]}
                                                   + {{(BD+2){1'b0}}, 7'd32};
                                        pred_cr_i = interp_sum[BD+5:6];
                                    end
                                    interp_cb_i[(ir*CHR_MB_WIDTH+ic)*BD +: BD] = pred_cb_i;
                                    interp_cr_i[(ir*CHR_MB_WIDTH+ic)*BD +: BD] = pred_cr_i;
                                    if (fetched_cb[(ir*CHR_MB_WIDTH+ic)*BD +: BD] != pred_cb_i ||
                                        fetched_cr[(ir*CHR_MB_WIDTH+ic)*BD +: BD] != pred_cr_i)
                                        skip_chroma_exact_i = 1'b0;
                                end
                            end
                            if (is_b_frame && is_b_bi_mb_reg && !b_bi_chr_fetch_l1_phase) begin
                                b_bi_chr_pred_cb_l0 <= interp_cb_i;
                                b_bi_chr_pred_cr_l0 <= interp_cr_i;
                                chr_fetch_cnt <= {CHR_FETCH_W{1'b0}};
                                chr_fetch_started <= 1'b0;
                                chr_raw_cb <= {(CHR_RAW_SAMPLES*BD){1'b0}};
                                chr_raw_cr <= {(CHR_RAW_SAMPLES*BD){1'b0}};
                                chr_f_row <= 5'd0;
                                chr_f_col <= {CHR_FETCH_COL_W{1'b0}};
                                b_bi_chr_fetch_l1_phase <= 1'b1;
                                ref_rd_bank_sel <= newest_ref_bank;
                                chr_frac_x <= me_best_mvx_l1[2:0];
                                chr_frac_y <= me_best_mvy_l1[2:0];
                                chr_fetch_cols <= (me_best_mvx_l1[2:0] != 3'd0) ? (CHR_MB_WIDTH[CHR_FETCH_COL_W-1:0] + {{(CHR_FETCH_COL_W-1){1'b0}}, 1'b1}) : CHR_MB_WIDTH[CHR_FETCH_COL_W-1:0];
                                chr_fetch_rows <= (me_best_mvy_l1[2:0] != 3'd0) ? (CHR_MB_HEIGHT[4:0] + 5'd1) : CHR_MB_HEIGHT[4:0];
                            end else begin
                                if (is_b_frame && is_b_bi_mb_reg) begin
                                    for (bi_chr_idx = 0; bi_chr_idx < CHR_MB_PIXELS; bi_chr_idx = bi_chr_idx + 1) begin
                                        bi_cb_i = use_weighted_pred_w ?
                                            apply_chroma_cb_bi_weight(b_bi_chr_pred_cb_l0[bi_chr_idx*BD +: BD],
                                                                      interp_cb_i[bi_chr_idx*BD +: BD]) :
                                            ((b_bi_chr_pred_cb_l0[bi_chr_idx*BD +: BD] + interp_cb_i[bi_chr_idx*BD +: BD] + 1'b1) >> 1);
                                        bi_cr_i = use_weighted_pred_w ?
                                            apply_chroma_cr_bi_weight(b_bi_chr_pred_cr_l0[bi_chr_idx*BD +: BD],
                                                                      interp_cr_i[bi_chr_idx*BD +: BD]) :
                                            ((b_bi_chr_pred_cr_l0[bi_chr_idx*BD +: BD] + interp_cr_i[bi_chr_idx*BD +: BD] + 1'b1) >> 1);
                                        interp_cb_i[bi_chr_idx*BD +: BD] = bi_cb_i;
                                        interp_cr_i[bi_chr_idx*BD +: BD] = bi_cr_i;
                                        if (fetched_cb[bi_chr_idx*BD +: BD] != bi_cb_i ||
                                            fetched_cr[bi_chr_idx*BD +: BD] != bi_cr_i)
                                            skip_chroma_exact_i = 1'b0;
                                    end
                                end
                                inter_chr_pred_cb <= interp_cb_i;
                                inter_chr_pred_cr <= interp_cr_i;
                                // verilator lint_on BLKSEQ

                                inter_chr_prefetched_valid <= 1'b1;
                                b_bi_chr_fetch_l1_phase <= 1'b0;
                                if (skip_probe_pending) begin
                                    skip_probe_pending <= 1'b0;
                                    if (skip_chroma_exact_i) begin
                                        is_skip_mb_reg <= cabac_p16x16_supported_w ? 1'b0 : 1'b1;
                                        mb_has_residual <= 1'b0;
                                        recon_buf <= inter_pred_buf;
                                        luma_recon_buf <= inter_pred_buf;
                                        chr_recon_cb <= interp_cb_i;
                                        chr_recon_cr <= interp_cr_i;
                                        top_state <= cabac_p16x16_supported_w ? TS_SKIP_CLR_FIFO :
                                                                                       TS_SKIP_MB_HDR;
                                    end else begin
                                        top_state <= TS_MB_HDR;
                                    end
                                end else begin
                                    // Done: enter chroma processing
                                    top_state <= TS_CHROMA;
                                    chr_phase <= 3'd0;
                                    chr_blk <= {CHR_BLK_W{1'b0}};
                                    chr_is_cr <= 1'b0;
                                    recon_buf <= {(256*BD){1'b0}};
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
                        end
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
                    if (CHROMA_FORMAT_IDC == 3) begin
                        sub_blk <= chroma_sub_blk_from_idx(chr_is_cr, chr_blk);
                        case (blk_state)
                            BS_PRED: begin
                                if (inter_chr_mode) begin
                                    begin : chr444_inter_pred_calc
                                        // verilator lint_off BLKSEQ
                                        integer cj;
                                        reg [7:0] pidx;
                                        reg [BD-1:0] orig_pix;
                                        reg [BD-1:0] pred_pix;
                                        for (cj = 0; cj < 16; cj = cj + 1) begin
                                            pidx = chr_pix_idx(chr_blk_row_w, cj[3:0], chr_blk_col_w);
                                            if (chr_is_cr) begin
                                                orig_pix = fetched_cr[pidx*BD +: BD];
                                                pred_pix = inter_chr_pred_cr[pidx*BD +: BD];
                                                if (use_post_weighted_pred_w)
                                                    pred_pix = apply_chroma_cr_weight(pred_pix);
                                            end else begin
                                                orig_pix = fetched_cb[pidx*BD +: BD];
                                                pred_pix = inter_chr_pred_cb[pidx*BD +: BD];
                                                if (use_post_weighted_pred_w)
                                                    pred_pix = apply_chroma_cb_weight(pred_pix);
                                            end
                                            chr_resid_4x4[cj*BD1 +: BD1] = {1'b0, orig_pix} - {1'b0, pred_pix};
                                        end
                                        // verilator lint_on BLKSEQ
                                    end
                                    chr_pred_mode <= 1'b1;
                                    blk_state <= BS_XFORM;
                                    blk_started <= 1'b0;
                                end else begin
                                    chr_pred_mode <= 1'b0;
                                    if (!blk_started) begin
                                        pred_start <= 1'b1;
                                        blk_started <= 1'b1;
                                    end else if (pred_done) begin
                                        blk_state <= BS_XFORM;
                                        blk_started <= 1'b0;
                                    end
                                end
                            end
                            BS_XFORM: begin
                                if (!blk_started) begin
                                    xform_start <= 1'b1;
                                    blk_started <= 1'b1;
                                end else if (xform_done) begin
                                    blk_state <= BS_QUANT;
                                    blk_started <= 1'b0;
                                end
                            end
                            BS_QUANT: begin
                                if (!blk_started) begin
                                    quant_start <= 1'b1;
                                    blk_started <= 1'b1;
                                end else if (quant_done) begin
                                    blk_state <= BS_ZIGZAG;
                                    blk_started <= 1'b0;
                                end
                            end
                            BS_ZIGZAG: begin
                                if (!blk_started) begin
                                    use_chr_dc_zigzag <= 1'b0;
                                    use_chr_ac_zigzag <= 1'b0;
                                    use_chr_iq_input <= 1'b0;
                                    use_chr_it_input <= 1'b0;
                                    zz_chroma_dc_mode <= 1'b0;
                                    zz_chroma_ac_mode <= 1'b0;
                                    cavlc_is_chroma_dc <= 1'b0;
                                    cavlc_is_chroma_ac <= 1'b0;
                                    zz_start <= 1'b1;
                                    iq_start <= 1'b1;
                                    blk_started <= 1'b1;
                                    iq_done_latched <= 1'b0;
                                end else begin
                                    if (iq_done)
                                        iq_done_latched <= 1'b1;
                                    if (zz_done) begin
                                        cabac_chroma_scan_flat_reg[cabac_chroma_payload_blk_idx(chr_is_cr, chr_blk) * 256 +: 256] <= scan_flat;
                                        cabac_chroma_nz_mask_reg[cabac_chroma_payload_blk_idx(chr_is_cr, chr_blk)] <= (total_coeffs != 5'd0);
                                        nz_coeff[chroma_sub_blk_from_idx(chr_is_cr, chr_blk)] <= total_coeffs;
                                        if (total_coeffs != 5'd0)
                                            i16_chroma_ac_nonzero <= 1'b1;
                                        blk_state <= BS_CAVLC;
                                        blk_started <= 1'b0;
                                    end
                                end
                            end
                            BS_CAVLC: begin
                                if (!blk_started && !bs_busy) begin
                                    cavlc_start <= 1'b1;
                                    blk_started <= 1'b1;
                                end else begin
                                    if (iq_done)
                                        iq_done_latched <= 1'b1;
                                    if (cavlc_done) begin
                                        blk_state <= BS_IQ;
                                        blk_started <= 1'b0;
                                    end
                                end
                            end
                            BS_IQ: begin
                                if (iq_done || iq_done_latched) begin
                                    blk_state <= BS_IT;
                                    blk_started <= 1'b0;
                                end else if (iq_done) begin
                                    iq_done_latched <= 1'b1;
                                end
                            end
                            BS_IT: begin
                                if (!blk_started) begin
                                    it_start <= 1'b1;
                                    blk_started <= 1'b1;
                                end else if (it_done) begin
                                    blk_state <= BS_RECON;
                                    blk_started <= 1'b0;
                                end
                            end
                            BS_RECON: begin
                                if (!blk_started) begin
                                    recon_start <= 1'b1;
                                    blk_started <= 1'b1;
                                end else if (recon_done) begin
                                    if (chr_is_cr)
                                        chr_recon_cr <= recon_out_w;
                                    else
                                        chr_recon_cb <= recon_out_w;
                                    recon_buf <= recon_out_w;
                                    if (chr_blk == CHR_BLOCKS_PER_PLANE - 1) begin
                                        if (chr_is_cr) begin
                                            reg mb_nonzero_i;
                                            integer nz_i;
                                            if (use_intra16_mb_reg) begin
                                                i16_cbp_chroma <= 2'd2;
                                                intra_mb_type_code_num <= intra_i16_base_type_code
                                                                        + {4'd0, intra16_mode_mb}
                                                                        + 6'd8
                                                                        + 6'd12;
                                            end
                                            if (is_inter_mb_reg) begin
                                                mb_nonzero_i = (total_coeffs != 5'd0);
                                                for (nz_i = 0; nz_i < TOTAL_SUB_BLOCKS; nz_i = nz_i + 1) begin
                                                    if (nz_coeff[nz_i] != 5'd0)
                                                        mb_nonzero_i = 1'b1;
                                                end
                                                mb_has_residual <= mb_nonzero_i;
                                                if (!mb_nonzero_i) begin
                                                    is_skip_mb_reg <= cabac_p16x16_supported_w ? 1'b0 :
                                                                      (pskip_syntax_eligible_reg || bskip_syntax_eligible_reg);
                                                    top_state <= TS_SKIP_CLR_FIFO;
                                                end else begin
                                                    top_state <= TS_DEFER_MB_HDR;
                                                end
                                            end else begin
                                                top_state <= TS_DEFER_MB_HDR;
                                            end
                                            blk_started <= 1'b0;
                                        end else begin
                                            chr_is_cr <= 1'b1;
                                            chr_blk <= {CHR_BLK_W{1'b0}};
                                            recon_buf <= {(256*BD){1'b0}};
                                            blk_state <= BS_PRED;
                                            blk_started <= 1'b0;
                                        end
                                    end else begin
                                        chr_blk <= chr_blk + 1'b1;
                                        blk_state <= BS_PRED;
                                        blk_started <= 1'b0;
                                    end
                                end
                            end
                            default: blk_state <= BS_PRED;
                        endcase
                    end else begin
                    case (chr_phase)
                        // Phase 0: pred → xform (capture raw DC) → quant (save quant buf) per 4x4 block
                        3'd0: begin
                            case (blk_state)
                                BS_PRED: begin
                                    sub_blk <= chroma_sub_blk_from_idx(chr_is_cr, chr_blk);
                                    chr_pred_mode <= 1'b1;
                                    if (inter_chr_mode) begin
                                        // Inter chroma: use reference block as prediction
                                        begin : chr_inter_pred_calc
                                            // verilator lint_off BLKSEQ
                                            integer cj;
                                            reg [7:0] pidx;
                                            reg [BD-1:0] orig_pix, pred_pix;
                                            for (cj = 0; cj < 16; cj = cj + 1) begin
                                                pidx = chr_pix_idx(chr_blk_row_w, cj[3:0], chr_blk_col_w);
                                                if (chr_is_cr) begin
                                                    orig_pix = fetched_cr[pidx*BD +: BD];
                                                    pred_pix = inter_chr_pred_cr[pidx*BD +: BD];
                                                    if (use_post_weighted_pred_w)
                                                        pred_pix = apply_chroma_cr_weight(pred_pix);
                                                end else begin
                                                    orig_pix = fetched_cb[pidx*BD +: BD];
                                                    pred_pix = inter_chr_pred_cb[pidx*BD +: BD];
                                                    if (use_post_weighted_pred_w)
                                                        pred_pix = apply_chroma_cb_weight(pred_pix);
                                                end
                                                chr_resid_4x4[cj*BD1 +: BD1] = {1'b0, orig_pix} - {1'b0, pred_pix};
                                            end
                                            // verilator lint_on BLKSEQ
                                        end
                                    end else begin
                                        // Intra chroma: H.264 8x8 DC prediction
                                        begin : chr_dc_pred_calc
                                            // verilator lint_off BLKSEQ
                                            reg [CHR_MB_WIDTH*BD-1:0] top_nb;
                                            reg [16*BD-1:0] left_nb_full;
                                            reg [BD+2:0] s0, s1, s2, s3, s4, s5, s6, s7;
                                            reg [BD+3:0] top_sum_i, left_sum_i;
                                            reg [1:0] blk_row_i, blk_col_i;
                                            reg [BD-1:0] dc_val;
                                            reg ta, la;
                                            integer cj;
                                            integer edge_i;

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

                                            if (CHROMA_FORMAT_IDC == 3) begin
                                                blk_row_i = chr_blk_row_w;
                                                blk_col_i = chr_blk_col_w;
                                                top_sum_i = {(BD+4){1'b0}};
                                                left_sum_i = {(BD+4){1'b0}};
                                                for (edge_i = 0; edge_i < 4; edge_i = edge_i + 1) begin
                                                    top_sum_i = top_sum_i + {{4{1'b0}}, top_nb[((blk_col_i * 4) + edge_i)*BD +: BD]};
                                                    left_sum_i = left_sum_i + {{4{1'b0}}, left_nb_full[((blk_row_i * 4) + edge_i)*BD +: BD]};
                                                end
                                                if (ta && la) dc_val = (top_sum_i + left_sum_i + {{(BD+1){1'b0}}, 3'd4}) >> 3;
                                                else if (ta)  dc_val = (top_sum_i + {{(BD+2){1'b0}}, 2'd2}) >> 2;
                                                else if (la)  dc_val = (left_sum_i + {{(BD+2){1'b0}}, 2'd2}) >> 2;
                                                else          dc_val = {1'b1, {(BD-1){1'b0}}};
                                            end else begin
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
                                                    3'd4: begin
                                                        if (la)       dc_val = (s4 + {{(BD+1){1'b0}}, 2'd2}) >> 2;
                                                        else          dc_val = {1'b1, {(BD-1){1'b0}}};
                                                    end
                                                    3'd5: begin
                                                        if (la)       dc_val = (s4 + {{(BD+1){1'b0}}, 2'd2}) >> 2;
                                                        else          dc_val = {1'b1, {(BD-1){1'b0}}};
                                                    end
                                                    3'd6: begin
                                                        if (la)       dc_val = (s5 + {{(BD+1){1'b0}}, 2'd2}) >> 2;
                                                        else          dc_val = {1'b1, {(BD-1){1'b0}}};
                                                    end
                                                    default: begin
                                                        if (la)       dc_val = (s5 + {{(BD+1){1'b0}}, 2'd2}) >> 2;
                                                        else          dc_val = {1'b1, {(BD-1){1'b0}}};
                                                    end
                                                endcase
                                            end
                                            chr_dc_pred[chr_blk] <= dc_val;

                                            for (cj = 0; cj < 16; cj = cj + 1) begin
                                                reg [7:0] pidx;
                                                reg [BD-1:0] orig_pix;
                                                pidx = chr_pix_idx(chr_blk_row_w, cj[3:0], chr_blk_col_w);
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
                                        integer cb_pred_i;
                                        // Save quantized block (for AC coeffs in bitstream & reconstruction)
                                        if (chr_is_cr)
                                            cr_quant_buf[chr_blk] <= quant_out_flat;
                                        else
                                            cb_quant_buf[chr_blk] <= quant_out_flat;
                                        if (chr_blk == CHR_BLOCKS_PER_PLANE - 1) begin
                                            chr_pred_mode <= 1'b0;
                                            if (CHROMA_FORMAT_IDC == 3) begin
                                                if (chr_is_cr) begin
                                                    chr_is_cr <= 1'b0;
                                                    chr_recon_blk <= {CHR_BLK_W{1'b0}};
                                                    chr_phase <= 3'd6;
                                                    blk_state <= BS_PRED;
                                                end else begin
                                                    for (cb_pred_i = 0; cb_pred_i < CHR_BLOCKS_PER_PLANE; cb_pred_i = cb_pred_i + 1)
                                                        cb_dc_pred_saved[cb_pred_i] <= chr_dc_pred[cb_pred_i];
                                                    chr_is_cr <= 1'b1;
                                                    chr_blk <= {CHR_BLK_W{1'b0}};
                                                    blk_state <= BS_PRED;
                                                end
                                            end else begin
                                                chr_phase <= 3'd1;
                                            end
                                            blk_started <= 1'b0;
                                        end else begin
                                            chr_blk <= chr_blk + 1'b1;
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
                                    chr_recon_blk <= {CHR_BLK_W{1'b0}};
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
                                    chr_blk <= {CHR_BLK_W{1'b0}};
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
                                    if (total_coeffs != 5'd0)
                                        i16_chroma_dc_nonzero <= 1'b1;
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
                                    if (total_coeffs != 5'd0)
                                        i16_chroma_dc_nonzero <= 1'b1;
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
                                    chr_blk <= {CHR_BLK_W{1'b0}};
                                    chr_is_cr <= 1'b0;
                                    blk_state <= BS_PRED;
                                end
                                default: blk_state <= BS_PRED;
                            endcase
                        end

                        // Phase 5: zigzag + CAVLC chroma AC (Cb×4 then Cr×4)
                        3'd5: begin
                            sub_blk <= chroma_sub_blk_from_idx(chr_is_cr, chr_blk);
                            case (blk_state)
                                BS_PRED: begin
                                    if (chr_is_cr)
                                        chr_ac_zigzag_in <= (CHROMA_FORMAT_IDC == 3) ? cr_quant_buf[chr_blk] : {cr_quant_buf[chr_blk][255:16], 16'd0};
                                    else
                                        chr_ac_zigzag_in <= (CHROMA_FORMAT_IDC == 3) ? cb_quant_buf[chr_blk] : {cb_quant_buf[chr_blk][255:16], 16'd0};
                                    use_chr_ac_zigzag <= 1'b1;
                                    use_chr_dc_zigzag <= 1'b0;
                                    zz_chroma_dc_mode <= 1'b0;
                                    zz_chroma_ac_mode <= (CHROMA_FORMAT_IDC != 3);
                                    cavlc_is_chroma_dc <= 1'b0;
                                    cavlc_is_chroma_ac <= (CHROMA_FORMAT_IDC != 3);
                                    zz_start <= 1'b1;
                                    blk_state <= BS_ZIGZAG;
                                end
                                BS_ZIGZAG: if (zz_done) begin
                                    cabac_chroma_scan_flat_reg[cabac_chroma_payload_blk_idx(chr_is_cr, chr_blk) * 256 +: 256] <= scan_flat;
                                    cabac_chroma_nz_mask_reg[cabac_chroma_payload_blk_idx(chr_is_cr, chr_blk)] <= (total_coeffs != 5'd0);
                                    nz_coeff[chroma_sub_blk_from_idx(chr_is_cr, chr_blk)] <= total_coeffs;
                                    if (total_coeffs != 5'd0)
                                        i16_chroma_ac_nonzero <= 1'b1;
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
                                    if (chr_blk == CHR_BLOCKS_PER_PLANE - 1) begin
                                        if (chr_is_cr) begin
                                            reg mb_nonzero_i;
                                            integer nz_i;
                                            use_chr_ac_zigzag <= 1'b0;
                                            cavlc_is_chroma_ac <= 1'b0;
                                            zz_chroma_ac_mode <= 1'b0;
                                            if (use_intra16_mb_reg) begin
                                                // The current I16 path always emits luma AC and chroma AC
                                                // residual syntax, even when the coefficients are all zero.
                                                // Keep mb_type aligned with the emitted syntax so FFmpeg
                                                // does not desynchronize while parsing macroblock residuals.
                                                i16_cbp_chroma <= 2'd2;
                                                intra_mb_type_code_num <= intra_i16_base_type_code
                                                                        + {4'd0, intra16_mode_mb}
                                                                        + 6'd8
                                                                        + 6'd12;
                                            end
                                            if (is_inter_mb_reg) begin
                                                mb_nonzero_i = i16_chroma_dc_nonzero || (total_coeffs != 5'd0);
                                                for (nz_i = 0; nz_i < TOTAL_SUB_BLOCKS; nz_i = nz_i + 1) begin
                                                    if (nz_coeff[nz_i] != 5'd0)
                                                        mb_nonzero_i = 1'b1;
                                                end
                                                mb_has_residual <= mb_nonzero_i;
                                                if (!mb_nonzero_i) begin
                                                    is_skip_mb_reg <= cabac_p16x16_supported_w ? 1'b0 :
                                                                      (pskip_syntax_eligible_reg || bskip_syntax_eligible_reg);
                                                    top_state <= TS_SKIP_CLR_FIFO;
                                                end else begin
                                                    top_state <= TS_DEFER_MB_HDR;
                                                end
                                            end else begin
                                                top_state <= TS_DEFER_MB_HDR;
                                            end
                                            blk_started <= 1'b0;
                                        end else begin
                                            chr_is_cr <= 1'b1;
                                            chr_blk <= {CHR_BLK_W{1'b0}};
                                            blk_state <= BS_PRED;
                                        end
                                    end else begin
                                        chr_blk <= chr_blk + 1'b1;
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
                                        chr_iq_input <= (CHROMA_FORMAT_IDC == 3) ? cr_quant_buf[chr_recon_blk] : {cr_quant_buf[chr_recon_blk][255:16], 16'd0};
                                    else
                                        chr_iq_input <= (CHROMA_FORMAT_IDC == 3) ? cb_quant_buf[chr_recon_blk] : {cb_quant_buf[chr_recon_blk][255:16], 16'd0};
                                    use_chr_iq_input <= 1'b1;
                                    iq_start <= 1'b1;
                                    blk_state <= BS_ZIGZAG; // reuse as IQ wait state
                                    iq_done_latched <= 1'b0;
                                end
                                BS_ZIGZAG: begin // waiting for IQ
                                    if (iq_done || iq_done_latched) begin
                                        use_chr_it_input <= (CHROMA_FORMAT_IDC != 3);
                                        if (CHROMA_FORMAT_IDC != 3) begin
                                            if (chr_is_cr)
                                                chr_it_dc_patch <= cr_inv_dc[chr_recon_blk];
                                            else
                                                chr_it_dc_patch <= cb_inv_dc[chr_recon_blk];
                                        end
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
                                            reg [7:0] pix_idx_0;
                                            reg signed [16:0] sum_0;
                                            reg [BD-1:0] clamp_0, pred_val;
                                            for (ci = 0; ci < 16; ci = ci + 1) begin
                                                pix_idx_0 = chr_pix_idx(chr_recon_blk_row_w, ci[3:0], chr_recon_blk_col_w);
                                                if (inter_chr_mode) begin
                                                    if (chr_is_cr)
                                                        pred_val = inter_chr_pred_cr[pix_idx_0*BD +: BD];
                                                    else
                                                        pred_val = inter_chr_pred_cb[pix_idx_0*BD +: BD];
                                                    if (use_post_weighted_pred_w) begin
                                                        if (chr_is_cr)
                                                            pred_val = apply_chroma_cr_weight(pred_val);
                                                        else
                                                            pred_val = apply_chroma_cb_weight(pred_val);
                                                    end
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
                                        if (chr_recon_blk == CHR_BLOCKS_PER_PLANE - 1) begin
                                            if (chr_is_cr) begin
                                                chr_phase <= (CHROMA_FORMAT_IDC == 3) ? 3'd5 : 3'd3;
                                                chr_blk <= {CHR_BLK_W{1'b0}};
                                                chr_is_cr <= 1'b0;
                                                blk_state <= BS_PRED;
                                                blk_started <= 1'b0;
                                            end else begin
                                                chr_is_cr <= 1'b1;
                                                chr_recon_blk <= {CHR_BLK_W{1'b0}};
                                                blk_state <= BS_PRED;
                                                blk_started <= 1'b0;
                                            end
                                        end else begin
                                            chr_recon_blk <= chr_recon_blk + 1'b1;
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
                end

                TS_TRAILING: if (!bs_busy) begin bs_cmd_trailing <= 1'b1; flush_pending <= 1'b0; flush_accepted <= 1'b0; top_state <= TS_DONE; end
                TS_DONE: if (!flush_pending) begin if (bs_cmd_done) begin bs_cmd_flush <= 1'b1; flush_pending <= 1'b1; end end
                         else if (!flush_accepted) flush_accepted <= 1'b1;
                         else if (bs_cmd_done) begin
                             done <= 1'b1;
                            $display("[PSKIP] Frame %0d skip_mbs=%0d b_l1_mbs=%0d b_bi_mbs=%0d b_direct_mbs=%0d b_l0_refgt0_mbs=%0d b_direct_refgt0_mbs=%0d b_direct_l1src_mbs=%0d cabac_p16x16_mbs=%0d",
                                     cur_frame_num, frame_skip_mb_count, frame_b_l1_mb_count, frame_b_bi_mb_count, frame_b_direct_mb_count, frame_b_l0_nonzero_ref_mb_count, frame_b_direct_nonzero_ref_mb_count, frame_b_direct_from_l1_mb_count, frame_cabac_p16x16_mb_count);
                             refbank_poc_lsb[current_write_bank] <= cur_pic_order_cnt_lsb;
                            if (is_p_frame) begin
                                refbank_has_l0_ref0[current_write_bank] <= (valid_ref_count != 3'd0);
                                refbank_l0_ref0_bank[current_write_bank] <= newest_ref_bank;
                                refbank_has_l0_ref1[current_write_bank] <= (valid_ref_count >= 3'd2);
                                refbank_l0_ref1_bank[current_write_bank] <= older_ref_bank;
                                refbank_has_l0_ref2[current_write_bank] <= (valid_ref_count >= 3'd3);
                                refbank_l0_ref2_bank[current_write_bank] <= oldest_ref_bank;
                                refbank_has_l1_ref0[current_write_bank] <= 1'b0;
                                refbank_l1_ref0_bank[current_write_bank] <= 3'd0;
                                ancient_ref_bank <= oldest_ref_bank;
                                oldest_ref_bank <= older_ref_bank;
                                older_ref_bank <= newest_ref_bank;
                                newest_ref_bank <= current_write_bank;
                                valid_ref_count <= (valid_ref_count < 3'd4) ? (valid_ref_count + 3'd1) : 3'd4;
                                next_write_bank <= pick_free_ref_bank(current_write_bank, newest_ref_bank, older_ref_bank, oldest_ref_bank);
                            end else if (is_b_ref_frame) begin
                                refbank_has_l0_ref0[current_write_bank] <= (valid_ref_count != 3'd0);
                                refbank_l0_ref0_bank[current_write_bank] <= b_l0_ref_bank_w;
                                refbank_has_l0_ref1[current_write_bank] <= (valid_ref_count >= 3'd3);
                                refbank_l0_ref1_bank[current_write_bank] <= oldest_ref_bank;
                                refbank_has_l0_ref2[current_write_bank] <= (valid_ref_count >= 3'd4);
                                refbank_l0_ref2_bank[current_write_bank] <= ancient_ref_bank;
                                refbank_has_l1_ref0[current_write_bank] <= (valid_ref_count != 3'd0);
                                refbank_l1_ref0_bank[current_write_bank] <= newest_ref_bank;
                                ancient_ref_bank <= oldest_ref_bank;
                                oldest_ref_bank <= older_ref_bank;
                                older_ref_bank <= newest_ref_bank;
                                 newest_ref_bank <= current_write_bank;
                                 valid_ref_count <= (valid_ref_count < 3'd4) ? (valid_ref_count + 3'd1) : 3'd4;
                                 next_write_bank <= pick_free_ref_bank(current_write_bank, newest_ref_bank, older_ref_bank, oldest_ref_bank);
                             end else if (is_b_frame) begin
                                 next_write_bank <= current_write_bank;
                             end else begin
                                 refbank_has_l0_ref0[current_write_bank] <= 1'b0;
                                 refbank_l0_ref0_bank[current_write_bank] <= 3'd0;
                                 refbank_has_l0_ref1[current_write_bank] <= 1'b0;
                                 refbank_l0_ref1_bank[current_write_bank] <= 3'd0;
                                 refbank_has_l0_ref2[current_write_bank] <= 1'b0;
                                 refbank_l0_ref2_bank[current_write_bank] <= 3'd0;
                                 refbank_has_l1_ref0[current_write_bank] <= 1'b0;
                                 refbank_l1_ref0_bank[current_write_bank] <= 3'd0;
                                 newest_ref_bank <= current_write_bank;
                                 older_ref_bank <= current_write_bank;
                                 oldest_ref_bank <= current_write_bank;
                                 ancient_ref_bank <= current_write_bank;
                                 valid_ref_count <= 3'd1;
                                 next_write_bank <= pick_free_ref_bank(current_write_bank, current_write_bank, current_write_bank, current_write_bank);
                             end
                             top_state <= TS_IDLE;
                             dbg_frame_cnt <= dbg_frame_cnt + 8'd1;
                         end
                default: top_state <= TS_IDLE;
            endcase

        end
    end

    localparam DEBUG_TRACE = 1'b1;
    localparam [7:0] DEBUG_FRAME = 8'd1;
    localparam signed [12:0] DEBUG_MB_START = 13'sd0;
    localparam signed [12:0] DEBUG_MB_END = 13'sd1;

    // Debug: frame counter and CAVLC trace
    reg [7:0] dbg_frame_cnt;
    initial dbg_frame_cnt = 8'd0;

    /* verilator lint_off UNUSED */
    wire dbg_target_mb = DEBUG_TRACE && (dbg_frame_cnt == DEBUG_FRAME);
    wire dbg_detail_mb = DEBUG_TRACE && (dbg_frame_cnt == DEBUG_FRAME) &&
                         ($signed({1'b0, mb_count}) >= DEBUG_MB_START) &&
                         ($signed({1'b0, mb_count}) <= DEBUG_MB_END);
    /* verilator lint_on UNUSED */

    always @(posedge clk) begin
        // dbg_frame_cnt is reset and advanced in the main FSM block; keep this
        // debug trace block read-only to avoid multi-driver/reset lint noise.
        if (dbg_detail_mb && zz_done) begin
            $display("[ZZD] F%0d MB%0d sb=%0d isL=%0d isCb=%0d isCr=%0d nC=%0d TC=%0d T1=%0d last=%0d chDC=%0d chAC=%0d",
                dbg_frame_cnt, mb_count, sub_blk, is_luma, is_cb, is_cr, nC_val, total_coeffs, trailing_ones, last_nonzero_idx, cavlc_is_chroma_dc, cavlc_is_chroma_ac);
            $display("[ZZS] F%0d MB%0d sb=%0d scan=%064x_%064x_%064x_%064x",
                dbg_frame_cnt, mb_count, sub_blk,
                scan_flat[255:192], scan_flat[191:128], scan_flat[127:64], scan_flat[63:0]);
        end
        if (dbg_detail_mb && cavlc_bits_valid) begin
            $display("[CVO] F%0d MB%0d sb=%0d bits=%08x count=%0d chDC=%0d",
                dbg_frame_cnt, mb_count, sub_blk, cavlc_bits, cavlc_count, cavlc_is_chroma_dc);
        end
        if (DEBUG_TRACE && dbg_frame_cnt == DEBUG_FRAME && bs_cmd_mb_hdr) begin
            $display("[MBH] F%0d MB%0d x=%0d y=%0d inter=%0d ref=%0d rbank=%0d wbank=%0d mvx=%0d mvy=%0d mvpx=%0d mvpy=%0d mvdx=%0d mvdy=%0d type=%0d predbits=%016x predcnt=%0d bytes=%0d",
                dbg_frame_cnt, mb_count, mb_x, mb_y, is_inter_mb_reg,
                mb_ref_idx_reg, ref_rd_bank_sel, ref_wr_bank_sel,
                $signed(me_best_mvx), $signed(me_best_mvy),
                $signed(mvp_x), $signed(mvp_y),
                $signed(mvd_x_w), $signed(mvd_y_w),
                intra_mb_type_code_num, intra_pred_bits_mb, intra_pred_count_mb,
                bs_bytes_written);
        end
        if (dbg_detail_mb && !is_inter_mb_reg && !use_intra16_mb_reg &&
            top_state == TS_ENCODE_SBLK && blk_state == BS_PRED && pred_done && is_luma) begin
            $display("[I4] F%0d MB%0d sb=%0d mode=%0d mpm=%0d prev=%0d rem=%0d bits=%016x count=%0d",
                dbg_frame_cnt, mb_count, sub_blk, pred_mode_w, intra_mpm_w,
                intra_prev_flag_w, intra_rem_mode_w, intra_pred_bits_mb, intra_pred_count_mb);
            $display("[I4D] F%0d MB%0d sb=%0d rc=%0d,%0d tl=%0d top=%0d,%0d,%0d,%0d left=%0d,%0d,%0d,%0d pred0=%0d pred1=%0d pred2=%0d pred3=%0d",
                dbg_frame_cnt, mb_count, sub_blk, sb_r, sb_c, sb_top_left_pixel,
                sb_top_pixels[0*BD +: BD], sb_top_pixels[1*BD +: BD], sb_top_pixels[2*BD +: BD], sb_top_pixels[3*BD +: BD],
                sb_left_pixels[0*BD +: BD], sb_left_pixels[1*BD +: BD], sb_left_pixels[2*BD +: BD], sb_left_pixels[3*BD +: BD],
                pred_4x4_w[0*BD +: BD], pred_4x4_w[1*BD +: BD], pred_4x4_w[2*BD +: BD], pred_4x4_w[3*BD +: BD]);
        end
    end

endmodule
