// h264_bitstream.v — Bitstream Assembler / NAL Unit Writer
// Collects bits and assembles into byte-aligned H.264 bitstream
// Handles: NAL start codes, SPS, PPS, slice header, MB header, trailing bits
// Emulation prevention (0x000003 stuffing)
//
// Bit buffer convention: bits are stored left-justified (MSB-first) in bit_buf.
// bit_cnt tracks how many valid bits are in the buffer, starting from bit_buf[95].
// Byte emission takes bit_buf[95:88] and shifts left by 8.

module h264_bitstream #(
    parameter MB_COLS = 20,
    parameter MB_ROWS = 11,
    parameter BIT_DEPTH = 8,
    parameter CHROMA_FORMAT_IDC = 1,
    parameter FRAME_RATE = 24,
    parameter DEBLOCK_ENABLE = 1,
    parameter DISABLE_DEBLOCKING_FILTER_IDC = 0,
    parameter DEBUG_CABAC_P16X16 = 1'b0
) (
    input  wire        clk,
    input  wire        rst_n,

    // Control commands (active-high pulses)
    input  wire        cmd_write_sps,
    input  wire        cmd_write_pps,
    input  wire        cmd_write_slice_hdr,
    input  wire        cmd_write_mb_header,
    input  wire        cmd_write_trailing,
    input  wire        cmd_flush,
    input  wire        cmd_clear_fifo,

    // Bits from CAVLC encoder
    input  wire        cavlc_valid,
    input  wire [31:0] cavlc_bits,
    input  wire [5:0]  cavlc_count,
    input  wire [3:0]  cavlc_cbp_luma,
    input  wire [1:0]  cavlc_cbp_chroma,
    input  wire        transform_8x8_mode_enable,
    input  wire        transform_size_8x8_flag,
    input  wire signed [8:0] pic_init_qp_minus26,
    input  wire signed [8:0] chroma_qp_index_offset,
    input  wire signed [8:0] second_chroma_qp_index_offset,

    // MB coding info
    /* verilator lint_off UNUSED */
    input  wire signed [8:0] mb_qp_delta,
    /* verilator lint_on UNUSED */
    input  wire        mb_has_residual,
    input  wire        cabac_feature_enable,
    input  wire        cabac_slice_enable,
    input  wire [1:0]  cabac_skip_ctx,

    // Slice-type support
    input  wire        is_p_slice,
    input  wire        is_b_slice,
    input  wire        is_b_ref_slice,
    input  wire [7:0]  frame_num,
    input  wire [8:0]  pic_order_cnt_lsb,
    input  wire        is_inter_mb,
    input  wire        is_skip_mb,
    input  wire        is_b_direct_mb,
    input  wire        is_b_l1_mb,
    input  wire        is_b_bi_mb,
    input  wire        direct_spatial_mv_pred_flag,
    input  wire [1:0]  mb_ref_idx_l0,
    input  wire [1:0]  mb_ref_idx_l0_part1,
    input  wire [1:0]  mb_ref_idx_l1,
    input  wire [1:0]  p_partition_mode,
    input  wire [1:0]  p_sub_mb_type,
    input  wire signed [8:0] mvd_x_l0,
    input  wire signed [8:0] mvd_y_l0,
    input  wire signed [8:0] mvd_x_l0_part1,
    input  wire signed [8:0] mvd_y_l0_part1,
    input  wire signed [8:0] mvd_x_l1,
    input  wire signed [8:0] mvd_y_l1,
    input  wire [1:0]  cabac_mvd_ctx_x,
    input  wire [1:0]  cabac_mvd_ctx_y,
    input  wire [1:0]  cabac_cbp_luma_ctx0_sel,
    input  wire [1:0]  cabac_cbp_luma_ctx1_sel,
    input  wire [1:0]  cabac_cbp_luma_ctx2_sel,
    input  wire [3:0]  cabac_cbp_luma,
    input  wire [1:0]  cabac_cbp_chroma,
    input  wire [4095:0] cabac_luma_scan_flat,
    input  wire [15:0] cabac_luma_nz_mask,
    input  wire [511:0] cabac_chroma_dc_scan_flat,
    input  wire [8191:0] cabac_chroma_ac_scan_flat,
    input  wire [1:0]  slice_num_ref_idx_l0_active_minus1,
    input  wire        hold_fifo_drain,
    input  wire        is_intra16_mb,
    input  wire        is_ipcm_mb,
    input  wire        force_transform_8x8_in,
    input  wire [5:0]  intra_mb_type_code_num,
    input  wire [63:0] intra_pred_bits,
    input  wire [6:0]  intra_pred_count,
    input  wire [256*BIT_DEPTH-1:0] ipcm_luma_flat,
    input  wire [(((CHROMA_FORMAT_IDC == 3) ? 256 : ((CHROMA_FORMAT_IDC == 2) ? 128 : 64))*BIT_DEPTH)-1:0] ipcm_cb_flat,
    input  wire [(((CHROMA_FORMAT_IDC == 3) ? 256 : ((CHROMA_FORMAT_IDC == 2) ? 128 : 64))*BIT_DEPTH)-1:0] ipcm_cr_flat,
    input  wire        weighted_pred_enable,
    input  wire [3:0]  luma_log2_weight_denom,
    input  wire signed [8:0] luma_weight,
    input  wire signed [8:0] luma_offset,
    input  wire [3:0]  chroma_log2_weight_denom,
    input  wire signed [8:0] chroma_weight_cb,
    input  wire signed [8:0] chroma_offset_cb,
    input  wire signed [8:0] chroma_weight_cr,
    input  wire signed [8:0] chroma_offset_cr,

    output reg         busy,
    output reg         cmd_done,

    // Memory write port
    output reg  [23:0] bs_mem_addr,
    output reg  [7:0]  bs_mem_data,
    output reg         bs_mem_wr,
    output reg  [23:0] bs_bytes_written
);

    // Bit accumulator — bits are MSB-justified
    // bit_buf[95] is the first bit to be emitted.
    // 96 bits wide to absorb a max-32-bit CAVLC fragment while holding 64 bits.
    reg [95:0] bit_buf;
    reg [6:0]  bit_cnt;  // number of valid bits (0..96)

    // Emulation prevention
    reg [1:0]  zero_cnt;

    // FSM
    localparam S_IDLE    = 4'd0;
    localparam S_SPS     = 4'd1;
    localparam S_PPS     = 4'd2;
    localparam S_SLICE   = 4'd3;
    localparam S_MB_HDR  = 4'd4;
    localparam S_TRAIL   = 4'd5;
    localparam S_EMIT    = 4'd6;
    localparam S_FLUSH   = 4'd7;
    localparam S_CABAC_RES = 4'd8;

    reg [3:0]  state;
    reg [3:0]  return_state;
    reg [6:0]  sub;

    // Byte to write
    reg        do_write;
    reg [7:0]  write_byte;

    // CAVLC input buffer — holds one pending fragment when we're busy

    // =====================================================================
    // CAVLC Output FIFO (absorbs bursty bit emission)
    //
    // Deferred intra MB header emission can hold draining for an entire MB.
    // The previous 64-entry FIFO overflowed on 4:4:4 residual bursts and
    // silently dropped later CAVLC fragments, corrupting the slice RBSP.
    // =====================================================================
    localparam integer CAVLC_FIFO_DEPTH = 2048;
    localparam integer CAVLC_FIFO_LAST  = CAVLC_FIFO_DEPTH - 1;
    localparam integer CAVLC_FIFO_PTR_W = 11;

    reg [37:0] cavlc_fifo [0:CAVLC_FIFO_LAST]; // 32 bits data + 6 bits count
    reg [CAVLC_FIFO_PTR_W-1:0] fifo_wr_ptr;
    reg [CAVLC_FIFO_PTR_W-1:0] fifo_rd_ptr;
    wire [CAVLC_FIFO_PTR_W-1:0] fifo_count = fifo_wr_ptr - fifo_rd_ptr;
    wire       fifo_empty = (fifo_wr_ptr == fifo_rd_ptr);
    wire       fifo_full  = (fifo_count == CAVLC_FIFO_LAST);

    wire [37:0] fifo_rd_data = cavlc_fifo[fifo_rd_ptr];
    wire [31:0] fifo_rd_bits  = fifo_rd_data[37:6];
    wire [5:0]  fifo_rd_count = fifo_rd_data[5:0];
    reg        cavlc_buf_valid;
    reg [31:0] cavlc_buf_bits;
    reg [5:0]  cavlc_buf_count;
`ifdef VERILATOR
    integer dbg_fifo_deq_idx;
`endif

    wire use_high10_profile = (BIT_DEPTH > 8) && (CHROMA_FORMAT_IDC == 1);
    wire use_high420_profile = (CHROMA_FORMAT_IDC == 1) && (force_transform_8x8_in || transform_8x8_mode_enable);
    wire use_high422_profile = (CHROMA_FORMAT_IDC == 2) || (BIT_DEPTH > 10);
    wire use_high444_profile = (CHROMA_FORMAT_IDC == 3);
    wire use_high_profile = use_high10_profile || use_high420_profile || use_high422_profile || use_high444_profile;
    // The current CABAC P-skip subset and weighted-prediction path cannot be
    // signaled as Baseline. Keep the current non-High CAVLC subset on
    // Baseline for now, and switch to Main when these tools are enabled.
    wire use_main_profile = (weighted_pred_enable || cabac_feature_enable) && !use_high_profile;

    wire weighted_pred_flag = weighted_pred_enable;
    wire [1:0] weighted_bipred_idc = weighted_pred_enable ? 2'b01 : 2'b00;
    wire slice_multi_ref_enable = (slice_num_ref_idx_l0_active_minus1 != 2'd0);
    wire slice_has_skip_run = is_p_slice || is_b_slice;
    localparam integer CHR_MB_WIDTH = (CHROMA_FORMAT_IDC == 3) ? 16 : 8;
    localparam integer CHR_MB_HEIGHT = (CHROMA_FORMAT_IDC == 1) ? 8 : 16;
    localparam integer CHR_MB_PIXELS = CHR_MB_WIDTH * CHR_MB_HEIGHT;
    localparam integer IPCM_TOTAL_SAMPLES = 256 + 2*CHR_MB_PIXELS;
    reg [6:0]  slice_multi_ref_bits;
    reg [3:0]  slice_multi_ref_bits_len;
    reg [11:0] slice_multi_ref_bits_qp;
    reg [3:0]  slice_multi_ref_bits_qp_len;
    reg [8:0]  b_slice_multi_ref_bits;
    reg [3:0]  b_slice_multi_ref_bits_len;
    reg [13:0] b_slice_multi_ref_bits_qp_ref;
    reg [3:0]  b_slice_multi_ref_bits_qp_ref_len;
    reg [12:0] b_slice_multi_ref_bits_qp_nonref;
    reg [3:0]  b_slice_multi_ref_bits_qp_nonref_len;
    reg [9:0]  ipcm_sample_idx;
    always @(*) begin
        case (slice_num_ref_idx_l0_active_minus1)
            2'd1: begin
                slice_multi_ref_bits    = 7'b1010000;      // 1 + ue(1)=010 + reorder_l0=0
                slice_multi_ref_bits_len = 4'd5;
                slice_multi_ref_bits_qp = 12'b101000101000; // + adaptive_marking=0 + qp_delta=1 + deblock=010
                slice_multi_ref_bits_qp_len = 4'd10;
            end
            2'd2: begin
                slice_multi_ref_bits    = 7'b1011000;      // 1 + ue(2)=011 + reorder_l0=0
                slice_multi_ref_bits_len = 4'd5;
                slice_multi_ref_bits_qp = 12'b101100101000;
                slice_multi_ref_bits_qp_len = 4'd10;
            end
            2'd3: begin
                slice_multi_ref_bits    = 7'b1001000;      // 1 + ue(3)=00100 + reorder_l0=0
                slice_multi_ref_bits_len = 4'd7;
                slice_multi_ref_bits_qp = 12'b100100001010;
                slice_multi_ref_bits_qp_len = 4'd12;
            end
            default: begin
                slice_multi_ref_bits    = 7'd0;
                slice_multi_ref_bits_len = 4'd0;
                slice_multi_ref_bits_qp = 12'd0;
                slice_multi_ref_bits_qp_len = 4'd0;
            end
        endcase
    end
    always @(*) begin
        case (slice_num_ref_idx_l0_active_minus1)
            2'd1: begin
                b_slice_multi_ref_bits = 9'b101010000;      // 1 + ue(1)=010 + ue(0)=1 + reorder_l0=0 + reorder_l1=0
                b_slice_multi_ref_bits_len = 4'd7;
                b_slice_multi_ref_bits_qp_ref = 14'b10101000101000;    // + adaptive_marking=0 + qp_delta=1 + deblock=010
                b_slice_multi_ref_bits_qp_ref_len = 4'd12;
                b_slice_multi_ref_bits_qp_nonref = 13'b1010100101000;  // + qp_delta=1 + deblock=010
                b_slice_multi_ref_bits_qp_nonref_len = 4'd11;
            end
            2'd2: begin
                b_slice_multi_ref_bits = 9'b101110000;      // 1 + ue(2)=011 + ue(0)=1 + reorder_l0=0 + reorder_l1=0
                b_slice_multi_ref_bits_len = 4'd7;
                b_slice_multi_ref_bits_qp_ref = 14'b10111000101000;
                b_slice_multi_ref_bits_qp_ref_len = 4'd12;
                b_slice_multi_ref_bits_qp_nonref = 13'b1011100101000;
                b_slice_multi_ref_bits_qp_nonref_len = 4'd11;
            end
            2'd3: begin
                b_slice_multi_ref_bits = 9'b100100100;      // 1 + ue(3)=00100 + ue(0)=1 + reorder_l0=0 + reorder_l1=0
                b_slice_multi_ref_bits_len = 4'd9;
                b_slice_multi_ref_bits_qp_ref = 14'b10010010001010;
                b_slice_multi_ref_bits_qp_ref_len = 4'd14;
                b_slice_multi_ref_bits_qp_nonref = 13'b1001001001010;
                b_slice_multi_ref_bits_qp_nonref_len = 4'd13;
            end
            default: begin
                b_slice_multi_ref_bits = 9'd0;
                b_slice_multi_ref_bits_len = 4'd0;
                b_slice_multi_ref_bits_qp_ref = 14'd0;
                b_slice_multi_ref_bits_qp_ref_len = 4'd0;
                b_slice_multi_ref_bits_qp_nonref = 13'd0;
                b_slice_multi_ref_bits_qp_nonref_len = 4'd0;
            end
        endcase
    end
    wire luma_weight_non_default = (luma_weight != $signed(9'd1 << luma_log2_weight_denom)) || (luma_offset != 9'sd0);
    wire chroma_weight_non_default =
        (chroma_weight_cb != $signed(9'd1 << chroma_log2_weight_denom)) || (chroma_offset_cb != 9'sd0) ||
        (chroma_weight_cr != $signed(9'd1 << chroma_log2_weight_denom)) || (chroma_offset_cr != 9'sd0);
    wire [7:0] sps_profile_idc = use_high444_profile ? 8'hF4 :
                                 use_high422_profile ? 8'h7A :
                                 use_high10_profile  ? 8'h6E :
                                 use_high420_profile ? 8'h64 :
                                 use_high_profile   ? 8'h4D : 8'h42;

    wire [7:0] sps_constraint_flags = (use_high_profile || use_main_profile) ? 8'h00 : 8'hC0;
    localparam integer FRAME_NUM_BITS = 8;
    localparam integer LOG2_MAX_FRAME_NUM_MINUS4 = FRAME_NUM_BITS - 4;
    localparam integer POC_LSB_BITS = 9;
    localparam integer LOG2_MAX_POC_LSB_MINUS4 = POC_LSB_BITS - 4;
    wire [6:0] sps_id_and_chroma_bits =
        (CHROMA_FORMAT_IDC == 3) ? 7'b1001000 : // sps_id=UE(0)=1, chroma_format_idc=UE(3)=00100, separate_colour_plane_flag=0
        (CHROMA_FORMAT_IDC == 2) ? 7'b1011000 : // sps_id=UE(0)=1, chroma_format_idc=UE(2)=011
                                  7'b1010000 ; // sps_id=UE(0)=1, chroma_format_idc=UE(1)=010
    wire [2:0] sps_id_and_chroma_len = (CHROMA_FORMAT_IDC == 3) ? 3'd7 : 3'd4;
    localparam integer FRAME_MB_COUNT = MB_COLS * MB_ROWS;
    localparam integer FRAME_MBPS = FRAME_MB_COUNT * FRAME_RATE;
    localparam [31:0] VUI_NUM_UNITS_IN_TICK = 32'd1;
    localparam [31:0] VUI_TIME_SCALE = FRAME_RATE * 2;
    localparam [9:0]  VUI_LOG2_MAX_MV_LENGTH = 10'd6;

    function [7:0] select_level_idc;
        input integer frame_mbs;
        input integer frame_mbps;
        begin
            if (frame_mbs <= 99 && frame_mbps <= 1485)
                select_level_idc = 8'h0A; // Level 1.0
            else if (frame_mbs <= 396 && frame_mbps <= 3000)
                select_level_idc = 8'h0B; // Level 1.1
            else if (frame_mbs <= 396 && frame_mbps <= 6000)
                select_level_idc = 8'h0C; // Level 1.2
            else if (frame_mbs <= 396 && frame_mbps <= 11880)
                select_level_idc = 8'h0D; // Level 1.3 / 2.0 class by MBPS+FS
            else if (frame_mbs <= 792 && frame_mbps <= 19800)
                select_level_idc = 8'h15; // Level 2.1
            else if (frame_mbs <= 1620 && frame_mbps <= 20250)
                select_level_idc = 8'h16; // Level 2.2
            else if (frame_mbs <= 1620 && frame_mbps <= 40500)
                select_level_idc = 8'h1E; // Level 3.0
            else if (frame_mbs <= 3600 && frame_mbps <= 108000)
                select_level_idc = 8'h1F; // Level 3.1
            else if (frame_mbs <= 5120 && frame_mbps <= 216000)
                select_level_idc = 8'h20; // Level 3.2
            else if (frame_mbs <= 8192 && frame_mbps <= 245760)
                select_level_idc = 8'h28; // Level 4.0 / 4.1 class by MBPS+FS
            else if (frame_mbs <= 8704 && frame_mbps <= 522240)
                select_level_idc = 8'h2A; // Level 4.2
            else if (frame_mbs <= 22080 && frame_mbps <= 589824)
                select_level_idc = 8'h32; // Level 5.0
            else if (frame_mbs <= 36864 && frame_mbps <= 983040)
                select_level_idc = 8'h33; // Level 5.1
            else
                select_level_idc = 8'h34; // Level 5.2
        end
    endfunction

    // Skip emulation prevention during start code output
    reg        skip_ep;
    reg        pps_secondary_active;
    reg        cabac_slice_active;
    reg [11:0] cabac_mb_counter;
    reg [6:0]  cabac_skip_ctx_state_0;
    reg [6:0]  cabac_skip_ctx_state_1;
    reg [6:0]  cabac_skip_ctx_state_2;
    reg [1:0]  cabac_pending_skip_ctx_idx;
    reg [6:0]  cabac_mb_type_ctx_state_14;
    reg [6:0]  cabac_mb_type_ctx_state_15;
    reg [6:0]  cabac_mb_type_ctx_state_16;
    reg [6:0]  cabac_mvdx_ctx_state_0;
    reg [6:0]  cabac_mvdx_ctx_state_1;
    reg [6:0]  cabac_mvdx_ctx_state_2;
    reg [6:0]  cabac_mvdy_ctx_state_0;
    reg [6:0]  cabac_mvdy_ctx_state_1;
    reg [6:0]  cabac_mvdy_ctx_state_2;
    reg [6:0]  cabac_cbp_luma_ctx_state_73;
    reg [6:0]  cabac_cbp_luma_ctx_state_74;
    reg [6:0]  cabac_cbp_luma_ctx_state_75;
    reg [6:0]  cabac_cbp_luma_ctx_state_76;
    reg [6:0]  cabac_cbp_chroma_ctx_state [0:7];
    reg [6:0]  cabac_qp_delta_ctx_state_60;
    reg [6:0]  cabac_res_cbf_ctx_state [0:3];
    reg [6:0]  cabac_res_sig_ctx_state [0:14];
    reg [6:0]  cabac_res_last_ctx_state [0:14];
    reg [6:0]  cabac_res_level_ctx_state_0;
    reg [6:0]  cabac_res_level_ctx_state_1;
    reg [6:0]  cabac_res_chroma_dc_cbf_ctx_state [0:3];
    reg [6:0]  cabac_res_chroma_dc_sig_ctx_state [0:2];
    reg [6:0]  cabac_res_chroma_dc_last_ctx_state [0:2];
    reg [6:0]  cabac_res_chroma_dc_level_ctx_state_0;
    reg [6:0]  cabac_res_chroma_dc_level_ctx_state_1;
    reg [6:0]  cabac_res_chroma_ac_cbf_ctx_state [0:3];
    reg [6:0]  cabac_res_chroma_ac_cr_cbf_ctx_state [0:3];
    reg [6:0]  cabac_res_chroma_ac_sig_ctx_state [0:14];
    reg [6:0]  cabac_res_chroma_ac_last_ctx_state [0:14];
    reg [6:0]  cabac_res_chroma_ac_level_ctx_state_0;
    reg [6:0]  cabac_res_chroma_ac_level_ctx_state_1;
    reg [6:0]  cabac_res_chroma_ac_cr_sig_ctx_state [0:14];
    reg [6:0]  cabac_res_chroma_ac_cr_last_ctx_state [0:14];
    reg [6:0]  cabac_res_chroma_ac_cr_level_ctx_state_0;
    reg [6:0]  cabac_res_chroma_ac_cr_level_ctx_state_1;
    reg [4:0]  cabac_pending_ctx_kind;
    reg [4:0]  cabac_pending_ctx_sel;
    reg [1:0]  cabac_pending_res_category;
    reg [3:0]  cabac_pending_res_block_idx;
    reg [3:0]  cabac_res_block_idx;
    reg [1:0]  cabac_res_category;
    reg        cabac_res_scan_start;
    reg        cabac_res_scan_done_pending;
    integer    cabac_res_i;
    reg        cabac_start;
    reg        cabac_bin_valid;
    reg        cabac_bin_value;
    reg        cabac_bin_bypass;
    reg        cabac_bin_terminate;
    reg [6:0]  cabac_ctx_state_in;
    wire       cabac_bin_ready;
    wire       cabac_bits_valid;
    wire [127:0] cabac_bits_out;
    wire [7:0] cabac_bits_count;
    wire       cabac_bits_overflow;
    wire       cabac_ctx_state_wr;
    wire [6:0] cabac_ctx_state_out;
    wire       cabac_done;
    wire       cabac_active;
    wire [63:0] cabac_debug_low;
    wire [8:0] cabac_debug_range;
    wire signed [7:0] cabac_debug_queue;
    wire [7:0] cabac_debug_outstanding;
    wire       cabac_debug_pending_valid;
    wire [7:0] cabac_debug_pending_byte;


    localparam [4:0] CABAC_CTX_NONE      = 5'd0;
    localparam [4:0] CABAC_CTX_SKIP      = 5'd1;
    localparam [4:0] CABAC_CTX_MBTYPE14  = 5'd2;
    localparam [4:0] CABAC_CTX_MBTYPE15  = 5'd3;
    localparam [4:0] CABAC_CTX_MBTYPE16  = 5'd4;
    localparam [4:0] CABAC_CTX_MVDX      = 5'd5;
    localparam [4:0] CABAC_CTX_MVDY      = 5'd6;
    localparam [4:0] CABAC_CTX_CBP0      = 5'd7;
    localparam [4:0] CABAC_CTX_CBP1      = 5'd8;
    localparam [4:0] CABAC_CTX_CBP2      = 5'd9;
    localparam [4:0] CABAC_CTX_CBP3      = 5'd10;
    localparam [4:0] CABAC_CTX_CBPCHROMA = 5'd11;
    localparam [4:0] CABAC_CTX_QPDELTA   = 5'd12;
    localparam [4:0] CABAC_CTX_RES_CBF   = 5'd13;
    localparam [4:0] CABAC_CTX_RES_SIG   = 5'd14;
    localparam [4:0] CABAC_CTX_RES_LAST  = 5'd15;
    localparam [4:0] CABAC_CTX_RES_LEVEL = 5'd16;

    localparam [4:0] CABAC_CTX_RES_CHRDC_CBF   = 5'd17;
    localparam [4:0] CABAC_CTX_RES_CHRDC_SIG   = 5'd18;
    localparam [4:0] CABAC_CTX_RES_CHRDC_LAST  = 5'd19;
    localparam [4:0] CABAC_CTX_RES_CHRDC_LEVEL = 5'd20;
    localparam [4:0] CABAC_CTX_RES_CHRAC_CBF   = 5'd21;
    localparam [4:0] CABAC_CTX_RES_CHRAC_SIG   = 5'd22;
    localparam [4:0] CABAC_CTX_RES_CHRAC_LAST  = 5'd23;
    localparam [4:0] CABAC_CTX_RES_CHRAC_LEVEL = 5'd24;

    localparam [1:0] CABAC_RES_CAT_LUMA      = 2'd0;
    localparam [1:0] CABAC_RES_CAT_CHROMA_DC = 2'd1;
    localparam [1:0] CABAC_RES_CAT_CHROMA_AC = 2'd2;
    localparam [3:0] CABAC_CHROMA_DC_MAX_COEFF_MINUS1 = (CHROMA_FORMAT_IDC == 2) ? 4'd7 : 4'd3;
    localparam [3:0] CABAC_CHROMA_AC_TOTAL_MINUS1 = (CHROMA_FORMAT_IDC == 2) ? 4'd15 : 4'd7;
    localparam [3:0] CABAC_CHROMA_AC_BLOCKS_PER_PLANE = (CHROMA_FORMAT_IDC == 2) ? 4'd8 : 4'd4;

    task automatic cabac_debug_header_bits;
        begin
            `ifndef SYNTHESIS
            if (DEBUG_CABAC_P16X16)
                $display("[CABACHDRBITS] mb=%0d sub=%0d kind=%0d sel=%0d count=%0d bits=%024x bit_cnt=%0d ari_low=%0h ari_range=%0d ari_queue=%0d ari_outstanding=%0d ari_pending=%0d ari_pbyte=%0h",
                         cabac_mb_counter, sub, cabac_pending_ctx_kind, cabac_pending_ctx_sel,
                         cabac_bits_count, cabac_bits_out[127:32], bit_cnt,
                         cabac_debug_low, cabac_debug_range, cabac_debug_queue,
                         cabac_debug_outstanding, cabac_debug_pending_valid, cabac_debug_pending_byte);
            `endif
        end
    endtask

    function automatic [6:0] cabac_init_state;
        input integer m;
        input integer n;
        input integer qp;
        integer state_i;
        integer clipped_i;
        integer pstate_i;
        integer mps_i;
        begin
            state_i = ((m * qp) >>> 4) + n;
            if (state_i < 1)
                clipped_i = 1;
            else if (state_i > 126)
                clipped_i = 126;
            else
                clipped_i = state_i;
            if (clipped_i <= (127 - clipped_i)) begin
                pstate_i = clipped_i;
                mps_i = 0;
            end else begin
                pstate_i = 127 - clipped_i;
                mps_i = 1;
            end
            cabac_init_state = {pstate_i[5:0], mps_i[0]};
        end
    endfunction

    function automatic [6:0] cabac_pskip_ctx_init;
        input [1:0] skip_ctx_i;
        begin
            case (skip_ctx_i)
                2'd0: cabac_pskip_ctx_init = cabac_init_state(23, 33, 26);
                2'd1: cabac_pskip_ctx_init = cabac_init_state(23, 2, 26);
                default: cabac_pskip_ctx_init = cabac_init_state(21, 0, 26);
            endcase
        end
    endfunction

    // UE(v) encoder — general-purpose unsigned Exp-Golomb
    // Used by SPS and other parameter sets
    reg [9:0] ue_input;   // codeNum (unsigned, max ~1023)
    wire [10:0] ue_code1 = {1'b0, ue_input} + 11'd1;

    reg [3:0] ue_msb;
    always @(*) begin
        casez (ue_code1)
            11'b1??????????: ue_msb = 4'd10;
            11'b01?????????: ue_msb = 4'd9;
            11'b001????????: ue_msb = 4'd8;
            11'b0001???????: ue_msb = 4'd7;
            11'b00001??????: ue_msb = 4'd6;
            11'b000001?????: ue_msb = 4'd5;
            11'b0000001????: ue_msb = 4'd4;
            11'b00000001???: ue_msb = 4'd3;
            11'b000000001??: ue_msb = 4'd2;
            11'b0000000001?: ue_msb = 4'd1;
            default:         ue_msb = 4'd0;
        endcase
    end

    wire [4:0] ue_total_bits = {ue_msb, 1'b0} + 5'd1;
    reg [20:0] ue_ue_bits;
    always @(*) begin
        case (ue_msb)
            4'd0:  ue_ue_bits = {ue_code1[0], 20'd0};
            4'd1:  ue_ue_bits = {1'b0, ue_code1[1:0], 18'd0};
            4'd2:  ue_ue_bits = {2'b0, ue_code1[2:0], 16'd0};
            4'd3:  ue_ue_bits = {3'b0, ue_code1[3:0], 14'd0};
            4'd4:  ue_ue_bits = {4'b0, ue_code1[4:0], 12'd0};
            4'd5:  ue_ue_bits = {5'b0, ue_code1[5:0], 10'd0};
            4'd6:  ue_ue_bits = {6'b0, ue_code1[6:0], 8'd0};
            4'd7:  ue_ue_bits = {7'b0, ue_code1[7:0], 6'd0};
            4'd8:  ue_ue_bits = {8'b0, ue_code1[8:0], 4'd0};
            4'd9:  ue_ue_bits = {9'b0, ue_code1[9:0], 2'd0};
            4'd10: ue_ue_bits = {10'b0, ue_code1[10:0]};
            default: ue_ue_bits = {1'b1, 20'd0};
        endcase
    end

    // SE(v) encoder for MVD — combinational
    // Maps signed value to Exp-Golomb codeNum, then generates UE bit pattern
    reg signed [8:0] se_input;
    wire [8:0] se_abs = (se_input[8]) ? (~se_input + 9'd1) : se_input;
    wire [9:0] se_codenum = (se_input == 9'sd0) ? 10'd0 :
                            (se_input[8])        ? {se_abs, 1'b0} :       // negative: 2*|v|
                                                   {1'b0, se_abs, 1'b0} - 10'd1; // positive: 2*v-1

    // Larger UE(v) helper for mb_skip_run. This must cover at least the macroblock
    // count of the validated 720p target and wider local smoke resolutions.
    wire [12:0] ue_big_input = pending_skip_run;
    wire [13:0] ue_big_code1 = {1'b0, ue_big_input} + 14'd1;
    reg [4:0] ue_big_msb;
    always @(*) begin
        casez (ue_big_code1)
            14'b1?????????????: ue_big_msb = 5'd13;
            14'b01????????????: ue_big_msb = 5'd12;
            14'b001???????????: ue_big_msb = 5'd11;
            14'b0001??????????: ue_big_msb = 5'd10;
            14'b00001?????????: ue_big_msb = 5'd9;
            14'b000001????????: ue_big_msb = 5'd8;
            14'b0000001???????: ue_big_msb = 5'd7;
            14'b00000001??????: ue_big_msb = 5'd6;
            14'b000000001?????: ue_big_msb = 5'd5;
            14'b0000000001????: ue_big_msb = 5'd4;
            14'b00000000001???: ue_big_msb = 5'd3;
            14'b000000000001??: ue_big_msb = 5'd2;
            14'b0000000000001?: ue_big_msb = 5'd1;
            default:            ue_big_msb = 5'd0;
        endcase
    end
    reg [12:0] pending_skip_run;
    reg [2:0]  p8x8_sub_idx;
    reg [4:0]  p8x8_mvd_idx;
    wire [4:0] p8x8_mvd_total_w = (p_sub_mb_type == 2'd0) ? 5'd4 :
                                      (p_sub_mb_type == 2'd3) ? 5'd16 : 5'd8;
    wire [5:0] ue_big_total_bits = {ue_big_msb, 1'b0} + 6'd1;
    reg [24:0] ue_big_bits;
    always @(*) begin
        case (ue_big_msb)
            5'd0:  ue_big_bits = {ue_big_code1[0], 24'd0};
            5'd1:  ue_big_bits = {1'b0, ue_big_code1[1:0], 22'd0};
            5'd2:  ue_big_bits = {2'b0, ue_big_code1[2:0], 20'd0};
            5'd3:  ue_big_bits = {3'b0, ue_big_code1[3:0], 18'd0};
            5'd4:  ue_big_bits = {4'b0, ue_big_code1[4:0], 16'd0};
            5'd5:  ue_big_bits = {5'b0, ue_big_code1[5:0], 14'd0};
            5'd6:  ue_big_bits = {6'b0, ue_big_code1[6:0], 12'd0};
            5'd7:  ue_big_bits = {7'b0, ue_big_code1[7:0], 10'd0};
            5'd8:  ue_big_bits = {8'b0, ue_big_code1[8:0], 8'd0};
            5'd9:  ue_big_bits = {9'b0, ue_big_code1[9:0], 6'd0};
            5'd10: ue_big_bits = {10'b0, ue_big_code1[10:0], 4'd0};
            5'd11: ue_big_bits = {11'b0, ue_big_code1[11:0], 2'd0};
            5'd12: ue_big_bits = {12'b0, ue_big_code1[12:0]};
            5'd13: ue_big_bits = 25'd0;
            default: ue_big_bits = {1'b1, 24'd0};
        endcase
    end
    wire [10:0] se_code1 = se_codenum + 11'd1;  // codeNum + 1
    wire [9:0]  mvd_x_l0_codenum_w = (mvd_x_l0 == 9'sd0) ? 10'd0 :
                                     (mvd_x_l0[8])       ? ({(~mvd_x_l0 + 9'd1), 1'b0}) :
                                                            ({mvd_x_l0, 1'b0} - 10'd1);
    wire [9:0]  mvd_y_l0_codenum_w = (mvd_y_l0 == 9'sd0) ? 10'd0 :
                                     (mvd_y_l0[8])       ? ({(~mvd_y_l0 + 9'd1), 1'b0}) :
                                                            ({mvd_y_l0, 1'b0} - 10'd1);
    wire [9:0]  mvd_x_l0_part1_codenum_w = (mvd_x_l0_part1 == 9'sd0) ? 10'd0 :
                                            (mvd_x_l0_part1[8])       ? ({(~mvd_x_l0_part1 + 9'd1), 1'b0}) :
                                                                        ({mvd_x_l0_part1, 1'b0} - 10'd1);
    wire [9:0]  mvd_y_l0_part1_codenum_w = (mvd_y_l0_part1 == 9'sd0) ? 10'd0 :
                                            (mvd_y_l0_part1[8])       ? ({(~mvd_y_l0_part1 + 9'd1), 1'b0}) :
                                                                        ({mvd_y_l0_part1, 1'b0} - 10'd1);
    wire [9:0]  mvd_x_l1_codenum_w = (mvd_x_l1 == 9'sd0) ? 10'd0 :
                                     (mvd_x_l1[8])       ? ({(~mvd_x_l1 + 9'd1), 1'b0}) :
                                                            ({mvd_x_l1, 1'b0} - 10'd1);
    wire [9:0]  mvd_y_l1_codenum_w = (mvd_y_l1 == 9'sd0) ? 10'd0 :
                                     (mvd_y_l1[8])       ? ({(~mvd_y_l1 + 9'd1), 1'b0}) :
                                                            ({mvd_y_l1, 1'b0} - 10'd1);

    h264_cabac_core u_cabac_core (
        .clk(clk),
        .rst_n(rst_n),
        .start(cabac_start),
        .bin_valid(cabac_bin_valid),
        .bin_value(cabac_bin_value),
        .bin_bypass(cabac_bin_bypass),
        .bin_terminate(cabac_bin_terminate),
        .ctx_state_in(cabac_ctx_state_in),
        .bin_ready(cabac_bin_ready),
        .bits_valid(cabac_bits_valid),
        .bits_out(cabac_bits_out),
        .bits_count(cabac_bits_count),
        .bits_overflow(cabac_bits_overflow),
        .ctx_state_wr(cabac_ctx_state_wr),
        .ctx_state_out(cabac_ctx_state_out),
        .done(cabac_done),
        .active(cabac_active),
        .debug_low(cabac_debug_low),
        .debug_range(cabac_debug_range),
        .debug_queue(cabac_debug_queue),
        .debug_outstanding(cabac_debug_outstanding),
        .debug_pending_valid(cabac_debug_pending_valid),
        .debug_pending_byte(cabac_debug_pending_byte)
    );


    function automatic signed [15:0] cabac_luma_coeff_at;
        input [3:0] block_i;
        input [3:0] coeff_i;
        integer bit_base_i;
        begin
            bit_base_i = ((block_i * 16) + coeff_i) * 16;
            cabac_luma_coeff_at = cabac_luma_scan_flat[bit_base_i +: 16];
        end
    endfunction

    function automatic signed [15:0] cabac_chroma_dc_coeff_at;
        input [3:0] block_i;
        input [3:0] coeff_i;
        integer bit_base_i;
        begin
            bit_base_i = (((block_i[0] ? 1 : 0) * 16) + coeff_i) * 16;
            cabac_chroma_dc_coeff_at = cabac_chroma_dc_scan_flat[bit_base_i +: 16];
        end
    endfunction

    function automatic signed [15:0] cabac_chroma_ac_coeff_at;
        input [3:0] block_i;
        input [3:0] coeff_i;
        integer bit_base_i;
        begin
            bit_base_i = ((block_i * 16) + coeff_i) * 16;
            cabac_chroma_ac_coeff_at = cabac_chroma_ac_scan_flat[bit_base_i +: 16];
        end
    endfunction

    function automatic signed [15:0] cabac_res_coeff_at;
        input [1:0] category_i;
        input [3:0] block_i;
        input [3:0] coeff_i;
        begin
            case (category_i)
                CABAC_RES_CAT_CHROMA_DC: cabac_res_coeff_at = cabac_chroma_dc_coeff_at(block_i, coeff_i);
                CABAC_RES_CAT_CHROMA_AC: cabac_res_coeff_at = cabac_chroma_ac_coeff_at(block_i, coeff_i);
                default:                 cabac_res_coeff_at = cabac_luma_coeff_at(block_i, coeff_i);
            endcase
        end
    endfunction

    function automatic [3:0] cabac_res_max_coeff_minus1_for;
        input [1:0] category_i;
        begin
            case (category_i)
                CABAC_RES_CAT_CHROMA_DC: cabac_res_max_coeff_minus1_for = CABAC_CHROMA_DC_MAX_COEFF_MINUS1;
                CABAC_RES_CAT_CHROMA_AC: cabac_res_max_coeff_minus1_for = 4'd14;
                default:                 cabac_res_max_coeff_minus1_for = 4'd15;
            endcase
        end
    endfunction

    function automatic [8:0] cabac_res_ctx_cbf_base_for;
        input [1:0] category_i;
        begin
            case (category_i)
                CABAC_RES_CAT_CHROMA_DC: cabac_res_ctx_cbf_base_for = 9'd97;
                CABAC_RES_CAT_CHROMA_AC: cabac_res_ctx_cbf_base_for = 9'd101;
                default:                 cabac_res_ctx_cbf_base_for = 9'd85;
            endcase
        end
    endfunction

    function automatic [8:0] cabac_res_ctx_sig_base_for;
        input [1:0] category_i;
        begin
            case (category_i)
                CABAC_RES_CAT_CHROMA_DC: cabac_res_ctx_sig_base_for = 9'd149;
                CABAC_RES_CAT_CHROMA_AC: cabac_res_ctx_sig_base_for = 9'd152;
                default:                 cabac_res_ctx_sig_base_for = 9'd105;
            endcase
        end
    endfunction

    function automatic [8:0] cabac_res_ctx_last_base_for;
        input [1:0] category_i;
        begin
            case (category_i)
                CABAC_RES_CAT_CHROMA_DC: cabac_res_ctx_last_base_for = 9'd210;
                CABAC_RES_CAT_CHROMA_AC: cabac_res_ctx_last_base_for = 9'd213;
                default:                 cabac_res_ctx_last_base_for = 9'd166;
            endcase
        end
    endfunction

    function automatic [8:0] cabac_res_ctx_level_gt1_for;
        input [1:0] category_i;
        begin
            case (category_i)
                CABAC_RES_CAT_CHROMA_DC: cabac_res_ctx_level_gt1_for = 9'd257;
                CABAC_RES_CAT_CHROMA_AC: cabac_res_ctx_level_gt1_for = 9'd266;
                default:                 cabac_res_ctx_level_gt1_for = 9'd227;
            endcase
        end
    endfunction

    function automatic [8:0] cabac_res_ctx_level_gt2_for;
        input [1:0] category_i;
        begin
            case (category_i)
                CABAC_RES_CAT_CHROMA_DC: cabac_res_ctx_level_gt2_for = 9'd262;
                CABAC_RES_CAT_CHROMA_AC: cabac_res_ctx_level_gt2_for = 9'd277;
                default:                 cabac_res_ctx_level_gt2_for = 9'd232;
            endcase
        end
    endfunction

    function automatic [3:0] cabac_res_ctx_sig_last_max_for;
        input [1:0] category_i;
        begin
            case (category_i)
                CABAC_RES_CAT_CHROMA_DC: cabac_res_ctx_sig_last_max_for = 4'd2;
                CABAC_RES_CAT_CHROMA_AC: cabac_res_ctx_sig_last_max_for = 4'd14;
                default:                 cabac_res_ctx_sig_last_max_for = 4'd14;
            endcase
        end
    endfunction

    function automatic [3:0] cabac_res_last_block_for;
        input [1:0] category_i;
        begin
            case (category_i)
                CABAC_RES_CAT_CHROMA_DC: cabac_res_last_block_for = 4'd1;
                CABAC_RES_CAT_CHROMA_AC: cabac_res_last_block_for = CABAC_CHROMA_AC_TOTAL_MINUS1;
                default:                 cabac_res_last_block_for = 4'd15;
            endcase
        end
    endfunction

    function automatic [1:0] cabac_res_cbf_ctx_sel_for;
        input [3:0] block_i;
        reg left_coded_i;
        reg top_coded_i;
        begin
            left_coded_i = (block_i[1:0] != 2'd0) ? cabac_luma_nz_mask[block_i - 4'd1] : 1'b0;
            top_coded_i = (block_i >= 4'd4) ? cabac_luma_nz_mask[block_i - 4'd4] : 1'b0;
            cabac_res_cbf_ctx_sel_for = {top_coded_i, left_coded_i};
        end
    endfunction

    function automatic cabac_chroma_ac_block_nz_for;
        input [3:0] block_i;
        integer coeff_i;
        reg coded_i;
        begin
            coded_i = 1'b0;
            for (coeff_i = 0; coeff_i < 15; coeff_i = coeff_i + 1) begin
                if (cabac_chroma_ac_coeff_at(block_i, coeff_i[3:0]) != 16'sd0)
                    coded_i = 1'b1;
            end
            cabac_chroma_ac_block_nz_for = coded_i;
        end
    endfunction

    function automatic cabac_chroma_ac_cb_plane_any_nz;
        integer block_i;
        reg coded_i;
        begin
            coded_i = 1'b0;
            for (block_i = 0; block_i < CABAC_CHROMA_AC_BLOCKS_PER_PLANE; block_i = block_i + 1) begin
                if (cabac_chroma_ac_block_nz_for(block_i[3:0]))
                    coded_i = 1'b1;
            end
            cabac_chroma_ac_cb_plane_any_nz = coded_i;
        end
    endfunction

    function automatic cabac_chroma_ac_cb_plane_full_nz;
        integer block_i;
        reg coded_i;
        begin
            coded_i = 1'b1;
            for (block_i = 0; block_i < CABAC_CHROMA_AC_BLOCKS_PER_PLANE; block_i = block_i + 1) begin
                if (!cabac_chroma_ac_block_nz_for(block_i[3:0]))
                    coded_i = 1'b0;
            end
            cabac_chroma_ac_cb_plane_full_nz = coded_i;
        end
    endfunction

    function automatic cabac_chroma_ac_cr_plane_any_nz;
        integer block_i;
        reg coded_i;
        begin
            coded_i = 1'b0;
            for (block_i = 0; block_i < CABAC_CHROMA_AC_BLOCKS_PER_PLANE; block_i = block_i + 1) begin
                if (cabac_chroma_ac_block_nz_for(CABAC_CHROMA_AC_BLOCKS_PER_PLANE + block_i[3:0]))
                    coded_i = 1'b1;
            end
            cabac_chroma_ac_cr_plane_any_nz = coded_i;
        end
    endfunction

    function automatic cabac_chroma_ac_cr_plane_full_nz;
        integer block_i;
        reg coded_i;
        begin
            coded_i = 1'b1;
            for (block_i = 0; block_i < CABAC_CHROMA_AC_BLOCKS_PER_PLANE; block_i = block_i + 1) begin
                if (!cabac_chroma_ac_block_nz_for(CABAC_CHROMA_AC_BLOCKS_PER_PLANE + block_i[3:0]))
                    coded_i = 1'b0;
            end
            cabac_chroma_ac_cr_plane_full_nz = coded_i;
        end
    endfunction

    function automatic [3:0] cabac_chroma_ac_cb_plane_nz_mask;
        integer block_i;
        reg [3:0] mask_i;
        begin
            mask_i = 4'd0;
            for (block_i = 0; block_i < CABAC_CHROMA_AC_BLOCKS_PER_PLANE; block_i = block_i + 1) begin
                if (cabac_chroma_ac_block_nz_for(block_i[3:0]))
                    mask_i[block_i] = 1'b1;
            end
            cabac_chroma_ac_cb_plane_nz_mask = mask_i;
        end
    endfunction

    function automatic [3:0] cabac_chroma_ac_cr_plane_nz_mask;
        integer block_i;
        reg [3:0] mask_i;
        begin
            mask_i = 4'd0;
            for (block_i = 0; block_i < CABAC_CHROMA_AC_BLOCKS_PER_PLANE; block_i = block_i + 1) begin
                if (cabac_chroma_ac_block_nz_for(CABAC_CHROMA_AC_BLOCKS_PER_PLANE + block_i[3:0]))
                    mask_i[block_i] = 1'b1;
            end
            cabac_chroma_ac_cr_plane_nz_mask = mask_i;
        end
    endfunction

    function automatic cabac_chroma_ac_split_plane_ctx;
        begin
            // Scope the separate Cr residual payload context bank to the
            // Cb-singleton / Cr-all-but-one complements that exposed high-
            // amplitude short-decode lanes. Other promoted mixed guards stay on
            // the historical shared payload context bank.
            cabac_chroma_ac_split_plane_ctx =
                ((cabac_chroma_ac_cb_plane_nz_mask() == 4'h2) &&
                 (cabac_chroma_ac_cr_plane_nz_mask() == 4'hd)) ||
                ((cabac_chroma_ac_cb_plane_nz_mask() == 4'h4) &&
                 (cabac_chroma_ac_cr_plane_nz_mask() == 4'hb));
        end
    endfunction

    function automatic [1:0] cabac_res_chroma_ac_cbf_ctx_sel_for;
        input [3:0] block_i;
        reg [2:0] plane_block_i;
        reg left_coded_i;
        reg top_coded_i;
        begin
            // Chroma AC coded_block_flag context derivation is plane-local.
            // Keep sparse Cb/Cr edge probes on the historical edge-coded path.
            // Dense Cr is sensitive to the preceding all-zero Cb AC CBF bins; when
            // every Cr AC block is coded, use uncoded unavailable edges for the Cb
            // plane's zero CBF walk so the dense Cr checker strict-decodes without
            // perturbing sparse Cr singles.
            if (block_i < CABAC_CHROMA_AC_BLOCKS_PER_PLANE)
                plane_block_i = block_i[2:0];
            else
                plane_block_i = block_i - CABAC_CHROMA_AC_BLOCKS_PER_PLANE;
            if ((cabac_chroma_ac_cb_plane_nz_mask() == 4'hb) &&
                (cabac_chroma_ac_cr_plane_nz_mask() == 4'h4)) begin
                // The high-amplitude reciprocal Cb-all-but-one / Cr-singleton
                // complement needs the literal plane-local CBF neighbour walk.
                // Keep this narrower than the sparse Cb-only path below, whose
                // top-row masks still depend on the synthetic edge-coded walk.
                left_coded_i = plane_block_i[0] ? cabac_chroma_ac_block_nz_for(block_i - 4'd1) : 1'b0;
                top_coded_i = (plane_block_i >= 3'd2) ? cabac_chroma_ac_block_nz_for(block_i - 4'd2) : 1'b0;
            end else if ((block_i < CABAC_CHROMA_AC_BLOCKS_PER_PLANE) &&
                cabac_chroma_ac_cb_plane_any_nz() &&
                !cabac_chroma_ac_cb_plane_full_nz() &&
                !cabac_chroma_ac_cr_plane_any_nz()) begin
                // Sparse Cb-only AC needs a dedicated CBF context walk: the
                // top-row sparse misses stay isolated, while bottom-row sparse Cb
                // now strict-decodes without perturbing dense Cb/Cr or Cr-only.
                case (plane_block_i)
                    3'd0: begin left_coded_i = 1'b1; top_coded_i = 1'b0; end
                    3'd1: begin left_coded_i = 1'b1; top_coded_i = 1'b0; end
                    3'd2: begin left_coded_i = 1'b1; top_coded_i = 1'b1; end
                    default: begin left_coded_i = 1'b0; top_coded_i = 1'b0; end
                endcase
            end else if ((block_i < CABAC_CHROMA_AC_BLOCKS_PER_PLANE) && cabac_chroma_ac_cr_plane_full_nz()) begin
                left_coded_i = plane_block_i[0] ? cabac_chroma_ac_block_nz_for(block_i - 4'd1) : 1'b0;
                top_coded_i = (plane_block_i >= 3'd2) ? cabac_chroma_ac_block_nz_for(block_i - 4'd2) : 1'b0;
            end else if ((block_i >= CABAC_CHROMA_AC_BLOCKS_PER_PLANE) && (plane_block_i == 3'd0) && cabac_chroma_ac_block_nz_for(block_i)) begin
                left_coded_i = 1'b0;
                top_coded_i = 1'b0;
            end else begin
                left_coded_i = plane_block_i[0] ? cabac_chroma_ac_block_nz_for(block_i - 4'd1) : 1'b1;
                top_coded_i = (plane_block_i >= 3'd2) ? cabac_chroma_ac_block_nz_for(block_i - 4'd2) : 1'b1;
            end
            cabac_res_chroma_ac_cbf_ctx_sel_for = {top_coded_i, left_coded_i};
        end
    endfunction

    wire        cabac_res_event_valid;
    wire        cabac_res_event_ready;
    wire [2:0]  cabac_res_event_kind;
    wire        cabac_res_event_value;
    wire [3:0]  cabac_res_event_coeff_idx;
    wire [15:0] cabac_res_event_level_abs;
    wire        cabac_res_event_level_sign;
    wire        cabac_res_scan_done;
    wire        cabac_res_scan_busy;
    wire        cabac_res_bin_valid;
    wire        cabac_res_bin_value;
    wire        cabac_res_bin_bypass;
    wire [8:0]  cabac_res_bin_ctx_idx;
    wire        cabac_res_bin_done;

    h264_cabac_residual4x4_scan u_cabac_res_scan (
        .clk(clk), .rst_n(rst_n), .start(cabac_res_scan_start),
        .coeff0(cabac_res_coeff_at(cabac_res_category, cabac_res_block_idx, 4'd0)),
        .coeff1(cabac_res_coeff_at(cabac_res_category, cabac_res_block_idx, 4'd1)),
        .coeff2(cabac_res_coeff_at(cabac_res_category, cabac_res_block_idx, 4'd2)),
        .coeff3(cabac_res_coeff_at(cabac_res_category, cabac_res_block_idx, 4'd3)),
        .coeff4(cabac_res_coeff_at(cabac_res_category, cabac_res_block_idx, 4'd4)),
        .coeff5(cabac_res_coeff_at(cabac_res_category, cabac_res_block_idx, 4'd5)),
        .coeff6(cabac_res_coeff_at(cabac_res_category, cabac_res_block_idx, 4'd6)),
        .coeff7(cabac_res_coeff_at(cabac_res_category, cabac_res_block_idx, 4'd7)),
        .coeff8(cabac_res_coeff_at(cabac_res_category, cabac_res_block_idx, 4'd8)),
        .coeff9(cabac_res_coeff_at(cabac_res_category, cabac_res_block_idx, 4'd9)),
        .coeff10(cabac_res_coeff_at(cabac_res_category, cabac_res_block_idx, 4'd10)),
        .coeff11(cabac_res_coeff_at(cabac_res_category, cabac_res_block_idx, 4'd11)),
        .coeff12(cabac_res_coeff_at(cabac_res_category, cabac_res_block_idx, 4'd12)),
        .coeff13(cabac_res_coeff_at(cabac_res_category, cabac_res_block_idx, 4'd13)),
        .coeff14(cabac_res_coeff_at(cabac_res_category, cabac_res_block_idx, 4'd14)),
        .coeff15(cabac_res_coeff_at(cabac_res_category, cabac_res_block_idx, 4'd15)),
        .max_coeff_minus1(cabac_res_max_coeff_minus1_for(cabac_res_category)),
        .event_valid(cabac_res_event_valid),
        .event_ready(cabac_res_event_ready),
        .event_kind(cabac_res_event_kind),
        .event_value(cabac_res_event_value),
        .event_coeff_idx(cabac_res_event_coeff_idx),
        .event_level_abs(cabac_res_event_level_abs),
        .event_level_sign(cabac_res_event_level_sign),
        .done(cabac_res_scan_done),
        .busy(cabac_res_scan_busy)
    );

    h264_cabac_residual4x4_bins u_cabac_res_bins (
        .clk(clk), .rst_n(rst_n),
        .event_valid(cabac_res_event_valid),
        .event_ready(cabac_res_event_ready),
        .event_kind(cabac_res_event_kind),
        .event_value(cabac_res_event_value),
        .event_coeff_idx(cabac_res_event_coeff_idx),
        .event_level_abs(cabac_res_event_level_abs),
        .event_level_sign(cabac_res_event_level_sign),
        .ctx_cbf_base(cabac_res_ctx_cbf_base_for(cabac_res_category)),
        // Keep the emitted helper ctxIdx at the category base and select the
        // actual context state in this wrapper. That mirrors the luma residual
        // path and lets the Cr AC expected-miss probe exercise a plane-local
        // CBF ctxInc without changing the standalone bin helper interface.
        .ctx_cbf_sel(2'd0),
        .ctx_sig_base(cabac_res_ctx_sig_base_for(cabac_res_category)),
        .ctx_last_base(cabac_res_ctx_last_base_for(cabac_res_category)),
        .ctx_level_gt1(cabac_res_ctx_level_gt1_for(cabac_res_category)),
        .ctx_level_gt2(cabac_res_ctx_level_gt2_for(cabac_res_category)),
        .ctx_sig_last_max(cabac_res_ctx_sig_last_max_for(cabac_res_category)),
        .bin_valid(cabac_res_bin_valid),
        .bin_ready(cabac_bin_ready),
        .bin_value(cabac_res_bin_value),
        .bin_bypass(cabac_res_bin_bypass),
        .bin_ctx_idx(cabac_res_bin_ctx_idx),
        .done(cabac_res_bin_done)
    );

    // Find MSB position of se_code1 (priority encoder)
    reg [3:0] se_msb;
    always @(*) begin
        casez (se_code1)
            11'b1??????????: se_msb = 4'd10;
            11'b01?????????: se_msb = 4'd9;
            11'b001????????: se_msb = 4'd8;
            11'b0001???????: se_msb = 4'd7;
            11'b00001??????: se_msb = 4'd6;
            11'b000001?????: se_msb = 4'd5;
            11'b0000001????: se_msb = 4'd4;
            11'b00000001???: se_msb = 4'd3;
            11'b000000001??: se_msb = 4'd2;
            11'b0000000001?: se_msb = 4'd1;
            default:         se_msb = 4'd0;
        endcase
    end

    // UE total bits = 2*se_msb + 1, value = se_code1 left-justified in 21-bit field
    wire [4:0] se_total_bits = {se_msb, 1'b0} + 5'd1;
    // Build the UE bitstream: se_msb leading zeros, then se_msb+1 bits of se_code1
    // Left-justify into 21 bits (max: 2*10+1=21)
    reg [20:0] se_ue_bits;
    always @(*) begin
        case (se_msb)
            4'd0:  se_ue_bits = {se_code1[0], 20'd0};
            4'd1:  se_ue_bits = {1'b0, se_code1[1:0], 18'd0};
            4'd2:  se_ue_bits = {2'b0, se_code1[2:0], 16'd0};
            4'd3:  se_ue_bits = {3'b0, se_code1[3:0], 14'd0};
            4'd4:  se_ue_bits = {4'b0, se_code1[4:0], 12'd0};
            4'd5:  se_ue_bits = {5'b0, se_code1[5:0], 10'd0};
            4'd6:  se_ue_bits = {6'b0, se_code1[6:0], 8'd0};
            4'd7:  se_ue_bits = {7'b0, se_code1[7:0], 6'd0};
            4'd8:  se_ue_bits = {8'b0, se_code1[8:0], 4'd0};
            4'd9:  se_ue_bits = {9'b0, se_code1[9:0], 2'd0};
            4'd10: se_ue_bits = {10'b0, se_code1[10:0]};
            default: se_ue_bits = {1'b1, 20'd0};
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= S_IDLE;
            return_state     <= S_IDLE;
            bit_buf          <= 96'd0;
            bit_cnt          <= 7'd0;
            bs_mem_addr      <= 24'd0;
            bs_mem_data      <= 8'd0;
            bs_mem_wr        <= 1'b0;
            bs_bytes_written <= 24'd0;
            busy             <= 1'b0;
            cmd_done         <= 1'b0;
            zero_cnt         <= 2'd0;
            sub              <= 7'd0;
            do_write         <= 1'b0;
            write_byte       <= 8'd0;
            fifo_wr_ptr      <= {CAVLC_FIFO_PTR_W{1'b0}};
            fifo_rd_ptr      <= {CAVLC_FIFO_PTR_W{1'b0}};
            cavlc_buf_valid  <= 1'b0;
            cavlc_buf_bits   <= 32'd0;
            cavlc_buf_count  <= 6'd0;
`ifdef VERILATOR
            dbg_fifo_deq_idx <= 0;
`endif
            skip_ep          <= 1'b0;
            se_input         <= 8'sd0;
            ue_input         <= 10'd0;
            pending_skip_run <= 13'd0;
            ipcm_sample_idx  <= 10'd0;
            pps_secondary_active <= 1'b0;
            cabac_slice_active <= 1'b0;
            cabac_mb_counter <= 12'd0;
            cabac_skip_ctx_state_0 <= 7'd0;
            cabac_skip_ctx_state_1 <= 7'd0;
            cabac_skip_ctx_state_2 <= 7'd0;
            cabac_pending_skip_ctx_idx <= 2'd0;
            cabac_mb_type_ctx_state_14 <= 7'd0;
            cabac_mb_type_ctx_state_15 <= 7'd0;
            cabac_mb_type_ctx_state_16 <= 7'd0;
            cabac_mvdx_ctx_state_0 <= 7'd0;
            cabac_mvdx_ctx_state_1 <= 7'd0;
            cabac_mvdx_ctx_state_2 <= 7'd0;
            cabac_mvdy_ctx_state_0 <= 7'd0;
            cabac_mvdy_ctx_state_1 <= 7'd0;
            cabac_mvdy_ctx_state_2 <= 7'd0;
            cabac_cbp_luma_ctx_state_73 <= 7'd0;
            cabac_cbp_luma_ctx_state_74 <= 7'd0;
            cabac_cbp_luma_ctx_state_75 <= 7'd0;
            cabac_cbp_luma_ctx_state_76 <= 7'd0;
            for (cabac_res_i = 0; cabac_res_i < 8; cabac_res_i = cabac_res_i + 1) begin
                cabac_cbp_chroma_ctx_state[cabac_res_i] <= 7'd0;
            end
            cabac_qp_delta_ctx_state_60 <= 7'd0;
            for (cabac_res_i = 0; cabac_res_i < 4; cabac_res_i = cabac_res_i + 1) begin
                cabac_res_cbf_ctx_state[cabac_res_i] <= 7'd0;
            end
            cabac_res_level_ctx_state_0 <= 7'd0;
            cabac_res_level_ctx_state_1 <= 7'd0;
            for (cabac_res_i = 0; cabac_res_i < 15; cabac_res_i = cabac_res_i + 1) begin
                cabac_res_sig_ctx_state[cabac_res_i] <= 7'd0;
                cabac_res_last_ctx_state[cabac_res_i] <= 7'd0;
            end
            for (cabac_res_i = 0; cabac_res_i < 4; cabac_res_i = cabac_res_i + 1) begin
                cabac_res_chroma_dc_cbf_ctx_state[cabac_res_i] <= 7'd0;
                cabac_res_chroma_ac_cbf_ctx_state[cabac_res_i] <= 7'd0;
                cabac_res_chroma_ac_cr_cbf_ctx_state[cabac_res_i] <= 7'd0;
            end
            cabac_res_chroma_dc_level_ctx_state_0 <= 7'd0;
            cabac_res_chroma_dc_level_ctx_state_1 <= 7'd0;
            for (cabac_res_i = 0; cabac_res_i < 3; cabac_res_i = cabac_res_i + 1) begin
                cabac_res_chroma_dc_sig_ctx_state[cabac_res_i] <= 7'd0;
                cabac_res_chroma_dc_last_ctx_state[cabac_res_i] <= 7'd0;
            end
            cabac_res_chroma_ac_level_ctx_state_0 <= 7'd0;
            cabac_res_chroma_ac_level_ctx_state_1 <= 7'd0;
            cabac_res_chroma_ac_cr_level_ctx_state_0 <= 7'd0;
            cabac_res_chroma_ac_cr_level_ctx_state_1 <= 7'd0;
            for (cabac_res_i = 0; cabac_res_i < 15; cabac_res_i = cabac_res_i + 1) begin
                cabac_res_chroma_ac_sig_ctx_state[cabac_res_i] <= 7'd0;
                cabac_res_chroma_ac_last_ctx_state[cabac_res_i] <= 7'd0;
                cabac_res_chroma_ac_cr_sig_ctx_state[cabac_res_i] <= 7'd0;
                cabac_res_chroma_ac_cr_last_ctx_state[cabac_res_i] <= 7'd0;
            end
            cabac_pending_ctx_kind <= CABAC_CTX_NONE;
            cabac_pending_ctx_sel <= 4'd0;
            cabac_pending_res_category <= CABAC_RES_CAT_LUMA;
            cabac_pending_res_block_idx <= 4'd0;
            cabac_res_block_idx <= 4'd0;
            cabac_res_category <= CABAC_RES_CAT_LUMA;
            cabac_res_scan_start <= 1'b0;
            cabac_res_scan_done_pending <= 1'b0;
            cabac_start <= 1'b0;
            cabac_bin_valid <= 1'b0;
            cabac_bin_value <= 1'b0;
            cabac_bin_bypass <= 1'b0;
            cabac_bin_terminate <= 1'b0;
            cabac_ctx_state_in <= 7'd0;
        end else begin
            bs_mem_wr <= 1'b0;
            cmd_done  <= 1'b0;
            cabac_start <= 1'b0;
            cabac_bin_valid <= 1'b0;
            cabac_bin_value <= 1'b0;
            cabac_bin_bypass <= 1'b0;
            cabac_bin_terminate <= 1'b0;
            cabac_res_scan_start <= 1'b0;

            if (cabac_ctx_state_wr) begin
                if (DEBUG_CABAC_P16X16 &&
                    ((cabac_pending_ctx_kind == CABAC_CTX_RES_CHRAC_CBF) ||
                     (cabac_pending_ctx_kind == CABAC_CTX_RES_CHRAC_SIG) ||
                     (cabac_pending_ctx_kind == CABAC_CTX_RES_CHRAC_LAST) ||
                     (cabac_pending_ctx_kind == CABAC_CTX_RES_CHRAC_LEVEL)))
                    $display("[CABACCTX] mb=%0d cat=%0d blk=%0d kind=%0d sel=%0d in=%0d out=%0d ari_low=%0h ari_range=%0d ari_queue=%0d ari_outstanding=%0d ari_pending=%0d ari_pbyte=%0h",
                             cabac_mb_counter, cabac_pending_res_category, cabac_pending_res_block_idx,
                             cabac_pending_ctx_kind, cabac_pending_ctx_sel,
                             cabac_ctx_state_in, cabac_ctx_state_out,
                             cabac_debug_low, cabac_debug_range, cabac_debug_queue,
                             cabac_debug_outstanding, cabac_debug_pending_valid, cabac_debug_pending_byte);
                case (cabac_pending_ctx_kind)
                    CABAC_CTX_SKIP: begin
                        case (cabac_pending_ctx_sel)
                            2'd0: cabac_skip_ctx_state_0 <= cabac_ctx_state_out;
                            2'd1: cabac_skip_ctx_state_1 <= cabac_ctx_state_out;
                            default: cabac_skip_ctx_state_2 <= cabac_ctx_state_out;
                        endcase
                    end
                    CABAC_CTX_MBTYPE14: cabac_mb_type_ctx_state_14 <= cabac_ctx_state_out;
                    CABAC_CTX_MBTYPE15: cabac_mb_type_ctx_state_15 <= cabac_ctx_state_out;
                    CABAC_CTX_MBTYPE16: cabac_mb_type_ctx_state_16 <= cabac_ctx_state_out;
                    CABAC_CTX_MVDX: begin
                        case (cabac_pending_ctx_sel)
                            2'd0: cabac_mvdx_ctx_state_0 <= cabac_ctx_state_out;
                            2'd1: cabac_mvdx_ctx_state_1 <= cabac_ctx_state_out;
                            default: cabac_mvdx_ctx_state_2 <= cabac_ctx_state_out;
                        endcase
                    end
                    CABAC_CTX_MVDY: begin
                        case (cabac_pending_ctx_sel)
                            2'd0: cabac_mvdy_ctx_state_0 <= cabac_ctx_state_out;
                            2'd1: cabac_mvdy_ctx_state_1 <= cabac_ctx_state_out;
                            default: cabac_mvdy_ctx_state_2 <= cabac_ctx_state_out;
                        endcase
                    end
                    CABAC_CTX_CBP0,
                    CABAC_CTX_CBP1,
                    CABAC_CTX_CBP2: begin
                        case (cabac_pending_ctx_sel)
                            2'd0: cabac_cbp_luma_ctx_state_76 <= cabac_ctx_state_out;
                            2'd1: cabac_cbp_luma_ctx_state_75 <= cabac_ctx_state_out;
                            2'd2: cabac_cbp_luma_ctx_state_74 <= cabac_ctx_state_out;
                            default: cabac_cbp_luma_ctx_state_73 <= cabac_ctx_state_out;
                        endcase
                    end
                    CABAC_CTX_CBP3: cabac_cbp_luma_ctx_state_76 <= cabac_ctx_state_out;
                    CABAC_CTX_CBPCHROMA: cabac_cbp_chroma_ctx_state[cabac_pending_ctx_sel[2:0]] <= cabac_ctx_state_out;
                    CABAC_CTX_QPDELTA: cabac_qp_delta_ctx_state_60 <= cabac_ctx_state_out;
                    CABAC_CTX_RES_CBF: cabac_res_cbf_ctx_state[cabac_pending_ctx_sel[1:0]] <= cabac_ctx_state_out;
                    CABAC_CTX_RES_SIG: cabac_res_sig_ctx_state[cabac_pending_ctx_sel] <= cabac_ctx_state_out;
                    CABAC_CTX_RES_LAST: cabac_res_last_ctx_state[cabac_pending_ctx_sel] <= cabac_ctx_state_out;
                    CABAC_CTX_RES_LEVEL: begin
                        if (cabac_pending_ctx_sel == 4'd0)
                            cabac_res_level_ctx_state_0 <= cabac_ctx_state_out;
                        else
                            cabac_res_level_ctx_state_1 <= cabac_ctx_state_out;
                    end
                    CABAC_CTX_RES_CHRDC_CBF: cabac_res_chroma_dc_cbf_ctx_state[cabac_pending_ctx_sel[1:0]] <= cabac_ctx_state_out;
                    CABAC_CTX_RES_CHRDC_SIG: cabac_res_chroma_dc_sig_ctx_state[cabac_pending_ctx_sel[1:0]] <= cabac_ctx_state_out;
                    CABAC_CTX_RES_CHRDC_LAST: cabac_res_chroma_dc_last_ctx_state[cabac_pending_ctx_sel[1:0]] <= cabac_ctx_state_out;
                    CABAC_CTX_RES_CHRDC_LEVEL: begin
                        if (cabac_pending_ctx_sel == 4'd0)
                            cabac_res_chroma_dc_level_ctx_state_0 <= cabac_ctx_state_out;
                        else
                            cabac_res_chroma_dc_level_ctx_state_1 <= cabac_ctx_state_out;
                    end
                    CABAC_CTX_RES_CHRAC_CBF: begin
                        if (cabac_pending_ctx_sel[2])
                            cabac_res_chroma_ac_cr_cbf_ctx_state[cabac_pending_ctx_sel[1:0]] <= cabac_ctx_state_out;
                        else
                            cabac_res_chroma_ac_cbf_ctx_state[cabac_pending_ctx_sel[1:0]] <= cabac_ctx_state_out;
                    end
                    CABAC_CTX_RES_CHRAC_SIG: begin
                        if (cabac_pending_ctx_sel[4])
                            cabac_res_chroma_ac_cr_sig_ctx_state[cabac_pending_ctx_sel[3:0]] <= cabac_ctx_state_out;
                        else
                            cabac_res_chroma_ac_sig_ctx_state[cabac_pending_ctx_sel[3:0]] <= cabac_ctx_state_out;
                    end
                    CABAC_CTX_RES_CHRAC_LAST: begin
                        if (cabac_pending_ctx_sel[4])
                            cabac_res_chroma_ac_cr_last_ctx_state[cabac_pending_ctx_sel[3:0]] <= cabac_ctx_state_out;
                        else
                            cabac_res_chroma_ac_last_ctx_state[cabac_pending_ctx_sel[3:0]] <= cabac_ctx_state_out;
                    end
                    CABAC_CTX_RES_CHRAC_LEVEL: begin
                        if (cabac_pending_ctx_sel[4]) begin
                            if (cabac_pending_ctx_sel[0] == 1'b0)
                                cabac_res_chroma_ac_cr_level_ctx_state_0 <= cabac_ctx_state_out;
                            else
                                cabac_res_chroma_ac_cr_level_ctx_state_1 <= cabac_ctx_state_out;
                        end else if (cabac_pending_ctx_sel[0] == 1'b0) begin
                            cabac_res_chroma_ac_level_ctx_state_0 <= cabac_ctx_state_out;
                        end else begin
                            cabac_res_chroma_ac_level_ctx_state_1 <= cabac_ctx_state_out;
                        end
                    end
                    default: begin end
                endcase
            end

            // Push to FIFO on valid (if full, we drop, but 64 entries should be plenty)
            if (cavlc_valid && cavlc_count > 6'd0) begin
                if (!fifo_full) begin
                    cavlc_fifo[fifo_wr_ptr] <= {cavlc_bits, cavlc_count};
                    fifo_wr_ptr <= fifo_wr_ptr + {{(CAVLC_FIFO_PTR_W-1){1'b0}}, 1'b1};
                end
            end

            if (do_write) begin
                if (zero_cnt >= 2'd2 && write_byte <= 8'h03) begin
                    bs_mem_data      <= 8'h03;
                    bs_mem_wr        <= 1'b1;
                    bs_mem_addr      <= bs_bytes_written;
                    bs_bytes_written <= bs_bytes_written + 24'd1;
                    zero_cnt         <= 2'd0;
                end else begin
                    bs_mem_data      <= write_byte;
                    bs_mem_wr        <= 1'b1;
                    bs_mem_addr      <= bs_bytes_written;
                    bs_bytes_written <= bs_bytes_written + 24'd1;
                    do_write         <= 1'b0;
                    zero_cnt         <= (write_byte == 8'h00) ? zero_cnt + 2'd1 : 2'd0;
                end
            end else begin
                case (state)
                    S_IDLE: begin
                        busy <= (!hold_fifo_drain && !fifo_empty) || (bit_cnt >= 7'd8) || do_write;
                        if (cmd_clear_fifo) begin
                            fifo_rd_ptr <= fifo_wr_ptr;
                            cmd_done <= 1'b1;
                            busy <= 1'b0;
                        end else if (cmd_write_sps) begin
                            state <= S_SPS; sub <= 6'd0; busy <= 1'b1;
                        end else if (cmd_write_pps) begin
                            state <= S_PPS; sub <= 6'd0; busy <= 1'b1; pps_secondary_active <= 1'b0;
                        end else if (cmd_write_slice_hdr) begin
                            state <= S_SLICE; sub <= 6'd0; busy <= 1'b1; cabac_slice_active <= cabac_slice_enable; cabac_mb_counter <= 12'd0; cabac_pending_ctx_kind <= CABAC_CTX_NONE; cabac_pending_ctx_sel <= 2'd0;
                        end else if (cmd_write_mb_header) begin
                            state <= S_MB_HDR; sub <= 6'd0; busy <= 1'b1; ipcm_sample_idx <= 10'd0; p8x8_sub_idx <= 3'd0; p8x8_mvd_idx <= 5'd0;
                        end else if (cmd_write_trailing) begin
                            state <= S_TRAIL; sub <= 6'd0; busy <= 1'b1;
                        end else if (cmd_flush) begin
                            state <= S_FLUSH; busy <= 1'b1;
                        end else if (!hold_fifo_drain && !fifo_empty) begin
`ifdef VERILATOR
                            dbg_fifo_deq_idx <= dbg_fifo_deq_idx + 1;
`endif
                            bit_buf <= bit_buf | (({fifo_rd_bits, 64'd0} >> bit_cnt[6:0]));
                            bit_cnt <= bit_cnt + {1'b0, fifo_rd_count};
                            fifo_rd_ptr <= fifo_rd_ptr + {{(CAVLC_FIFO_PTR_W-1){1'b0}}, 1'b1};
                            state   <= S_EMIT;
                            return_state <= S_IDLE;
                            busy <= 1'b1;
                        end else if (bit_cnt >= 7'd8) begin
                            state <= S_EMIT;
                            return_state <= S_IDLE;
                            busy <= 1'b1;
                        end
                    end

                    S_EMIT: begin
                        if (bit_cnt >= 7'd8) begin
                            `ifndef SYNTHESIS
                            if (DEBUG_CABAC_P16X16)
                                $display("[CABACEMIT] mb=%0d return_state=%0d return_sub=%0d byte=%02x bit_cnt=%0d bit_buf=%024x pending_kind=%0d pending_sel=%0d",
                                         cabac_mb_counter, return_state, sub, bit_buf[95:88], bit_cnt,
                                         bit_buf, cabac_pending_ctx_kind, cabac_pending_ctx_sel);
                            `endif
                            write_byte <= bit_buf[95:88];
                            do_write   <= 1'b1;
                            bit_buf    <= bit_buf << 8;
                            bit_cnt    <= bit_cnt - 7'd8;
                        end else begin
                            state <= return_state;
                        end
                    end

                    S_SPS: begin
                        // Dynamic SPS generation using UE encoder
                        // Field order per openh264 WelsWriteSpsSyntax (au_set.cpp:264-332)
                        case (sub)
                            // Start code 00 00 00 01
                            6'd0:  begin bs_mem_data<=8'h00; bs_mem_wr<=1'b1; bs_mem_addr<=bs_bytes_written; bs_bytes_written<=bs_bytes_written+24'd1; sub<=sub+6'd1; end
                            6'd1:  begin bs_mem_data<=8'h00; bs_mem_wr<=1'b1; bs_mem_addr<=bs_bytes_written; bs_bytes_written<=bs_bytes_written+24'd1; sub<=sub+6'd1; end
                            6'd2:  begin bs_mem_data<=8'h00; bs_mem_wr<=1'b1; bs_mem_addr<=bs_bytes_written; bs_bytes_written<=bs_bytes_written+24'd1; sub<=sub+6'd1; end
                            6'd3:  begin bs_mem_data<=8'h01; bs_mem_wr<=1'b1; bs_mem_addr<=bs_bytes_written; bs_bytes_written<=bs_bytes_written+24'd1; sub<=sub+6'd1; zero_cnt<=2'd0; end
                            // NAL header: forbidden=0, nal_ref_idc=3, nal_unit_type=7 (SPS) = 0_11_00111 = 0x67
                            6'd4:  begin write_byte<=8'h67; do_write<=1'b1; sub<=sub+6'd1; end
                            // profile_idc / constraint flags selected from bit depth + chroma format
                            6'd5:  begin
                                write_byte <= sps_profile_idc;
                                do_write<=1'b1; sub<=sub+6'd1;
                            end
                            6'd6:  begin
                                write_byte <= sps_constraint_flags;
                                do_write<=1'b1; sub<=sub+6'd1;
                            end
                            // level_idc: choose the smallest level class that fits the
                            // current frame macroblock count at the configured frame rate.
                            6'd7:  begin
                                write_byte <= select_level_idc(FRAME_MB_COUNT, FRAME_MBPS);
                                do_write <= 1'b1;
                                sub <= sub + 6'd1;
                            end
                            // sps_id=UE(0)='1'
                            // For High profiles: chroma_format_idc=UE(CHROMA_FORMAT_IDC),
                            //   bit_depth_luma_minus8, bit_depth_chroma_minus8,
                            //   qpprime_y_zero_transform_bypass=0,
                            //   seq_scaling_matrix_present=0
                            // Then: log2_max_frame_num_minus4=UE(0)='1'
                            // + poc_type=UE(2)='011' + max_num_ref_frames=UE(4)='00101'
                            // + gaps_in_frame_num=0
                            6'd8: begin
                                if (use_high_profile) begin
                                    // sps_id=UE(0) + chroma_format_idc=UE(...) and for 4:4:4 also separate_colour_plane_flag=0
                                    bit_buf <= {sps_id_and_chroma_bits, 89'd0};
                                    bit_cnt <= {4'd0, sps_id_and_chroma_len};
                                    // Set up UE for bit_depth_luma_minus8
                                    ue_input <= BIT_DEPTH - 8;
                                    sub <= 6'd20; // jump to High profile sub-states
                                end else begin
                                    ue_input <= 10'd0; // seq_parameter_set_id
                                    sub <= 6'd30;
                                end
                            end
                            // Load UE(pic_width_in_mbs_minus1) into bit buffer
                            6'd9: begin
                                bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits};
                                // Set up UE encoder for pic_height_in_map_units_minus1
                                ue_input <= MB_ROWS - 1;
                                sub <= sub + 6'd1;
                            end
                            // Emit bytes to make room in bit buffer
                            6'd10: begin
                                state <= S_EMIT;
                                return_state <= S_SPS;
                                sub <= sub + 6'd1;
                            end
                            // Load UE(pic_height_in_map_units_minus1) into bit buffer
                            6'd11: begin
                                bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits};
                                sub <= sub + 6'd1;
                            end
                            // frame_mbs_only=1, direct_8x8_inference=1,
                            // frame_cropping=0, vui_present=1, then a minimal VUI:
                            // aspect_ratio=0, overscan=0, video_signal=0, chroma_loc=0,
                            // timing_info_present=1
                            6'd12: begin
                                bit_buf <= bit_buf | ({9'b110100001, 87'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + 7'd9;
                                sub <= sub + 6'd1;
                            end
                            6'd13: begin
                                bit_buf <= bit_buf | ({VUI_NUM_UNITS_IN_TICK, 64'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + 7'd32;
                                sub <= sub + 6'd1;
                            end
                            6'd14: begin
                                state <= S_EMIT;
                                return_state <= S_SPS;
                                sub <= sub + 6'd1;
                            end
                            6'd15: begin
                                bit_buf <= bit_buf | ({VUI_TIME_SCALE, 64'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + 7'd32;
                                sub <= sub + 6'd1;
                            end
                            // fixed_frame_rate=1, nal_hrd=0, vcl_hrd=0,
                            // pic_struct_present=0, bitstream_restriction=1,
                            // motion_vectors_over_pic_boundaries=1,
                            // max_bytes_per_pic_denom=UE(0), max_bits_per_mb_denom=UE(0)
                            6'd16: begin
                                bit_buf <= bit_buf | ({8'b10001111, 88'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + 7'd8;
                                ue_input <= VUI_LOG2_MAX_MV_LENGTH;
                                sub <= sub + 6'd1;
                            end
                            6'd17: begin
                                bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits};
                                ue_input <= VUI_LOG2_MAX_MV_LENGTH;
                                sub <= sub + 6'd1;
                            end
                            6'd18: begin
                                bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits};
                                ue_input <= 10'd0; // num_reorder_frames
                                sub <= sub + 6'd1;
                            end
                            6'd19: begin
                                bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits};
                                ue_input <= 10'd4; // max_dec_frame_buffering for the current four-ref subset
                                sub <= 6'd24;
                            end
                            6'd24: begin
                                bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits};
                                sub <= 6'd25;
                            end
                            // RBSP trailing bits: stop bit '1' + alignment zeros
                            6'd25: begin
                                bit_buf <= bit_buf | ({1'b1, 95'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + 7'd1;
                                sub <= 6'd26;
                            end
                            6'd26: begin
                                if (bit_cnt[2:0] != 3'd0)
                                    bit_cnt <= bit_cnt + 7'd1;
                                else
                                    sub <= 6'd27;
                            end
                            6'd27: begin
                                state <= S_EMIT;
                                return_state <= S_SPS;
                                sub <= 6'd28;
                            end
                            6'd28: begin cmd_done<=1'b1; busy<=1'b0; state<=S_IDLE; zero_cnt<=2'd0; end

                            // High 10 profile extra SPS fields (sub 20-25)
                            // Load UE(bit_depth_luma_minus8) into bit buffer
                            6'd20: begin
                                bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits};
                                // Set up UE for bit_depth_chroma_minus8
                                ue_input <= BIT_DEPTH - 8;
                                sub <= sub + 6'd1;
                            end
                            // Load UE(bit_depth_chroma_minus8) into bit buffer
                            6'd21: begin
                                bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits};
                                sub <= sub + 6'd1;
                            end
                            // qpprime_y_zero_transform_bypass=0, seq_scaling_matrix_present=0
                            // Then: log2_max_frame_num_minus4=UE(4)='00101'
                            // + poc_type=UE(0)='1' (poc_type=0)
                            // + log2_max_pic_order_cnt_lsb_minus4=UE(5)='00110' (max_poc_lsb=512)
                            // + max_num_ref_frames=UE(4)='00101'
                            // + gaps_in_frame_num=0
                            // = 0,0 + 00101,1,00110,00101,0 = 19 bits: 0000101100110001010
                            6'd22: begin
                                bit_buf <= bit_buf | ({19'b0000101100110001010, 77'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + 7'd19;
                                // Emit to make room
                                state <= S_EMIT;
                                return_state <= S_SPS;
                                sub <= sub + 6'd1;
                            end
                            // Set up UE for pic_width_in_mbs_minus1, rejoin main path at sub 9
                            6'd23: begin
                                ue_input <= MB_COLS - 1;
                                sub <= 6'd9;
                            end

                            // Baseline/Main SPS extra fields, using the shared UE encoder
                            6'd30: begin
                                bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits};
                                ue_input <= LOG2_MAX_FRAME_NUM_MINUS4[9:0];
                                sub <= 6'd31;
                            end
                            6'd31: begin
                                bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits};
                                ue_input <= 10'd0; // pic_order_cnt_type = 0
                                sub <= 6'd32;
                            end
                            6'd32: begin
                                bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits};
                                ue_input <= LOG2_MAX_POC_LSB_MINUS4[9:0];
                                sub <= 6'd33;
                            end
                            6'd33: begin
                                bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits};
                                ue_input <= 10'd4; // max_num_ref_frames
                                sub <= 6'd34;
                            end
                            6'd34: begin
                                bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits} + 7'd1; // gaps_in_frame_num_allowed_flag = 0
                                ue_input <= MB_COLS - 1;
                                sub <= 6'd9;
                            end

                            default: state <= S_IDLE;
                        endcase
                    end

                    S_PPS: begin
                        case (sub)
                            6'd0:  begin bs_mem_data<=8'h00; bs_mem_wr<=1'b1; bs_mem_addr<=bs_bytes_written; bs_bytes_written<=bs_bytes_written+24'd1; sub<=sub+6'd1; end
                            6'd1:  begin bs_mem_data<=8'h00; bs_mem_wr<=1'b1; bs_mem_addr<=bs_bytes_written; bs_bytes_written<=bs_bytes_written+24'd1; sub<=sub+6'd1; end
                            6'd2:  begin bs_mem_data<=8'h00; bs_mem_wr<=1'b1; bs_mem_addr<=bs_bytes_written; bs_bytes_written<=bs_bytes_written+24'd1; sub<=sub+6'd1; end
                            6'd3:  begin bs_mem_data<=8'h01; bs_mem_wr<=1'b1; bs_mem_addr<=bs_bytes_written; bs_bytes_written<=bs_bytes_written+24'd1; sub<=sub+6'd1; zero_cnt<=2'd0; end
                            6'd4:  begin write_byte<=8'h68; do_write<=1'b1; sub<=6'd5; end
                            6'd5: begin
                                ue_input <= pps_secondary_active ? 10'd1 : 10'd0;
                                sub <= 6'd14;
                            end
                            6'd14: begin
                                bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits};
                                ue_input <= 10'd0; // seq_parameter_set_id
                                sub <= 6'd15;
                            end
                            6'd15: begin
                                bit_buf <= bit_buf |
                                           ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]) |
                                           (({pps_secondary_active, 1'b0, 94'd0}) >> (bit_cnt + {2'b0, ue_total_bits}));
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits} + 7'd2;
                                ue_input <= 10'd0; // num_slice_groups_minus1
                                sub <= 6'd16;
                            end
                            6'd16: begin
                                bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits};
                                ue_input <= 10'd0; // num_ref_idx_l0_default_active_minus1
                                sub <= 6'd17;
                            end
                            6'd17: begin
                                bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits};
                                ue_input <= 10'd0; // num_ref_idx_l1_default_active_minus1
                                sub <= 6'd18;
                            end
                            6'd18: begin
                                bit_buf <= bit_buf |
                                           ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]) |
                                           (({weighted_pred_flag, weighted_bipred_idc, 93'd0}) >> (bit_cnt + {2'b0, ue_total_bits}));
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits} + 7'd3;
                                se_input <= pic_init_qp_minus26; // pic_init_qp_minus26
                                sub <= 6'd19;
                            end
                            6'd19: begin
                                bit_buf <= bit_buf | ({se_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, se_total_bits};
                                se_input <= 9'sd0; // pic_init_qs_minus26
                                sub <= 6'd20;
                            end
                            6'd20: begin
                                bit_buf <= bit_buf | ({se_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, se_total_bits};
                                se_input <= chroma_qp_index_offset; // chroma_qp_index_offset
                                sub <= 6'd21;
                            end
                            6'd21: begin
                                if (use_high_profile) begin
                                    bit_buf <= bit_buf |
                                               ({se_ue_bits, 75'd0} >> bit_cnt[6:0]) |
                                               (({5'b10000, 91'd0}) >> (bit_cnt + {2'b0, se_total_bits}));
                                    bit_cnt <= bit_cnt + {2'b0, se_total_bits} + 7'd5;
                                    se_input <= second_chroma_qp_index_offset; // second_chroma_qp_index_offset
                                    sub <= 6'd22;
                                end else begin
                                    bit_buf <= bit_buf |
                                               ({se_ue_bits, 75'd0} >> bit_cnt[6:0]) |
                                               (({3'b100, 93'd0}) >> (bit_cnt + {2'b0, se_total_bits}));
                                    bit_cnt <= bit_cnt + {2'b0, se_total_bits} + 7'd3;
                                    sub <= 6'd10;
                                end
                            end
                            6'd22: begin
                                bit_buf <= bit_buf | ({se_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, se_total_bits};
                                sub <= 6'd10;
                            end
                            6'd10: begin
                                bit_buf <= bit_buf | ({1'b1, 95'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + 7'd1;
                                sub <= 6'd11;
                            end
                            6'd11: begin
                                if (bit_cnt[2:0] != 3'd0)
                                    bit_cnt <= bit_cnt + 7'd1;
                                else
                                    sub <= 6'd12;
                            end
                            6'd12: begin
                                state <= S_EMIT;
                                return_state <= S_PPS;
                                sub <= 6'd13;
                            end
                            6'd13: begin
                                if (cabac_feature_enable && !pps_secondary_active) begin
                                    pps_secondary_active <= 1'b1;
                                    bit_buf <= 96'd0;
                                    bit_cnt <= 7'd0;
                                    zero_cnt <= 2'd0;
                                    sub <= 6'd0;
                                end else begin
                                    pps_secondary_active <= 1'b0;
                                    cmd_done<=1'b1; busy<=1'b0; state<=S_IDLE; zero_cnt<=2'd0;
                                end
                            end
                            default: state <= S_IDLE;
                        endcase
                    end

                    S_SLICE: begin
                        case (sub)
                            6'd0:  begin bs_mem_data<=8'h00; bs_mem_wr<=1'b1; bs_mem_addr<=bs_bytes_written; bs_bytes_written<=bs_bytes_written+24'd1; sub<=sub+6'd1; end
                            6'd1:  begin bs_mem_data<=8'h00; bs_mem_wr<=1'b1; bs_mem_addr<=bs_bytes_written; bs_bytes_written<=bs_bytes_written+24'd1; sub<=sub+6'd1; end
                            6'd2:  begin bs_mem_data<=8'h00; bs_mem_wr<=1'b1; bs_mem_addr<=bs_bytes_written; bs_bytes_written<=bs_bytes_written+24'd1; sub<=sub+6'd1; end
                            6'd3:  begin bs_mem_data<=8'h01; bs_mem_wr<=1'b1; bs_mem_addr<=bs_bytes_written; bs_bytes_written<=bs_bytes_written+24'd1; sub<=sub+6'd1; zero_cnt<=2'd0; end
                            6'd4: begin
                                if (is_p_slice)
                                    write_byte <= 8'h41; // nal_ref_idc=2, nal_unit_type=1 (non-IDR)
                                else if (is_b_slice && is_b_ref_slice)
                                    write_byte <= 8'h41; // nal_ref_idc=2, nal_unit_type=1 (reference B-slice)
                                else if (is_b_slice)
                                    write_byte <= 8'h01; // nal_ref_idc=0, nal_unit_type=1 (non-IDR B-slice)
                                else
                                    write_byte <= 8'h65; // nal_ref_idc=3, nal_unit_type=5 (IDR)
                                do_write <= 1'b1;
                                sub <= sub + 6'd1;
                            end
                            6'd5: begin
                                if (is_p_slice) begin
                                    if (cabac_slice_active) begin
                                        // Minimal CABAC P-slice subset:
                                        // first_mb=UE(0), slice_type=P, pic_parameter_set_id=UE(1),
                                        // frame_num, pic_order_cnt_lsb, num_ref_idx_active_override_flag=0,
                                        // ref_pic_list_reordering_flag_l0=0, adaptive_ref_pic_marking_mode_flag=0,
                                        // cabac_init_idc=UE(0), slice_qp_delta=SE(0), deblocking=UE(1).
                                        bit_buf <= {1'b1, 1'b1, 3'b010, frame_num, pic_order_cnt_lsb,
                                                    1'b0, 1'b0, 1'b0, 1'b1, 1'b1, 3'b010, 66'd0};
                                        bit_cnt <= 7'd30;
                                        sub <= 6'd30;
                                    end else if (weighted_pred_flag) begin
                                        if (use_high_profile) begin
                                            // P-slice base header up to ref_pic_list_reordering_flag_l0.
                                            if (slice_multi_ref_enable) begin
                                                bit_buf <= {3'b111, frame_num, pic_order_cnt_lsb, slice_multi_ref_bits, 71'd0};
                                                bit_cnt <= 7'd20 + {3'd0, slice_multi_ref_bits_len};
                                            end else begin
                                                bit_buf <= {3'b111, frame_num, pic_order_cnt_lsb, 2'b00, 74'd0};
                                                bit_cnt <= 7'd22;
                                            end
                                        end else begin
                                            if (slice_multi_ref_enable) begin
                                                bit_buf <= {3'b111, frame_num, pic_order_cnt_lsb, slice_multi_ref_bits, 71'd0};
                                                bit_cnt <= 7'd20 + {3'd0, slice_multi_ref_bits_len};
                                            end else begin
                                                bit_buf <= {3'b111, frame_num, pic_order_cnt_lsb, 2'b00, 74'd0};
                                                bit_cnt <= 7'd22;
                                            end
                                        end
                                        ue_input <= {6'd0, luma_log2_weight_denom};
                                        sub <= 6'd8;
                                    end else begin
                                        if (use_high_profile) begin
                                            // High-profile P-slice: SPS has poc_type=0, need poc_lsb(9 bits)
                                            // first_mb=UE(0)'1', slice_type(P)=UE(0)'1', pps_id=UE(0)'1',
                                            // frame_num(8), poc_lsb(9), num_ref_override=0, ref_list_reorder=0,
                                            // adaptive_marking=0, qp_delta=SE(0)'1', disable_deblocking=UE(1)'010'
                                            if (slice_multi_ref_enable) begin
                                                bit_buf <= {3'b111, frame_num, pic_order_cnt_lsb, slice_multi_ref_bits_qp, 64'd0};
                                                bit_cnt <= 7'd20 + {3'd0, slice_multi_ref_bits_qp_len};
                                            end else begin
                                                bit_buf <= {3'b111, frame_num, pic_order_cnt_lsb, 4'b0001, 3'b010, 69'd0};
                                                bit_cnt <= 7'd27;
                                            end
                                        end else begin
                                            // Baseline/Main P-slice: SPS now uses poc_type=0, so emit poc_lsb(9 bits)
                                            if (slice_multi_ref_enable) begin
                                                bit_buf <= {3'b111, frame_num, pic_order_cnt_lsb, slice_multi_ref_bits_qp, 64'd0};
                                                bit_cnt <= 7'd20 + {3'd0, slice_multi_ref_bits_qp_len};
                                            end else begin
                                                bit_buf <= {3'b111, frame_num, pic_order_cnt_lsb, 4'b0001, 3'b010, 69'd0};
                                                bit_cnt <= 7'd27;
                                            end
                                        end
                                        sub <= sub + 6'd1;
                                    end
                                end else if (is_b_slice) begin
                                    if (weighted_pred_flag) begin
                                        // B-slice base header up to ref_pic_list_reordering_flag_l1.
                                        // When slice_multi_ref_enable is set on the current limited B path,
                                        // emit num_ref_idx_active_override_flag=1,
                                        // num_ref_idx_l0_active_minus1, num_ref_idx_l1_active_minus1=0,
                                        // ref_pic_list_reordering_flag_l0=0, ref_pic_list_reordering_flag_l1=0
                                        // before the weighted pred_weight_table.
                                        if (slice_multi_ref_enable) begin
                                            bit_buf <= {1'b1, 3'b010, 1'b1, frame_num, pic_order_cnt_lsb, direct_spatial_mv_pred_flag, b_slice_multi_ref_bits, 64'd0};
                                            bit_cnt <= 7'd23 + {3'd0, b_slice_multi_ref_bits_len};
                                        end else begin
                                            bit_buf <= {1'b1, 3'b010, 1'b1, frame_num, pic_order_cnt_lsb, direct_spatial_mv_pred_flag, 3'b000, 70'd0};
                                            bit_cnt <= 7'd26;
                                        end
                                        ue_input <= {6'd0, luma_log2_weight_denom};
                                        sub <= 6'd8;
                                    end else begin
                                        // Non-weighted B-slice header on the current limited reordered B path.
                                        if (slice_multi_ref_enable) begin
                                            if (is_b_ref_slice) begin
                                                bit_buf <= {1'b1, 3'b010, 1'b1, frame_num, pic_order_cnt_lsb, direct_spatial_mv_pred_flag, b_slice_multi_ref_bits_qp_ref, 59'd0};
                                                bit_cnt <= 7'd23 + {3'd0, b_slice_multi_ref_bits_qp_ref_len};
                                            end else begin
                                                bit_buf <= {1'b1, 3'b010, 1'b1, frame_num, pic_order_cnt_lsb, direct_spatial_mv_pred_flag, b_slice_multi_ref_bits_qp_nonref, 60'd0};
                                                bit_cnt <= 7'd23 + {3'd0, b_slice_multi_ref_bits_qp_nonref_len};
                                            end
                                        end else begin
                                            // first_mb=UE(0), slice_type(B)=UE(1), pps_id=UE(0), frame_num(8),
                                            // pic_order_cnt_lsb(9), direct_spatial_mv_pred_flag,
                                            // num_ref_idx_active_override_flag=0, ref_pic_list_reordering_flag_l0=0,
                                            // ref_pic_list_reordering_flag_l1=0, optional adaptive_ref_pic_marking_mode_flag,
                                            // slice_qp_delta=SE(0), deblocking=UE(1)
                                            if (is_b_ref_slice) begin
                                                bit_buf <= {1'b1, 3'b010, 1'b1, frame_num, pic_order_cnt_lsb, direct_spatial_mv_pred_flag, 5'b00001, 3'b010, 65'd0};
                                                bit_cnt <= 7'd31;
                                            end else begin
                                                bit_buf <= {1'b1, 3'b010, 1'b1, frame_num, pic_order_cnt_lsb, direct_spatial_mv_pred_flag, 4'b0001, 3'b010, 66'd0};
                                                bit_cnt <= 7'd30;
                                            end
                                        end
                                        sub <= sub + 6'd1;
                                    end
                                end else begin
                                    if (use_high_profile) begin
                                        // High-profile IDR: SPS has poc_type=0, need poc_lsb(9 bits)
                                        // first_mb=UE(0)'1', slice_type(I)=UE(2)'011', pps_id=UE(0)'1',
                                        // frame_num(8), idr_pic_id=UE(0)'1', poc_lsb(9),
                                        // no_output_of_prior_pics=0, long_term_ref=0,
                                        // qp_delta=SE(0)'1', disable_deblocking=UE(1)'010'
                                        bit_buf <= {1'b1, 3'b011, 1'b1, frame_num, 1'b1, pic_order_cnt_lsb, 2'b00, 1'b1, 3'b010, 67'd0};
                                        bit_cnt <= 7'd29;
                                    end else begin
                                        // Baseline/Main IDR: SPS now uses poc_type=0, so emit poc_lsb(9 bits)
                                        bit_buf <= {1'b1, 3'b011, 1'b1, frame_num, 1'b1, pic_order_cnt_lsb, 2'b00, 1'b1, 3'b010, 67'd0};
                                        bit_cnt <= 7'd29;
                                    end
                                    sub <= sub + 6'd1;
                                end
                            end
                            6'd6: begin
                                state <= S_EMIT;
                                return_state <= S_SLICE;
                                sub <= sub + 6'd1;
                            end
                            6'd7: begin
                                if (cabac_slice_active) begin
                                    cabac_skip_ctx_state_0 <= cabac_pskip_ctx_init(2'd0);
                                    cabac_skip_ctx_state_1 <= cabac_pskip_ctx_init(2'd1);
                                    cabac_skip_ctx_state_2 <= cabac_pskip_ctx_init(2'd2);
                                    cabac_mb_type_ctx_state_14 <= cabac_init_state(1, 9, 26);
                                    cabac_mb_type_ctx_state_15 <= cabac_init_state(0, 49, 26);
                                    cabac_mb_type_ctx_state_16 <= cabac_init_state(-37, 118, 26);
                                    cabac_mvdx_ctx_state_0 <= cabac_init_state(-3, 69, 26);
                                    cabac_mvdx_ctx_state_1 <= cabac_init_state(-6, 81, 26);
                                    cabac_mvdx_ctx_state_2 <= cabac_init_state(-11, 96, 26);
                                    cabac_mvdy_ctx_state_0 <= cabac_init_state(0, 58, 26);
                                    cabac_mvdy_ctx_state_1 <= cabac_init_state(-3, 76, 26);
                                    cabac_mvdy_ctx_state_2 <= cabac_init_state(-10, 94, 26);
                                    cabac_cbp_luma_ctx_state_73 <= cabac_init_state(-27, 126, 26);
                                    cabac_cbp_luma_ctx_state_74 <= cabac_init_state(-28, 98, 26);
                                    cabac_cbp_luma_ctx_state_75 <= cabac_init_state(-25, 101, 26);
                                    cabac_cbp_luma_ctx_state_76 <= cabac_init_state(-23, 67, 26);
                                    cabac_cbp_chroma_ctx_state[0] <= cabac_init_state(-28, 82, 26);
                                    cabac_cbp_chroma_ctx_state[1] <= cabac_init_state(-20, 94, 26);
                                    cabac_qp_delta_ctx_state_60 <= cabac_init_state(0, 41, 26);
                                    cabac_res_cbf_ctx_state[0] <= cabac_init_state(-7, 92, 26);
                                    cabac_res_cbf_ctx_state[1] <= cabac_init_state(-5, 89, 26);
                                    cabac_res_cbf_ctx_state[2] <= cabac_init_state(-7, 96, 26);
                                    cabac_res_cbf_ctx_state[3] <= cabac_init_state(-13, 108, 26);
                                    cabac_res_sig_ctx_state[0] <= cabac_init_state(-2, 85, 26);
                                    cabac_res_sig_ctx_state[1] <= cabac_init_state(-6, 78, 26);
                                    cabac_res_sig_ctx_state[2] <= cabac_init_state(-1, 75, 26);
                                    cabac_res_sig_ctx_state[3] <= cabac_init_state(-7, 77, 26);
                                    cabac_res_sig_ctx_state[4] <= cabac_init_state(2, 54, 26);
                                    cabac_res_sig_ctx_state[5] <= cabac_init_state(5, 50, 26);
                                    cabac_res_sig_ctx_state[6] <= cabac_init_state(-3, 68, 26);
                                    cabac_res_sig_ctx_state[7] <= cabac_init_state(1, 50, 26);
                                    cabac_res_sig_ctx_state[8] <= cabac_init_state(6, 42, 26);
                                    cabac_res_sig_ctx_state[9] <= cabac_init_state(-4, 81, 26);
                                    cabac_res_sig_ctx_state[10] <= cabac_init_state(1, 63, 26);
                                    cabac_res_sig_ctx_state[11] <= cabac_init_state(-4, 70, 26);
                                    cabac_res_sig_ctx_state[12] <= cabac_init_state(0, 67, 26);
                                    cabac_res_sig_ctx_state[13] <= cabac_init_state(2, 57, 26);
                                    cabac_res_sig_ctx_state[14] <= cabac_init_state(-2, 76, 26);
                                    cabac_res_last_ctx_state[0] <= cabac_init_state(11, 28, 26);
                                    cabac_res_last_ctx_state[1] <= cabac_init_state(2, 40, 26);
                                    cabac_res_last_ctx_state[2] <= cabac_init_state(3, 44, 26);
                                    cabac_res_last_ctx_state[3] <= cabac_init_state(0, 49, 26);
                                    cabac_res_last_ctx_state[4] <= cabac_init_state(0, 46, 26);
                                    cabac_res_last_ctx_state[5] <= cabac_init_state(2, 44, 26);
                                    cabac_res_last_ctx_state[6] <= cabac_init_state(2, 51, 26);
                                    cabac_res_last_ctx_state[7] <= cabac_init_state(0, 47, 26);
                                    cabac_res_last_ctx_state[8] <= cabac_init_state(4, 39, 26);
                                    cabac_res_last_ctx_state[9] <= cabac_init_state(2, 62, 26);
                                    cabac_res_last_ctx_state[10] <= cabac_init_state(6, 46, 26);
                                    cabac_res_last_ctx_state[11] <= cabac_init_state(0, 54, 26);
                                    cabac_res_last_ctx_state[12] <= cabac_init_state(3, 54, 26);
                                    cabac_res_last_ctx_state[13] <= cabac_init_state(2, 58, 26);
                                    cabac_res_last_ctx_state[14] <= cabac_init_state(4, 63, 26);
                                    cabac_res_level_ctx_state_0 <= cabac_init_state(-6, 76, 26);
                                    cabac_res_level_ctx_state_1 <= cabac_init_state(-2, 59, 26);

                                    // Chroma residual CABAC contexts for the dormant
                                    // P16x16 chroma DC/AC residual lane.  Keep these
                                    // initialized from the same cabac_init_idc=0 / QP=26
                                    // table as the luma residual contexts so that lifting
                                    // the top-level chroma guard does not start from reset
                                    // state 0 for ctxIdx 97/101/149/152/210/213/257/266.
                                    cabac_res_chroma_dc_cbf_ctx_state[0] <= cabac_init_state(5, 54, 26);
                                    cabac_res_chroma_dc_cbf_ctx_state[1] <= cabac_init_state(6, 60, 26);
                                    cabac_res_chroma_dc_cbf_ctx_state[2] <= cabac_init_state(6, 59, 26);
                                    cabac_res_chroma_dc_cbf_ctx_state[3] <= cabac_init_state(6, 69, 26);
                                    cabac_res_chroma_dc_sig_ctx_state[0] <= cabac_init_state(3, 64, 26);
                                    cabac_res_chroma_dc_sig_ctx_state[1] <= cabac_init_state(1, 61, 26);
                                    cabac_res_chroma_dc_sig_ctx_state[2] <= cabac_init_state(9, 63, 26);
                                    cabac_res_chroma_dc_last_ctx_state[0] <= cabac_init_state(1, 67, 26);
                                    cabac_res_chroma_dc_last_ctx_state[1] <= cabac_init_state(5, 59, 26);
                                    cabac_res_chroma_dc_last_ctx_state[2] <= cabac_init_state(9, 67, 26);
                                    cabac_res_chroma_dc_level_ctx_state_0 <= cabac_init_state(0, 70, 26);
                                    cabac_res_chroma_dc_level_ctx_state_1 <= cabac_init_state(-2, 58, 26);

                                    cabac_res_chroma_ac_cbf_ctx_state[0] <= cabac_init_state(-1, 48, 26);
                                    cabac_res_chroma_ac_cr_cbf_ctx_state[0] <= cabac_init_state(-1, 48, 26);
                                    cabac_res_chroma_ac_cbf_ctx_state[1] <= cabac_init_state(0, 68, 26);
                                    cabac_res_chroma_ac_cr_cbf_ctx_state[1] <= cabac_init_state(0, 68, 26);
                                    cabac_res_chroma_ac_cbf_ctx_state[2] <= cabac_init_state(-4, 69, 26);
                                    cabac_res_chroma_ac_cr_cbf_ctx_state[2] <= cabac_init_state(-4, 69, 26);
                                    cabac_res_chroma_ac_cbf_ctx_state[3] <= cabac_init_state(-8, 88, 26);
                                    cabac_res_chroma_ac_cr_cbf_ctx_state[3] <= cabac_init_state(-8, 88, 26);
                                    cabac_res_chroma_ac_sig_ctx_state[0] <= cabac_init_state(7, 50, 26);
                                    cabac_res_chroma_ac_cr_sig_ctx_state[0] <= cabac_init_state(7, 50, 26);
                                    cabac_res_chroma_ac_sig_ctx_state[1] <= cabac_init_state(16, 39, 26);
                                    cabac_res_chroma_ac_cr_sig_ctx_state[1] <= cabac_init_state(16, 39, 26);
                                    cabac_res_chroma_ac_sig_ctx_state[2] <= cabac_init_state(5, 44, 26);
                                    cabac_res_chroma_ac_cr_sig_ctx_state[2] <= cabac_init_state(5, 44, 26);
                                    cabac_res_chroma_ac_sig_ctx_state[3] <= cabac_init_state(4, 52, 26);
                                    cabac_res_chroma_ac_cr_sig_ctx_state[3] <= cabac_init_state(4, 52, 26);
                                    cabac_res_chroma_ac_sig_ctx_state[4] <= cabac_init_state(11, 48, 26);
                                    cabac_res_chroma_ac_cr_sig_ctx_state[4] <= cabac_init_state(11, 48, 26);
                                    cabac_res_chroma_ac_sig_ctx_state[5] <= cabac_init_state(-5, 60, 26);
                                    cabac_res_chroma_ac_cr_sig_ctx_state[5] <= cabac_init_state(-5, 60, 26);
                                    cabac_res_chroma_ac_sig_ctx_state[6] <= cabac_init_state(-1, 59, 26);
                                    cabac_res_chroma_ac_cr_sig_ctx_state[6] <= cabac_init_state(-1, 59, 26);
                                    cabac_res_chroma_ac_sig_ctx_state[7] <= cabac_init_state(0, 59, 26);
                                    cabac_res_chroma_ac_cr_sig_ctx_state[7] <= cabac_init_state(0, 59, 26);
                                    cabac_res_chroma_ac_sig_ctx_state[8] <= cabac_init_state(22, 33, 26);
                                    cabac_res_chroma_ac_cr_sig_ctx_state[8] <= cabac_init_state(22, 33, 26);
                                    cabac_res_chroma_ac_sig_ctx_state[9] <= cabac_init_state(5, 44, 26);
                                    cabac_res_chroma_ac_cr_sig_ctx_state[9] <= cabac_init_state(5, 44, 26);
                                    cabac_res_chroma_ac_sig_ctx_state[10] <= cabac_init_state(14, 43, 26);
                                    cabac_res_chroma_ac_cr_sig_ctx_state[10] <= cabac_init_state(14, 43, 26);
                                    cabac_res_chroma_ac_sig_ctx_state[11] <= cabac_init_state(-1, 78, 26);
                                    cabac_res_chroma_ac_cr_sig_ctx_state[11] <= cabac_init_state(-1, 78, 26);
                                    cabac_res_chroma_ac_sig_ctx_state[12] <= cabac_init_state(0, 60, 26);
                                    cabac_res_chroma_ac_cr_sig_ctx_state[12] <= cabac_init_state(0, 60, 26);
                                    cabac_res_chroma_ac_sig_ctx_state[13] <= cabac_init_state(9, 69, 26);
                                    cabac_res_chroma_ac_cr_sig_ctx_state[13] <= cabac_init_state(9, 69, 26);
                                    cabac_res_chroma_ac_sig_ctx_state[14] <= cabac_init_state(11, 28, 26);
                                    cabac_res_chroma_ac_cr_sig_ctx_state[14] <= cabac_init_state(11, 28, 26);
                                    cabac_res_chroma_ac_last_ctx_state[0] <= cabac_init_state(16, 30, 26);
                                    cabac_res_chroma_ac_cr_last_ctx_state[0] <= cabac_init_state(16, 30, 26);
                                    cabac_res_chroma_ac_last_ctx_state[1] <= cabac_init_state(18, 32, 26);
                                    cabac_res_chroma_ac_cr_last_ctx_state[1] <= cabac_init_state(18, 32, 26);
                                    cabac_res_chroma_ac_last_ctx_state[2] <= cabac_init_state(18, 35, 26);
                                    cabac_res_chroma_ac_cr_last_ctx_state[2] <= cabac_init_state(18, 35, 26);
                                    cabac_res_chroma_ac_last_ctx_state[3] <= cabac_init_state(22, 29, 26);
                                    cabac_res_chroma_ac_cr_last_ctx_state[3] <= cabac_init_state(22, 29, 26);
                                    cabac_res_chroma_ac_last_ctx_state[4] <= cabac_init_state(24, 31, 26);
                                    cabac_res_chroma_ac_cr_last_ctx_state[4] <= cabac_init_state(24, 31, 26);
                                    cabac_res_chroma_ac_last_ctx_state[5] <= cabac_init_state(23, 38, 26);
                                    cabac_res_chroma_ac_cr_last_ctx_state[5] <= cabac_init_state(23, 38, 26);
                                    cabac_res_chroma_ac_last_ctx_state[6] <= cabac_init_state(18, 43, 26);
                                    cabac_res_chroma_ac_cr_last_ctx_state[6] <= cabac_init_state(18, 43, 26);
                                    cabac_res_chroma_ac_last_ctx_state[7] <= cabac_init_state(20, 41, 26);
                                    cabac_res_chroma_ac_cr_last_ctx_state[7] <= cabac_init_state(20, 41, 26);
                                    cabac_res_chroma_ac_last_ctx_state[8] <= cabac_init_state(11, 63, 26);
                                    cabac_res_chroma_ac_cr_last_ctx_state[8] <= cabac_init_state(11, 63, 26);
                                    cabac_res_chroma_ac_last_ctx_state[9] <= cabac_init_state(9, 59, 26);
                                    cabac_res_chroma_ac_cr_last_ctx_state[9] <= cabac_init_state(9, 59, 26);
                                    cabac_res_chroma_ac_last_ctx_state[10] <= cabac_init_state(9, 64, 26);
                                    cabac_res_chroma_ac_cr_last_ctx_state[10] <= cabac_init_state(9, 64, 26);
                                    cabac_res_chroma_ac_last_ctx_state[11] <= cabac_init_state(-1, 94, 26);
                                    cabac_res_chroma_ac_cr_last_ctx_state[11] <= cabac_init_state(-1, 94, 26);
                                    cabac_res_chroma_ac_last_ctx_state[12] <= cabac_init_state(-2, 89, 26);
                                    cabac_res_chroma_ac_cr_last_ctx_state[12] <= cabac_init_state(-2, 89, 26);
                                    cabac_res_chroma_ac_last_ctx_state[13] <= cabac_init_state(-9, 108, 26);
                                    cabac_res_chroma_ac_cr_last_ctx_state[13] <= cabac_init_state(-9, 108, 26);
                                    cabac_res_chroma_ac_last_ctx_state[14] <= cabac_init_state(-6, 76, 26);
                                    cabac_res_chroma_ac_cr_last_ctx_state[14] <= cabac_init_state(-6, 76, 26);
                                    cabac_res_chroma_ac_level_ctx_state_0 <= cabac_init_state(0, 58, 26);
                                    cabac_res_chroma_ac_level_ctx_state_1 <= cabac_init_state(-13, 106, 26);
                                    cabac_res_chroma_ac_cr_level_ctx_state_0 <= cabac_init_state(0, 58, 26);
                                    cabac_res_chroma_ac_cr_level_ctx_state_1 <= cabac_init_state(-13, 106, 26);
                                    cabac_start <= 1'b1;
                                end
                                cmd_done <= 1'b1;
                                busy     <= 1'b0;
                                state    <= S_IDLE;
                            end
                            6'd8: begin
                                bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits};
                                ue_input <= {6'd0, chroma_log2_weight_denom};
                                sub <= 6'd9;
                            end
                            6'd9: begin
                                bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits};
                                sub <= 6'd10;
                            end
                            6'd10: begin
                                bit_buf <= bit_buf | (({luma_weight_non_default, 95'd0}) >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + 7'd1;
                                if (luma_weight_non_default) begin
                                    se_input <= luma_weight;
                                    sub <= 6'd11;
                                end else begin
                                    sub <= 6'd13;
                                end
                            end
                            6'd11: begin
                                bit_buf <= bit_buf | ({se_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, se_total_bits};
                                se_input <= luma_offset;
                                sub <= 6'd12;
                            end
                            6'd12: begin
                                bit_buf <= bit_buf | ({se_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, se_total_bits};
                                sub <= 6'd13;
                            end
                            6'd13: begin
                                state <= S_EMIT;
                                return_state <= S_SLICE;
                                sub <= 6'd14;
                            end
                            6'd14: begin
                                bit_buf <= bit_buf | (({chroma_weight_non_default, 95'd0}) >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + 7'd1;
                                if (chroma_weight_non_default) begin
                                    se_input <= chroma_weight_cb;
                                    sub <= 6'd15;
                                end else begin
                                    sub <= 6'd19;
                                end
                            end
                            6'd15: begin
                                bit_buf <= bit_buf | ({se_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, se_total_bits};
                                se_input <= chroma_offset_cb;
                                sub <= 6'd16;
                            end
                            6'd16: begin
                                bit_buf <= bit_buf | ({se_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, se_total_bits};
                                se_input <= chroma_weight_cr;
                                sub <= 6'd17;
                            end
                            6'd17: begin
                                bit_buf <= bit_buf | ({se_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, se_total_bits};
                                se_input <= chroma_offset_cr;
                                sub <= 6'd18;
                            end
                            6'd18: begin
                                bit_buf <= bit_buf | ({se_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, se_total_bits};
                                sub <= 6'd19;
                            end
                            6'd19: begin
                                if (is_b_slice) begin
                                    bit_buf <= bit_buf | (({luma_weight_non_default, 95'd0}) >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + 7'd1;
                                    if (luma_weight_non_default) begin
                                        se_input <= luma_weight;
                                        sub <= 6'd20;
                                    end else begin
                                        sub <= 6'd22;
                                    end
                                end else begin
                                    // adaptive_ref_pic_marking_mode_flag=0, slice_qp_delta=SE(0)='1',
                                    // disable_deblocking_filter_idc=UE(1)='010'
                                    bit_buf <= bit_buf | ({5'b01010, 91'd0} >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + 7'd5;
                                    sub <= 6'd6;
                                end
                            end
                            6'd20: begin
                                bit_buf <= bit_buf | ({se_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, se_total_bits};
                                se_input <= luma_offset;
                                sub <= 6'd21;
                            end
                            6'd21: begin
                                bit_buf <= bit_buf | ({se_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, se_total_bits};
                                sub <= 6'd22;
                            end
                            6'd22: begin
                                state <= S_EMIT;
                                return_state <= S_SLICE;
                                sub <= 6'd23;
                            end
                            6'd23: begin
                                bit_buf <= bit_buf | (({chroma_weight_non_default, 95'd0}) >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + 7'd1;
                                if (chroma_weight_non_default) begin
                                    se_input <= chroma_weight_cb;
                                    sub <= 6'd24;
                                end else begin
                                    sub <= 6'd28;
                                end
                            end
                            6'd24: begin
                                bit_buf <= bit_buf | ({se_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, se_total_bits};
                                se_input <= chroma_offset_cb;
                                sub <= 6'd25;
                            end
                            6'd25: begin
                                bit_buf <= bit_buf | ({se_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, se_total_bits};
                                se_input <= chroma_weight_cr;
                                sub <= 6'd26;
                            end
                            6'd26: begin
                                bit_buf <= bit_buf | ({se_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, se_total_bits};
                                se_input <= chroma_offset_cr;
                                sub <= 6'd27;
                            end
                            6'd27: begin
                                bit_buf <= bit_buf | ({se_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, se_total_bits};
                                sub <= 6'd28;
                            end
                            6'd28: begin
                                if (is_b_ref_slice) begin
                                    bit_buf <= bit_buf | ({5'b01010, 91'd0} >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + 7'd5;
                                end else begin
                                    bit_buf <= bit_buf | ({4'b1010, 92'd0} >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + 7'd4;
                                end
                                sub <= 6'd6;
                            end
                            6'd30: begin
                                if (bit_cnt[2:0] != 3'd0) begin
                                    bit_buf <= bit_buf | ({1'b1, 95'd0} >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + 7'd1;
                                end else begin
                                    sub <= 6'd6;
                                end
                            end
                            default: state <= S_IDLE;
                        endcase
                    end

                    S_MB_HDR: begin
                        case (sub)
                            6'd0: begin
                                if (cabac_slice_active) begin
                                    if (!is_skip_mb &&
                                        !(is_inter_mb && !is_b_slice &&
                                          (p_partition_mode == 2'd0) &&
                                          (slice_num_ref_idx_l0_active_minus1 == 2'd0) &&
                                          (mb_ref_idx_l0 == 2'd0) &&
                                          (mvd_x_l0 == 9'sd0) && (mvd_y_l0 == 9'sd0) &&
                                          (!mb_has_residual || ((cabac_cbp_luma != 4'd0) || (cabac_cbp_chroma != 2'd0))))) begin
                                        `ifndef SYNTHESIS
                                        $fatal(1,
                                               "[CABAC_PSUBSET] Unsupported CABAC MB inter=%0d skip=%0d residual=%0d cbp_luma=%0d cbp_chroma=%0d ref=%0d mvd=(%0d,%0d) refs=%0d",
                                               is_inter_mb, is_skip_mb, mb_has_residual, mb_ref_idx_l0,
                                               cabac_cbp_luma, cabac_cbp_chroma,
                                               $signed(mvd_x_l0), $signed(mvd_y_l0),
                                               slice_num_ref_idx_l0_active_minus1 + 2'd1);
                                        `endif
                                    end else if (cabac_mb_counter != 12'd0) begin
                                        cabac_bin_valid <= 1'b1;
                                        cabac_bin_value <= 1'b0;
                                        cabac_bin_bypass <= 1'b0;
                                        cabac_bin_terminate <= 1'b1;
                                        cabac_ctx_state_in <= 7'd0;
                                        sub <= 6'd32;
                                    end else begin
                                        case (cabac_skip_ctx)
                                            2'd0: cabac_ctx_state_in <= cabac_skip_ctx_state_0;
                                            2'd1: cabac_ctx_state_in <= cabac_skip_ctx_state_1;
                                            default: cabac_ctx_state_in <= cabac_skip_ctx_state_2;
                                        endcase
                                        cabac_pending_skip_ctx_idx <= cabac_skip_ctx;
                                        cabac_pending_ctx_kind <= CABAC_CTX_SKIP;
                                        cabac_pending_ctx_sel <= cabac_skip_ctx;
                                        cabac_bin_valid <= 1'b1;
                                        cabac_bin_value <= is_skip_mb;
                                        cabac_bin_bypass <= 1'b0;
                                        cabac_bin_terminate <= 1'b0;
                                        sub <= 6'd33;
                                    end
                                end else if (slice_has_skip_run && is_skip_mb) begin
                                    pending_skip_run <= pending_skip_run + 13'd1;
                                    cmd_done <= 1'b1;
                                    busy     <= 1'b0;
                                    state    <= S_IDLE;
                                end else if (slice_has_skip_run && pending_skip_run != 13'd0) begin
                                    bit_buf <= bit_buf | ({ue_big_bits, 71'd0} >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + {1'b0, ue_big_total_bits};
                                    pending_skip_run <= 13'd0;
                                    sub <= 6'd24;
                                end else if (slice_has_skip_run) begin
                                    bit_buf <= bit_buf | ({1'b1, 95'd0} >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + 7'd1;
                                    sub <= 6'd24;
                                end else begin
                                    sub <= 6'd24;
                                end
                            end
                            6'd24: begin
                                if (is_inter_mb) begin
                                    if (is_b_slice) begin
                                        // Current B inter path supports B_DIRECT_16x16 plus
                                        // 16x16 single-list and bidirectional coding:
                                        // B_DIRECT_16x16 -> codeNum 0
                                        // B_L0_16x16 -> codeNum 1
                                        // B_L1_16x16 -> codeNum 2
                                        // B_BI_16x16 -> codeNum 3
                                        if (is_b_direct_mb) begin
                                            bit_buf <= bit_buf | ({1'b1, 95'd0} >> bit_cnt[6:0]);
                                            bit_cnt <= bit_cnt + 7'd1;
                                            sub <= 6'd15;
                                        end else begin
                                            ue_input <= is_b_bi_mb ? 9'd3 : (is_b_l1_mb ? 9'd2 : 9'd1);
                                            sub <= 6'd22;
                                        end
                                    end else begin
                                        // P inter mb_type: P_L0_16x16=0, P_L0_L0_16x8=1, P_L0_L0_8x16=2, P_8x8=3.
                                        if (p_partition_mode == 2'd1) begin
                                            ue_input <= 10'd1;
                                            sub <= 6'd22;
                                        end else if (p_partition_mode == 2'd2) begin
                                            ue_input <= 10'd2;
                                            sub <= 6'd22;
                                        end else if (p_partition_mode == 2'd3) begin
                                            ue_input <= 10'd3;
                                            sub <= 6'd22;
                                        end else begin
                                            bit_buf <= bit_buf | ({1'b1, 95'd0} >> bit_cnt[6:0]);
                                            bit_cnt <= bit_cnt + 7'd1;
                                            sub <= 6'd10;  // jump to inter path
                                        end
                                    end
                                end else begin
                                    ue_input <= {4'd0, intra_mb_type_code_num};
                                    sub <= is_p_slice ? 6'd20 : 6'd21;
                                end
                            end
                            6'd1: begin
                                if (!is_inter_mb && !is_intra16_mb && intra_pred_count != 7'd0) begin
                                    bit_buf <= bit_buf | ({intra_pred_bits, 32'd0} >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + intra_pred_count;
                                end
                                sub <= 6'd2;
                            end
                            6'd2: begin
                                if (!is_inter_mb) begin
                                    if (is_intra16_mb) begin
                                        bit_buf <= bit_buf | ({2'b11, 94'd0} >> bit_cnt[6:0]);
                                        bit_cnt <= bit_cnt + 7'd2;
                                    end else if (mb_has_residual) begin
                                        if (CHROMA_FORMAT_IDC == 3) begin
                                            // High 4:4:4 Predictive uses luma-style plane residuals here,
                                            // so this path emits coded_block_pattern=UE(0) and qp_delta=SE(0)
                                            // without the 4:2:0/4:2:2 intra_chroma_pred_mode syntax element.
                                            bit_buf <= bit_buf | ({2'b11, 94'd0} >> bit_cnt[6:0]);
                                            bit_cnt <= bit_cnt + 7'd2;
                                        end else begin
                                            // intra_chroma_pred_mode=UE(0)='1', coded_block_pattern=UE(0)='1', qp_delta=SE(0)='1'
                                            bit_buf <= bit_buf | ({3'b111, 93'd0} >> bit_cnt[6:0]);
                                            bit_cnt <= bit_cnt + 7'd3;
                                        end
                                    end else begin
                                        bit_buf <= bit_buf | ({2'b11, 94'd0} >> bit_cnt[6:0]);
                                        bit_cnt <= bit_cnt + 7'd2;
                                    end
                                end
                                sub <= 6'd3;
                            end
                            6'd3: begin
                                state <= S_EMIT;
                                return_state <= S_MB_HDR;
                                sub <= 6'd4;
                            end
                            6'd4: begin
                                cmd_done <= 1'b1;
                                busy     <= 1'b0;
                                state    <= S_IDLE;
                            end
                            6'd32: begin
                                if (DEBUG_CABAC_P16X16 && !is_skip_mb)
                                    $display("[CABACDBG] mb=%0d sub=32 terminate0", cabac_mb_counter);
                                if (cabac_bits_overflow) begin
                                    `ifndef SYNTHESIS
                                    $fatal(1, "[CABAC_PSUBSET] CABAC terminate(0) bit overflow");
                                    `endif
                                    end
                                if (cabac_bits_valid) begin
                                    cabac_debug_header_bits();
                                    bit_buf <= bit_buf | ((cabac_bits_out[127:32]) >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + {1'b0, cabac_bits_count[6:0]};
                                    state <= S_EMIT;
                                    return_state <= S_MB_HDR;
                                end
                                sub <= 6'd33;
                            end
                            6'd33: begin
                                if (DEBUG_CABAC_P16X16 && !is_skip_mb)
                                    $display("[CABACDBG] mb=%0d sub=33 skip ctx=%0d state=%0d bin=%0d",
                                             cabac_mb_counter, cabac_skip_ctx, cabac_ctx_state_in, is_skip_mb);
                                case (cabac_skip_ctx)
                                    2'd0: cabac_ctx_state_in <= cabac_skip_ctx_state_0;
                                    2'd1: cabac_ctx_state_in <= cabac_skip_ctx_state_1;
                                    default: cabac_ctx_state_in <= cabac_skip_ctx_state_2;
                                endcase
                                cabac_pending_skip_ctx_idx <= cabac_skip_ctx;
                                cabac_bin_valid <= 1'b1;
                                cabac_bin_value <= is_skip_mb;
                                cabac_bin_bypass <= 1'b0;
                                cabac_bin_terminate <= 1'b0;
                                sub <= 6'd34;
                            end
                            6'd34: begin
                                if (DEBUG_CABAC_P16X16 && !is_skip_mb)
                                    $display("[CABACDBG] mb=%0d sub=34 skip outstate=%0d bits_valid=%0d bits_count=%0d",
                                             cabac_mb_counter, cabac_ctx_state_out, cabac_bits_valid, cabac_bits_count);
                                if (cabac_bits_overflow) begin
                                    `ifndef SYNTHESIS
                                    $fatal(1, "[CABAC_PSUBSET] CABAC skip-flag bit overflow");
                                    `endif
                                    end
                                if (cabac_bits_valid) begin
                                    cabac_debug_header_bits();
                                    bit_buf <= bit_buf | ((cabac_bits_out[127:32]) >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + {1'b0, cabac_bits_count[6:0]};
                                    state <= S_EMIT;
                                    return_state <= S_MB_HDR;
                                end
                                if (is_skip_mb) begin
                                    cabac_mb_counter <= cabac_mb_counter + 12'd1;
                                    sub <= 6'd35;
                                end else begin
                                    cabac_ctx_state_in <= cabac_mb_type_ctx_state_14;
                                    cabac_pending_ctx_kind <= CABAC_CTX_MBTYPE14;
                                    cabac_pending_ctx_sel <= 2'd0;
                                    cabac_bin_valid <= 1'b1;
                                    cabac_bin_value <= 1'b0;
                                    cabac_bin_bypass <= 1'b0;
                                    cabac_bin_terminate <= 1'b0;
                                    sub <= 6'd36;
                                end
                            end
                            6'd35: begin
                                cmd_done <= 1'b1;
                                busy     <= 1'b0;
                                state    <= S_IDLE;
                            end
                            6'd36: begin
                                if (DEBUG_CABAC_P16X16)
                                    $display("[CABACDBG] mb=%0d sub=36 mbtype14 state=%0d", cabac_mb_counter, cabac_mb_type_ctx_state_14);
                                if (cabac_bits_overflow) begin
                                    `ifndef SYNTHESIS
                                    $fatal(1, "[CABAC_PSUBSET] CABAC mb_type[14] bit overflow");
                                    `endif
                                    end
                                if (cabac_bits_valid) begin
                                    cabac_debug_header_bits();
                                    bit_buf <= bit_buf | ((cabac_bits_out[127:32]) >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + {1'b0, cabac_bits_count[6:0]};
                                    state <= S_EMIT;
                                    return_state <= S_MB_HDR;
                                end
                                cabac_ctx_state_in <= cabac_mb_type_ctx_state_15;
                                cabac_pending_ctx_kind <= CABAC_CTX_MBTYPE15;
                                cabac_pending_ctx_sel <= 2'd0;
                                cabac_bin_valid <= 1'b1;
                                cabac_bin_value <= 1'b0;
                                cabac_bin_bypass <= 1'b0;
                                cabac_bin_terminate <= 1'b0;
                                sub <= 6'd37;
                            end
                            6'd37: begin
                                if (DEBUG_CABAC_P16X16)
                                    $display("[CABACDBG] mb=%0d sub=37 mbtype15 state=%0d", cabac_mb_counter, cabac_mb_type_ctx_state_15);
                                if (cabac_bits_overflow) begin
                                    `ifndef SYNTHESIS
                                    $fatal(1, "[CABAC_PSUBSET] CABAC mb_type[15] bit overflow");
                                    `endif
                                    end
                                if (cabac_bits_valid) begin
                                    cabac_debug_header_bits();
                                    bit_buf <= bit_buf | ((cabac_bits_out[127:32]) >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + {1'b0, cabac_bits_count[6:0]};
                                    state <= S_EMIT;
                                    return_state <= S_MB_HDR;
                                end
                                cabac_ctx_state_in <= cabac_mb_type_ctx_state_16;
                                cabac_pending_ctx_kind <= CABAC_CTX_MBTYPE16;
                                cabac_pending_ctx_sel <= 2'd0;
                                cabac_bin_valid <= 1'b1;
                                cabac_bin_value <= 1'b0;
                                cabac_bin_bypass <= 1'b0;
                                cabac_bin_terminate <= 1'b0;
                                sub <= 6'd38;
                            end
                            6'd38: begin
                                if (DEBUG_CABAC_P16X16)
                                    $display("[CABACDBG] mb=%0d sub=38 mbtype16 state=%0d", cabac_mb_counter, cabac_mb_type_ctx_state_16);
                                if (cabac_bits_overflow) begin
                                    `ifndef SYNTHESIS
                                    $fatal(1, "[CABAC_PSUBSET] CABAC mb_type[16] bit overflow");
                                    `endif
                                    end
                                if (cabac_bits_valid) begin
                                    cabac_debug_header_bits();
                                    bit_buf <= bit_buf | ((cabac_bits_out[127:32]) >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + {1'b0, cabac_bits_count[6:0]};
                                    state <= S_EMIT;
                                    return_state <= S_MB_HDR;
                                end
                                case (cabac_mvd_ctx_x)
                                    2'd0: cabac_ctx_state_in <= cabac_mvdx_ctx_state_0;
                                    2'd1: cabac_ctx_state_in <= cabac_mvdx_ctx_state_1;
                                    default: cabac_ctx_state_in <= cabac_mvdx_ctx_state_2;
                                endcase
                                cabac_pending_ctx_kind <= CABAC_CTX_MVDX;
                                cabac_pending_ctx_sel <= cabac_mvd_ctx_x;
                                cabac_bin_valid <= 1'b1;
                                cabac_bin_value <= 1'b0;
                                cabac_bin_bypass <= 1'b0;
                                cabac_bin_terminate <= 1'b0;
                                sub <= 6'd39;
                            end
                            6'd39: begin
                                if (DEBUG_CABAC_P16X16)
                                    $display("[CABACDBG] mb=%0d sub=39 mvdx ctx=%0d state=%0d",
                                             cabac_mb_counter, cabac_mvd_ctx_x, cabac_ctx_state_in);
                                if (cabac_bits_overflow) begin
                                    `ifndef SYNTHESIS
                                    $fatal(1, "[CABAC_PSUBSET] CABAC mvd_x bit overflow");
                                    `endif
                                    end
                                if (cabac_bits_valid) begin
                                    cabac_debug_header_bits();
                                    bit_buf <= bit_buf | ((cabac_bits_out[127:32]) >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + {1'b0, cabac_bits_count[6:0]};
                                    state <= S_EMIT;
                                    return_state <= S_MB_HDR;
                                end
                                case (cabac_mvd_ctx_y)
                                    2'd0: cabac_ctx_state_in <= cabac_mvdy_ctx_state_0;
                                    2'd1: cabac_ctx_state_in <= cabac_mvdy_ctx_state_1;
                                    default: cabac_ctx_state_in <= cabac_mvdy_ctx_state_2;
                                endcase
                                cabac_pending_ctx_kind <= CABAC_CTX_MVDY;
                                cabac_pending_ctx_sel <= cabac_mvd_ctx_y;
                                cabac_bin_valid <= 1'b1;
                                cabac_bin_value <= 1'b0;
                                cabac_bin_bypass <= 1'b0;
                                cabac_bin_terminate <= 1'b0;
                                sub <= 6'd40;
                            end
                            6'd40: begin
                                if (DEBUG_CABAC_P16X16)
                                    $display("[CABACDBG] mb=%0d sub=40 mvdy ctx=%0d state=%0d",
                                             cabac_mb_counter, cabac_mvd_ctx_y, cabac_ctx_state_in);
                                if (cabac_bits_overflow) begin
                                    `ifndef SYNTHESIS
                                    $fatal(1, "[CABAC_PSUBSET] CABAC mvd_y bit overflow");
                                    `endif
                                    end
                                if (cabac_bits_valid) begin
                                    cabac_debug_header_bits();
                                    bit_buf <= bit_buf | ((cabac_bits_out[127:32]) >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + {1'b0, cabac_bits_count[6:0]};
                                    state <= S_EMIT;
                                    return_state <= S_MB_HDR;
                                end
                                case (cabac_cbp_luma_ctx0_sel)
                                    2'd0: cabac_ctx_state_in <= cabac_cbp_luma_ctx_state_76;
                                    2'd1: cabac_ctx_state_in <= cabac_cbp_luma_ctx_state_75;
                                    2'd2: cabac_ctx_state_in <= cabac_cbp_luma_ctx_state_74;
                                    default: cabac_ctx_state_in <= cabac_cbp_luma_ctx_state_73;
                                endcase
                                cabac_pending_ctx_kind <= CABAC_CTX_CBP0;
                                cabac_pending_ctx_sel <= cabac_cbp_luma_ctx0_sel;
                                cabac_bin_valid <= 1'b1;
                                cabac_bin_value <= cabac_cbp_luma[0];
                                cabac_bin_bypass <= 1'b0;
                                cabac_bin_terminate <= 1'b0;
                                sub <= 6'd41;
                            end
                            6'd41: begin
                                if (DEBUG_CABAC_P16X16)
                                    $display("[CABACDBG] mb=%0d sub=41 cbp0 sel=%0d state=%0d",
                                             cabac_mb_counter, cabac_cbp_luma_ctx0_sel, cabac_ctx_state_in);
                                if (cabac_bits_overflow) begin
                                    `ifndef SYNTHESIS
                                    $fatal(1, "[CABAC_PSUBSET] CABAC cbp_luma[0] bit overflow");
                                    `endif
                                    end
                                if (cabac_bits_valid) begin
                                    cabac_debug_header_bits();
                                    bit_buf <= bit_buf | ((cabac_bits_out[127:32]) >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + {1'b0, cabac_bits_count[6:0]};
                                    state <= S_EMIT;
                                    return_state <= S_MB_HDR;
                                end
                                case (cabac_cbp_luma_ctx1_sel)
                                    2'd0: cabac_ctx_state_in <= (cabac_ctx_state_wr && (cabac_cbp_luma_ctx0_sel == 2'd0)) ? cabac_ctx_state_out : cabac_cbp_luma_ctx_state_76;
                                    2'd1: cabac_ctx_state_in <= (cabac_ctx_state_wr && (cabac_cbp_luma_ctx0_sel == 2'd1)) ? cabac_ctx_state_out : cabac_cbp_luma_ctx_state_75;
                                    2'd2: cabac_ctx_state_in <= (cabac_ctx_state_wr && (cabac_cbp_luma_ctx0_sel == 2'd2)) ? cabac_ctx_state_out : cabac_cbp_luma_ctx_state_74;
                                    default: cabac_ctx_state_in <= (cabac_ctx_state_wr && (cabac_cbp_luma_ctx0_sel == 2'd3)) ? cabac_ctx_state_out : cabac_cbp_luma_ctx_state_73;
                                endcase
                                cabac_pending_ctx_kind <= CABAC_CTX_CBP1;
                                cabac_pending_ctx_sel <= cabac_cbp_luma_ctx1_sel;
                                cabac_bin_valid <= 1'b1;
                                cabac_bin_value <= cabac_cbp_luma[1];
                                cabac_bin_bypass <= 1'b0;
                                cabac_bin_terminate <= 1'b0;
                                sub <= 6'd42;
                            end
                            6'd42: begin
                                if (DEBUG_CABAC_P16X16)
                                    $display("[CABACDBG] mb=%0d sub=42 cbp1 sel=%0d state=%0d",
                                             cabac_mb_counter, cabac_cbp_luma_ctx1_sel, cabac_ctx_state_in);
                                if (cabac_bits_overflow) begin
                                    `ifndef SYNTHESIS
                                    $fatal(1, "[CABAC_PSUBSET] CABAC cbp_luma[1] bit overflow");
                                    `endif
                                    end
                                if (cabac_bits_valid) begin
                                    cabac_debug_header_bits();
                                    bit_buf <= bit_buf | ((cabac_bits_out[127:32]) >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + {1'b0, cabac_bits_count[6:0]};
                                    state <= S_EMIT;
                                    return_state <= S_MB_HDR;
                                end
                                case (cabac_cbp_luma_ctx2_sel)
                                    2'd0: cabac_ctx_state_in <= (cabac_ctx_state_wr && (cabac_cbp_luma_ctx1_sel == 2'd0)) ? cabac_ctx_state_out : cabac_cbp_luma_ctx_state_76;
                                    2'd1: cabac_ctx_state_in <= (cabac_ctx_state_wr && (cabac_cbp_luma_ctx1_sel == 2'd1)) ? cabac_ctx_state_out : cabac_cbp_luma_ctx_state_75;
                                    2'd2: cabac_ctx_state_in <= (cabac_ctx_state_wr && (cabac_cbp_luma_ctx1_sel == 2'd2)) ? cabac_ctx_state_out : cabac_cbp_luma_ctx_state_74;
                                    default: cabac_ctx_state_in <= (cabac_ctx_state_wr && (cabac_cbp_luma_ctx1_sel == 2'd3)) ? cabac_ctx_state_out : cabac_cbp_luma_ctx_state_73;
                                endcase
                                cabac_pending_ctx_kind <= CABAC_CTX_CBP2;
                                cabac_pending_ctx_sel <= cabac_cbp_luma_ctx2_sel;
                                cabac_bin_valid <= 1'b1;
                                cabac_bin_value <= cabac_cbp_luma[2];
                                cabac_bin_bypass <= 1'b0;
                                cabac_bin_terminate <= 1'b0;
                                sub <= 6'd43;
                            end
                            6'd43: begin
                                if (DEBUG_CABAC_P16X16)
                                    $display("[CABACDBG] mb=%0d sub=43 cbp2 sel=%0d state=%0d",
                                             cabac_mb_counter, cabac_cbp_luma_ctx2_sel, cabac_ctx_state_in);
                                if (cabac_bits_overflow) begin
                                    `ifndef SYNTHESIS
                                    $fatal(1, "[CABAC_PSUBSET] CABAC cbp_luma[2] bit overflow");
                                    `endif
                                    end
                                if (cabac_bits_valid) begin
                                    cabac_debug_header_bits();
                                    bit_buf <= bit_buf | ((cabac_bits_out[127:32]) >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + {1'b0, cabac_bits_count[6:0]};
                                    state <= S_EMIT;
                                    return_state <= S_MB_HDR;
                                end
                                cabac_ctx_state_in <= (cabac_ctx_state_wr && (cabac_cbp_luma_ctx2_sel == 2'd0)) ? cabac_ctx_state_out : cabac_cbp_luma_ctx_state_76;
                                cabac_pending_ctx_kind <= CABAC_CTX_CBP3;
                                cabac_pending_ctx_sel <= 2'd0;
                                cabac_bin_valid <= 1'b1;
                                cabac_bin_value <= cabac_cbp_luma[3];
                                cabac_bin_bypass <= 1'b0;
                                cabac_bin_terminate <= 1'b0;
                                sub <= 6'd44;
                            end
                            6'd44: begin
                                if (DEBUG_CABAC_P16X16)
                                    $display("[CABACDBG] mb=%0d sub=44 cbp3 state=%0d",
                                             cabac_mb_counter, cabac_ctx_state_in);
                                if (cabac_bits_overflow) begin
                                    `ifndef SYNTHESIS
                                    $fatal(1, "[CABAC_PSUBSET] CABAC cbp_luma[3] bit overflow");
                                    `endif
                                    end
                                if (cabac_bits_valid) begin
                                    cabac_debug_header_bits();
                                    bit_buf <= bit_buf | ((cabac_bits_out[127:32]) >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + {1'b0, cabac_bits_count[6:0]};
                                    state <= S_EMIT;
                                    return_state <= S_MB_HDR;
                                end
                                cabac_ctx_state_in <= cabac_cbp_chroma_ctx_state[0];
                                cabac_pending_ctx_kind <= CABAC_CTX_CBPCHROMA;
                                cabac_pending_ctx_sel <= 2'd0;
                                cabac_bin_valid <= 1'b1;
                                // CABAC coded_block_pattern chroma bin 0 carries the
                                // nonzero-chroma predicate. The integrated chroma
                                // residual lane is still top-level guarded, but keep
                                // the dormant writer path from collapsing cbp_chroma=1/2
                                // to the old zero-CBP-only encoding.
                                cabac_bin_value <= (cabac_cbp_chroma != 2'd0);
                                cabac_bin_bypass <= 1'b0;
                                cabac_bin_terminate <= 1'b0;
                                sub <= 6'd45;
                            end
                            6'd45: begin
                                if (DEBUG_CABAC_P16X16)
                                    $display("[CABACDBG] mb=%0d sub=45 cbpchroma state=%0d",
                                             cabac_mb_counter, cabac_ctx_state_in);
                                if (cabac_bits_overflow) begin
                                    `ifndef SYNTHESIS
                                    $fatal(1, "[CABAC_PSUBSET] CABAC cbp_chroma bit overflow");
                                    `endif
                                    end
                                if (cabac_bits_valid) begin
                                    cabac_debug_header_bits();
                                    bit_buf <= bit_buf | ((cabac_bits_out[127:32]) >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + {1'b0, cabac_bits_count[6:0]};
                                    state <= S_EMIT;
                                    return_state <= S_MB_HDR;
                                end
                                if (cabac_cbp_chroma != 2'd0) begin
                                    cabac_ctx_state_in <= cabac_cbp_chroma_ctx_state[1];
                                    cabac_pending_ctx_kind <= CABAC_CTX_CBPCHROMA;
                                    cabac_pending_ctx_sel <= 4'd1;
                                    cabac_bin_valid <= 1'b1;
                                    // The second chroma coded_block_pattern bin is only
                                    // present when chroma DC is coded; it distinguishes
                                    // DC-only (cbp_chroma=1) from DC+AC (cbp_chroma=2).
                                    cabac_bin_value <= (cabac_cbp_chroma == 2'd2);
                                    cabac_bin_bypass <= 1'b0;
                                    cabac_bin_terminate <= 1'b0;
                                    sub <= 7'd64;
                                end else if (mb_has_residual && (cabac_cbp_luma != 4'd0)) begin
                                    cabac_ctx_state_in <= cabac_qp_delta_ctx_state_60;
                                    cabac_pending_ctx_kind <= CABAC_CTX_QPDELTA;
                                    cabac_pending_ctx_sel <= 2'd0;
                                    cabac_bin_valid <= 1'b1;
                                    cabac_bin_value <= 1'b0;
                                    cabac_bin_bypass <= 1'b0;
                                    cabac_bin_terminate <= 1'b0;
                                    sub <= 6'd63;
                                end else begin
                                    cabac_mb_counter <= cabac_mb_counter + 12'd1;
                                    sub <= 6'd46;
                                end

                            end
                            7'd64: begin
                                if (DEBUG_CABAC_P16X16)
                                    $display("[CABACDBG] mb=%0d sub=64 cbpchroma_ac state=%0d",
                                             cabac_mb_counter, cabac_ctx_state_in);
                                if (cabac_bits_overflow) begin
                                    `ifndef SYNTHESIS
                                    $fatal(1, "[CABAC_PSUBSET] CABAC cbp_chroma_ac bit overflow");
                                    `endif
                                    end
                                if (cabac_bits_valid) begin
                                    cabac_debug_header_bits();
                                    bit_buf <= bit_buf | ((cabac_bits_out[127:32]) >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + {1'b0, cabac_bits_count[6:0]};
                                    state <= S_EMIT;
                                    return_state <= S_MB_HDR;
                                end
                                if (mb_has_residual) begin
                                    cabac_ctx_state_in <= cabac_qp_delta_ctx_state_60;
                                    cabac_pending_ctx_kind <= CABAC_CTX_QPDELTA;
                                    cabac_pending_ctx_sel <= 2'd0;
                                    cabac_bin_valid <= 1'b1;
                                    cabac_bin_value <= 1'b0;
                                    cabac_bin_bypass <= 1'b0;
                                    cabac_bin_terminate <= 1'b0;
                                    sub <= 6'd63;
                                end else begin
                                    cabac_mb_counter <= cabac_mb_counter + 12'd1;
                                    sub <= 6'd46;
                                end
                            end
                            6'd46: begin
                                cmd_done <= 1'b1;
                                busy     <= 1'b0;
                                state    <= S_IDLE;
                            end
                            6'd63: begin
                                if (cabac_bits_overflow) begin
                                    `ifndef SYNTHESIS
                                    $fatal(1, "[CABAC_PSUBSET] CABAC qp_delta bit overflow");
                                    `endif
                                end
                                if (cabac_bits_valid) begin
                                    cabac_debug_header_bits();
                                    bit_buf <= bit_buf | ((cabac_bits_out[127:32]) >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + {1'b0, cabac_bits_count[6:0]};
                                end
                                cabac_res_block_idx <= 4'd0;
                                cabac_res_category <= (cabac_cbp_luma != 4'd0) ? CABAC_RES_CAT_LUMA : CABAC_RES_CAT_CHROMA_DC;
                                cabac_res_scan_done_pending <= 1'b0;
                                cabac_res_scan_start <= 1'b1;
                                state <= S_CABAC_RES;
                                sub <= 6'd0;
                            end
                            6'd20: begin
                                bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits};
                                sub <= is_ipcm_mb ? 6'd25 : 6'd1;
                            end
                            6'd21: begin
                                bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits};
                                sub <= is_ipcm_mb ? 6'd25 : 6'd1;
                            end
                            6'd22: begin
                                bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits};
                                if (!is_b_slice && (p_partition_mode == 2'd3)) begin
                                    p8x8_sub_idx <= 3'd0;
                                    ue_input <= {8'd0, p_sub_mb_type};
                                    sub <= 6'd52;
                                end else begin
                                    sub <= 6'd10;
                                end
                            end

                            // ===== Inter MB path (sub 10+) =====
                            // After the inter mb_type, P-slices may need ref_idx_l0 before the
                            // motion-vector-difference syntax. The current limited B-slice path
                            // now also emits ref_idx_l0 for B_L0_16x16 / B_BI_16x16 when more than
                            // one List0 reference is active.
                            // For exactly two active refs, ref_idx_l0 uses TE(v) with x=1,
                            // which is a single bit encoded as (1 ^ ref_idx).
                            // For three active refs, TE(v) falls back to UE(v) of ref_idx.
                            6'd10: begin
                                if (is_b_slice) begin
                                    if (!is_b_direct_mb && !is_b_l1_mb && slice_multi_ref_enable) begin
                                        if (slice_num_ref_idx_l0_active_minus1 == 2'd1) begin
                                            bit_buf <= bit_buf | ({(~mb_ref_idx_l0[0]), 95'd0} >> bit_cnt[6:0]);
                                            bit_cnt <= bit_cnt + 7'd1;
                                            sub <= 6'd11;
                                        end else begin
                                            ue_input <= {8'd0, mb_ref_idx_l0};
                                            sub <= 6'd23;
                                        end
                                    end else begin
                                        ue_input <= is_b_l1_mb ? mvd_x_l1_codenum_w : mvd_x_l0_codenum_w;
                                        sub <= 6'd12;
                                    end
                                end else if (slice_multi_ref_enable) begin
                                    if (slice_num_ref_idx_l0_active_minus1 == 2'd1) begin
                                        bit_buf <= bit_buf | ({(~mb_ref_idx_l0[0]), 95'd0} >> bit_cnt[6:0]);
                                        bit_cnt <= bit_cnt + 7'd1;
                                        sub <= (p_partition_mode != 2'd0) ? 6'd47 : 6'd11;
                                    end else begin
                                        ue_input <= {8'd0, mb_ref_idx_l0};
                                        sub <= 6'd23;
                                    end
                                end else begin
                                    sub <= 6'd11;
                                end
                            end
                            6'd11: begin
                                ue_input <= mvd_x_l0_codenum_w;
                                sub <= 6'd12;
                            end
                            6'd12: begin
                                // MVD uses signed Exp-Golomb, but the mapped codeNum is still
                                // encoded with the same UE(v) machinery as the parameter sets.
                                bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits};
                                ue_input <= (is_b_slice && is_b_l1_mb) ? mvd_y_l1_codenum_w : mvd_y_l0_codenum_w;
                                sub <= 6'd13;
                            end
                            6'd13: begin
                                // Emit to make room
                                state <= S_EMIT;
                                return_state <= S_MB_HDR;
                                sub <= 6'd14;
                            end
                            6'd14: begin
                                bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits};
                                if (is_b_slice && is_b_bi_mb) begin
                                    ue_input <= mvd_x_l1_codenum_w;
                                    sub <= 6'd27;
                                end else if (!is_b_slice && (p_partition_mode != 2'd0)) begin
                                    ue_input <= mvd_x_l0_part1_codenum_w;
                                    sub <= 6'd49;
                                end else begin
                                    sub <= 6'd15;
                                end
                            end
                            6'd15: begin
                                // Inter coded_block_pattern:
                                //   4:2:0 / 4:2:2 current path emits the full-residual case
                                //   CBP=47 -> codeNum=12 -> UE(12)='0001101'
                                //   4:4:4 uses the ChromaArrayType 3 table, where the matching
                                //   "all four 8x8 groups present" case is CBP=15 -> codeNum=9
                                //   -> UE(9)='0001010'. CBP=0 stays UE(0)='1' for every format.
                                if (mb_has_residual) begin
                                    if (CHROMA_FORMAT_IDC == 3) begin
                                        bit_buf <= bit_buf | ({7'b0001010, 89'd0} >> bit_cnt[6:0]);
                                        bit_cnt <= bit_cnt + 7'd7;
                                    end else begin
                                        bit_buf <= bit_buf | ({7'b0001101, 89'd0} >> bit_cnt[6:0]);
                                        bit_cnt <= bit_cnt + 7'd7;
                                    end
                                end else begin
                                    bit_buf <= bit_buf | ({1'b1, 95'd0} >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + 7'd1;
                                end
                                sub <= 6'd16;
                            end
                            6'd16: begin
                                if (transform_8x8_mode_enable && transform_size_8x8_flag) begin
                                    bit_buf <= bit_buf | ({transform_size_8x8_flag, 95'd0} >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + 7'd1;
                                end
                                if (mb_has_residual) begin
                                    se_input <= mb_qp_delta;
                                    sub <= 6'd17;
                                end else begin
                                    sub <= 6'd18;
                                end
                            end
                            6'd17: begin
                                bit_buf <= bit_buf | ({se_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, se_total_bits};
                                sub <= 6'd18;
                            end
                            6'd18: begin
                                cmd_done <= 1'b1;
                                busy     <= 1'b0;
                                state    <= S_IDLE;
                            end
                            6'd23: begin
                                bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits};
                                if (is_b_slice) begin
                                    ue_input <= is_b_l1_mb ? mvd_x_l1_codenum_w : mvd_x_l0_codenum_w;
                                    sub <= 6'd12;
                                end else if ((p_partition_mode != 2'd0) && slice_multi_ref_enable) begin
                                    ue_input <= {8'd0, mb_ref_idx_l0_part1};
                                    sub <= 6'd48;
                                end else begin
                                    sub <= 6'd11;
                                end
                            end
                            6'd47: begin
                                bit_buf <= bit_buf | ({(~mb_ref_idx_l0_part1[0]), 95'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + 7'd1;
                                sub <= 6'd11;
                            end
                            6'd48: begin
                                bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits};
                                sub <= 6'd11;
                            end
                            6'd49: begin
                                bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits};
                                ue_input <= mvd_y_l0_part1_codenum_w;
                                sub <= 6'd50;
                            end
                            6'd50: begin
                                state <= S_EMIT;
                                return_state <= S_MB_HDR;
                                sub <= 6'd51;
                            end
                            6'd51: begin
                                bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits};
                                sub <= 6'd15;
                            end
                            6'd27: begin
                                bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits};
                                ue_input <= mvd_y_l1_codenum_w;
                                sub <= 6'd28;
                            end
                            6'd28: begin
                                state <= S_EMIT;
                                return_state <= S_MB_HDR;
                                sub <= 6'd29;
                            end
                            6'd29: begin
                                bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits};
                                sub <= 6'd15;
                            end
                            // P_8x8 / sub-macroblock syntax. This CAVLC path forces all four
                            // sub-macroblocks to the same sub_mb_type/ref. The datapath currently
                            // uses one uniform luma/chroma predictor for the whole MB; to keep the
                            // decoder's per-partition MVs equal to that predictor, emit the external
                            // MVP delta on the first subpartition and zero MVDs for internal
                            // subpartitions whose MVP is the previous same-MV neighbor.
                            6'd52: begin
                                bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits};
                                if (p8x8_sub_idx == 3'd3) begin
                                    if (slice_multi_ref_enable) begin
                                        p8x8_sub_idx <= 3'd0;
                                        ue_input <= {8'd0, mb_ref_idx_l0};
                                        sub <= 6'd54;
                                    end else begin
                                        p8x8_mvd_idx <= 5'd0;
                                        ue_input <= mvd_x_l0_codenum_w;
                                        sub <= 6'd58;
                                    end
                                end else begin
                                    p8x8_sub_idx <= p8x8_sub_idx + 3'd1;
                                    ue_input <= {8'd0, p_sub_mb_type};
                                    sub <= 6'd53;
                                end
                            end
                            6'd53: begin
                                state <= S_EMIT;
                                return_state <= S_MB_HDR;
                                sub <= 6'd52;
                            end
                            6'd54: begin
                                if (slice_num_ref_idx_l0_active_minus1 == 2'd1) begin
                                    bit_buf <= bit_buf | ({(~mb_ref_idx_l0[0]), 95'd0} >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + 7'd1;
                                end else begin
                                    bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + {2'b0, ue_total_bits};
                                end
                                if (p8x8_sub_idx == 3'd3) begin
                                    p8x8_mvd_idx <= 5'd0;
                                    ue_input <= mvd_x_l0_codenum_w;
                                    sub <= 6'd58;
                                end else begin
                                    p8x8_sub_idx <= p8x8_sub_idx + 3'd1;
                                    ue_input <= {8'd0, mb_ref_idx_l0};
                                    sub <= 6'd55;
                                end
                            end
                            6'd55: begin
                                state <= S_EMIT;
                                return_state <= S_MB_HDR;
                                sub <= 6'd54;
                            end
                            6'd58: begin
                                bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits};
                                ue_input <= (p8x8_mvd_idx == 5'd0) ? mvd_y_l0_codenum_w : 10'd0;
                                sub <= 6'd59;
                            end
                            6'd59: begin
                                state <= S_EMIT;
                                return_state <= S_MB_HDR;
                                sub <= 6'd60;
                            end
                            6'd60: begin
                                bit_buf <= bit_buf | ({ue_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, ue_total_bits};
                                if (p8x8_mvd_idx == (p8x8_mvd_total_w - 5'd1)) begin
                                    sub <= 6'd62;
                                end else begin
                                    p8x8_mvd_idx <= p8x8_mvd_idx + 5'd1;
                                    ue_input <= 10'd0;
                                    sub <= 6'd61;
                                end
                            end
                            6'd61: begin
                                state <= S_EMIT;
                                return_state <= S_MB_HDR;
                                sub <= 6'd58;
                            end
                            6'd62: begin
                                state <= S_EMIT;
                                return_state <= S_MB_HDR;
                                sub <= 6'd15;
                            end
                            6'd25: begin
                                if (bit_cnt[2:0] != 3'd0)
                                    bit_cnt <= bit_cnt + {3'd0, (4'd8 - {1'b0, bit_cnt[2:0]})};
                                sub <= 6'd26;
                            end
                            6'd26: begin
                                if (bit_cnt >= 7'd8) begin
                                    state <= S_EMIT;
                                    return_state <= S_MB_HDR;
                                    sub <= 6'd26;
                                end else begin
                                    bit_buf <= 96'd0;
                                    sub <= 6'd30;
                                end
                            end
                            6'd30: begin : ipcm_emit_byte
                                reg [9:0] ipcm_idx_i;
                                reg [7:0] ipcm_byte_i;
                                reg [BIT_DEPTH-1:0] ipcm_sample_i;
                                ipcm_idx_i = ipcm_sample_idx;
                                if (ipcm_idx_i < IPCM_TOTAL_SAMPLES[9:0]) begin
                                    if (BIT_DEPTH == 8) begin
                                        if (ipcm_idx_i < 10'd256)
                                            ipcm_byte_i = ipcm_luma_flat[ipcm_idx_i*BIT_DEPTH +: 8];
                                        else if (ipcm_idx_i < (10'd256 + CHR_MB_PIXELS[9:0]))
                                            ipcm_byte_i = ipcm_cb_flat[(ipcm_idx_i - 10'd256)*BIT_DEPTH +: 8];
                                        else
                                            ipcm_byte_i = ipcm_cr_flat[(ipcm_idx_i - 10'd256 - CHR_MB_PIXELS[9:0])*BIT_DEPTH +: 8];
                                        write_byte <= ipcm_byte_i;
                                        do_write <= 1'b1;
                                        ipcm_sample_idx <= ipcm_sample_idx + 10'd1;
                                    end else begin
                                        if (ipcm_idx_i < 10'd256)
                                            ipcm_sample_i = ipcm_luma_flat[ipcm_idx_i*BIT_DEPTH +: BIT_DEPTH];
                                        else if (ipcm_idx_i < (10'd256 + CHR_MB_PIXELS[9:0]))
                                            ipcm_sample_i = ipcm_cb_flat[(ipcm_idx_i - 10'd256)*BIT_DEPTH +: BIT_DEPTH];
                                        else
                                            ipcm_sample_i = ipcm_cr_flat[(ipcm_idx_i - 10'd256 - CHR_MB_PIXELS[9:0])*BIT_DEPTH +: BIT_DEPTH];
                                        bit_buf <= bit_buf | (({ipcm_sample_i, {(96-BIT_DEPTH){1'b0}}} >> bit_cnt[6:0]));
                                        bit_cnt <= bit_cnt + BIT_DEPTH[6:0];
                                        ipcm_sample_idx <= ipcm_sample_idx + 10'd1;
                                        sub <= 6'd31;
                                    end
                                end else begin
                                    sub <= 6'd4;
                                end
                            end
                            6'd31: begin
                                if (bit_cnt >= 7'd8) begin
                                    state <= S_EMIT;
                                    return_state <= S_MB_HDR;
                                    sub <= 6'd31;
                                end else begin
                                    sub <= 6'd30;
                                end
                            end

                            default: state <= S_IDLE;
                        endcase
                    end

                    S_CABAC_RES: begin
                        if (cabac_bits_overflow) begin
                            `ifndef SYNTHESIS
                            $fatal(1, "[CABAC_PSUBSET] CABAC residual bit overflow");
                            `endif
                        end
                        if (cabac_bits_valid) begin
                            if (DEBUG_CABAC_P16X16 && (cabac_res_category != CABAC_RES_CAT_LUMA))
                                $display("[CABACBITS] mb=%0d cat=%0d blk=%0d count=%0d bits=%024x bit_cnt=%0d",
                                         cabac_mb_counter, cabac_res_category, cabac_res_block_idx,
                                         cabac_bits_count, cabac_bits_out[127:32], bit_cnt);
                            bit_buf <= bit_buf | ((cabac_bits_out[127:32]) >> bit_cnt[6:0]);
                            bit_cnt <= bit_cnt + {1'b0, cabac_bits_count[6:0]};
                        end
                        if (cabac_res_bin_valid) begin
                            if (DEBUG_CABAC_P16X16 && (cabac_res_category != CABAC_RES_CAT_LUMA))
                                $display("[CABACRES] mb=%0d cat=%0d blk=%0d ctx=%0d val=%0d bypass=%0d coeff=%0d state_in=%0d pending_kind=%0d pending_sel=%0d",
                                         cabac_mb_counter, cabac_res_category, cabac_res_block_idx,
                                         cabac_res_bin_ctx_idx, cabac_res_bin_value,
                                         cabac_res_bin_bypass, cabac_res_event_coeff_idx,
                                         cabac_ctx_state_in, cabac_pending_ctx_kind, cabac_pending_ctx_sel);
                            cabac_bin_valid <= 1'b1;
                            cabac_bin_value <= cabac_res_bin_value;
                            cabac_bin_bypass <= cabac_res_bin_bypass;
                            cabac_bin_terminate <= 1'b0;
                            cabac_pending_res_category <= cabac_res_category;
                            cabac_pending_res_block_idx <= cabac_res_block_idx;
                            if (cabac_res_category == CABAC_RES_CAT_CHROMA_DC) begin
                                case (cabac_res_bin_ctx_idx)
                                    9'd97: begin
                                        cabac_ctx_state_in <= cabac_res_chroma_dc_cbf_ctx_state[0];
                                        cabac_pending_ctx_kind <= CABAC_CTX_RES_CHRDC_CBF;
                                        cabac_pending_ctx_sel <= 4'd0;
                                    end
                                    9'd257: begin
                                        cabac_ctx_state_in <= cabac_res_chroma_dc_level_ctx_state_0;
                                        cabac_pending_ctx_kind <= CABAC_CTX_RES_CHRDC_LEVEL;
                                        cabac_pending_ctx_sel <= 4'd0;
                                    end
                                    9'd262: begin
                                        cabac_ctx_state_in <= cabac_res_chroma_dc_level_ctx_state_1;
                                        cabac_pending_ctx_kind <= CABAC_CTX_RES_CHRDC_LEVEL;
                                        cabac_pending_ctx_sel <= 4'd1;
                                    end
                                    default: begin
                                        if ((cabac_res_bin_ctx_idx >= 9'd149) && (cabac_res_bin_ctx_idx <= 9'd151)) begin
                                            cabac_ctx_state_in <= cabac_res_chroma_dc_sig_ctx_state[cabac_res_bin_ctx_idx - 9'd149];
                                            cabac_pending_ctx_kind <= CABAC_CTX_RES_CHRDC_SIG;
                                            cabac_pending_ctx_sel <= cabac_res_bin_ctx_idx - 9'd149;
                                        end else if ((cabac_res_bin_ctx_idx >= 9'd210) && (cabac_res_bin_ctx_idx <= 9'd212)) begin
                                            cabac_ctx_state_in <= cabac_res_chroma_dc_last_ctx_state[cabac_res_bin_ctx_idx - 9'd210];
                                            cabac_pending_ctx_kind <= CABAC_CTX_RES_CHRDC_LAST;
                                            cabac_pending_ctx_sel <= cabac_res_bin_ctx_idx - 9'd210;
                                        end else begin
                                            cabac_ctx_state_in <= 7'd0;
                                            cabac_pending_ctx_kind <= CABAC_CTX_NONE;
                                            cabac_pending_ctx_sel <= 4'd0;
                                        end
                                    end
                                endcase
                            end else if (cabac_res_category == CABAC_RES_CAT_CHROMA_AC) begin
                                case (cabac_res_bin_ctx_idx)
                                    9'd101: begin
                                        if (cabac_res_block_idx >= CABAC_CHROMA_AC_BLOCKS_PER_PLANE)
                                            cabac_ctx_state_in <= cabac_res_chroma_ac_cr_cbf_ctx_state[cabac_res_chroma_ac_cbf_ctx_sel_for(cabac_res_block_idx)];
                                        else
                                            cabac_ctx_state_in <= cabac_res_chroma_ac_cbf_ctx_state[cabac_res_chroma_ac_cbf_ctx_sel_for(cabac_res_block_idx)];
                                        cabac_pending_ctx_kind <= CABAC_CTX_RES_CHRAC_CBF;
                                        cabac_pending_ctx_sel <= {1'b0, (cabac_res_block_idx >= CABAC_CHROMA_AC_BLOCKS_PER_PLANE), cabac_res_chroma_ac_cbf_ctx_sel_for(cabac_res_block_idx)};
                                    end
                                    9'd266: begin
                                        cabac_ctx_state_in <= ((cabac_res_block_idx >= CABAC_CHROMA_AC_BLOCKS_PER_PLANE) && cabac_chroma_ac_split_plane_ctx()) ? cabac_res_chroma_ac_cr_level_ctx_state_0 : cabac_res_chroma_ac_level_ctx_state_0;
                                        cabac_pending_ctx_kind <= CABAC_CTX_RES_CHRAC_LEVEL;
                                        cabac_pending_ctx_sel <= {((cabac_res_block_idx >= CABAC_CHROMA_AC_BLOCKS_PER_PLANE) && cabac_chroma_ac_split_plane_ctx()), 4'd0};
                                    end
                                    9'd277: begin
                                        cabac_ctx_state_in <= ((cabac_res_block_idx >= CABAC_CHROMA_AC_BLOCKS_PER_PLANE) && cabac_chroma_ac_split_plane_ctx()) ? cabac_res_chroma_ac_cr_level_ctx_state_1 : cabac_res_chroma_ac_level_ctx_state_1;
                                        cabac_pending_ctx_kind <= CABAC_CTX_RES_CHRAC_LEVEL;
                                        cabac_pending_ctx_sel <= {((cabac_res_block_idx >= CABAC_CHROMA_AC_BLOCKS_PER_PLANE) && cabac_chroma_ac_split_plane_ctx()), 4'd1};
                                    end
                                    default: begin
                                        if ((cabac_res_bin_ctx_idx >= 9'd101) && (cabac_res_bin_ctx_idx <= 9'd104)) begin
                                            if (cabac_res_block_idx >= CABAC_CHROMA_AC_BLOCKS_PER_PLANE)
                                                cabac_ctx_state_in <= cabac_res_chroma_ac_cr_cbf_ctx_state[cabac_res_bin_ctx_idx[1:0] - 2'd1];
                                            else
                                                cabac_ctx_state_in <= cabac_res_chroma_ac_cbf_ctx_state[cabac_res_bin_ctx_idx[1:0] - 2'd1];
                                            cabac_pending_ctx_kind <= CABAC_CTX_RES_CHRAC_CBF;
                                            cabac_pending_ctx_sel <= {1'b0, (cabac_res_block_idx >= CABAC_CHROMA_AC_BLOCKS_PER_PLANE), (cabac_res_bin_ctx_idx[1:0] - 2'd1)};
                                        end else if ((cabac_res_bin_ctx_idx >= 9'd152) && (cabac_res_bin_ctx_idx <= 9'd166)) begin
                                            cabac_ctx_state_in <= ((cabac_res_block_idx >= CABAC_CHROMA_AC_BLOCKS_PER_PLANE) && cabac_chroma_ac_split_plane_ctx()) ? cabac_res_chroma_ac_cr_sig_ctx_state[cabac_res_bin_ctx_idx - 9'd152] : cabac_res_chroma_ac_sig_ctx_state[cabac_res_bin_ctx_idx - 9'd152];
                                            cabac_pending_ctx_kind <= CABAC_CTX_RES_CHRAC_SIG;
                                            cabac_pending_ctx_sel <= {((cabac_res_block_idx >= CABAC_CHROMA_AC_BLOCKS_PER_PLANE) && cabac_chroma_ac_split_plane_ctx()), (cabac_res_bin_ctx_idx - 9'd152)};
                                        end else if ((cabac_res_bin_ctx_idx >= 9'd213) && (cabac_res_bin_ctx_idx <= 9'd227)) begin
                                            cabac_ctx_state_in <= ((cabac_res_block_idx >= CABAC_CHROMA_AC_BLOCKS_PER_PLANE) && cabac_chroma_ac_split_plane_ctx()) ? cabac_res_chroma_ac_cr_last_ctx_state[cabac_res_bin_ctx_idx - 9'd213] : cabac_res_chroma_ac_last_ctx_state[cabac_res_bin_ctx_idx - 9'd213];
                                            cabac_pending_ctx_kind <= CABAC_CTX_RES_CHRAC_LAST;
                                            cabac_pending_ctx_sel <= {((cabac_res_block_idx >= CABAC_CHROMA_AC_BLOCKS_PER_PLANE) && cabac_chroma_ac_split_plane_ctx()), (cabac_res_bin_ctx_idx - 9'd213)};
                                        end else begin
                                            cabac_ctx_state_in <= 7'd0;
                                            cabac_pending_ctx_kind <= CABAC_CTX_NONE;
                                            cabac_pending_ctx_sel <= 4'd0;
                                        end
                                    end
                                endcase
                            end else begin
                                case (cabac_res_bin_ctx_idx)
                                    9'd85: begin
                                        cabac_ctx_state_in <= cabac_res_cbf_ctx_state[cabac_res_cbf_ctx_sel_for(cabac_res_block_idx)];
                                        cabac_pending_ctx_kind <= CABAC_CTX_RES_CBF;
                                        cabac_pending_ctx_sel <= {2'd0, cabac_res_cbf_ctx_sel_for(cabac_res_block_idx)};
                                    end
                                    9'd227: begin
                                        cabac_ctx_state_in <= cabac_res_level_ctx_state_0;
                                        cabac_pending_ctx_kind <= CABAC_CTX_RES_LEVEL;
                                        cabac_pending_ctx_sel <= 4'd0;
                                    end
                                    9'd232: begin
                                        cabac_ctx_state_in <= cabac_res_level_ctx_state_1;
                                        cabac_pending_ctx_kind <= CABAC_CTX_RES_LEVEL;
                                        cabac_pending_ctx_sel <= 4'd1;
                                    end
                                    default: begin
                                        if ((cabac_res_bin_ctx_idx >= 9'd85) && (cabac_res_bin_ctx_idx <= 9'd88)) begin
                                            cabac_ctx_state_in <= cabac_res_cbf_ctx_state[cabac_res_bin_ctx_idx - 9'd85];
                                            cabac_pending_ctx_kind <= CABAC_CTX_RES_CBF;
                                            cabac_pending_ctx_sel <= cabac_res_bin_ctx_idx - 9'd85;
                                        end else if ((cabac_res_bin_ctx_idx >= 9'd105) && (cabac_res_bin_ctx_idx <= 9'd119)) begin
                                            cabac_ctx_state_in <= cabac_res_sig_ctx_state[cabac_res_bin_ctx_idx - 9'd105];
                                            cabac_pending_ctx_kind <= CABAC_CTX_RES_SIG;
                                            cabac_pending_ctx_sel <= cabac_res_bin_ctx_idx - 9'd105;
                                        end else if ((cabac_res_bin_ctx_idx >= 9'd166) && (cabac_res_bin_ctx_idx <= 9'd180)) begin
                                            cabac_ctx_state_in <= cabac_res_last_ctx_state[cabac_res_bin_ctx_idx - 9'd166];
                                            cabac_pending_ctx_kind <= CABAC_CTX_RES_LAST;
                                            cabac_pending_ctx_sel <= cabac_res_bin_ctx_idx - 9'd166;
                                        end else begin
                                            cabac_ctx_state_in <= 7'd0;
                                            cabac_pending_ctx_kind <= CABAC_CTX_NONE;
                                            cabac_pending_ctx_sel <= 4'd0;
                                        end
                                    end
                                endcase
                            end
                        end
                        if (cabac_res_scan_done)
                            cabac_res_scan_done_pending <= 1'b1;
                        if (cabac_res_scan_done_pending && !cabac_res_bin_valid) begin
                            if (cabac_res_block_idx == cabac_res_last_block_for(cabac_res_category)) begin
                                if ((cabac_res_category == CABAC_RES_CAT_LUMA) && (cabac_cbp_chroma != 2'd0)) begin
                                    cabac_res_category <= CABAC_RES_CAT_CHROMA_DC;
                                    cabac_res_block_idx <= 4'd0;
                                    cabac_res_scan_done_pending <= 1'b0;
                                    sub <= 6'd0;
                                    cabac_res_scan_start <= 1'b1;
                                end else if ((cabac_res_category == CABAC_RES_CAT_CHROMA_DC) && (cabac_cbp_chroma == 2'd2)) begin
                                    cabac_res_category <= CABAC_RES_CAT_CHROMA_AC;
                                    cabac_res_block_idx <= 4'd0;
                                    cabac_res_scan_done_pending <= 1'b0;
                                    sub <= 6'd0;
                                    cabac_res_scan_start <= 1'b1;
                                end else begin
                                    cabac_mb_counter <= cabac_mb_counter + 12'd1;
                                    cabac_res_scan_done_pending <= 1'b0;
                                    sub <= 6'd46;
                                    state <= S_MB_HDR;
                                end
                            end else begin
                                cabac_res_block_idx <= cabac_res_block_idx + 4'd1;
                                cabac_res_scan_done_pending <= 1'b0;
                                sub <= 6'd0;
                                cabac_res_scan_start <= 1'b1;
                            end
                        end
                    end

                    S_TRAIL: begin
                        case (sub)
                            6'd0: begin
                                if (cabac_slice_active) begin
                                    cabac_bin_valid <= 1'b1;
                                    cabac_bin_value <= 1'b1;
                                    cabac_bin_bypass <= 1'b0;
                                    cabac_bin_terminate <= 1'b1;
                                    cabac_ctx_state_in <= 7'd0;
                                    sub <= 6'd20;
                                end else if (slice_has_skip_run && pending_skip_run != 13'd0) begin
                                    bit_buf <= bit_buf | ({ue_big_bits, 71'd0} >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + {1'b0, ue_big_total_bits};
                                    pending_skip_run <= 13'd0;
                                    sub <= 6'd1;
                                end else begin
                                    sub <= 6'd2;
                                end
                            end
                            6'd1: begin
                                state <= S_EMIT;
                                return_state <= S_TRAIL;
                                sub <= 6'd2;
                            end
                            6'd2: begin
                                bit_buf <= bit_buf | ({1'b1, 95'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + 7'd1;
                                sub <= sub + 6'd1;
                            end
                            6'd3: begin
                                if (bit_cnt[2:0] != 3'd0) begin
                                    bit_cnt <= bit_cnt + 7'd1;
                                end else begin
                                    sub <= sub + 6'd1;
                                end
                            end
                            6'd4: begin
                                state <= S_EMIT;
                                return_state <= S_TRAIL;
                                sub <= sub + 6'd1;
                            end
                            6'd5: begin
                                cmd_done <= 1'b1;
                                busy     <= 1'b0;
                                state    <= S_IDLE;
                            end
                            6'd20: begin
                                if (cabac_bits_overflow) begin
                                    `ifndef SYNTHESIS
                                    $fatal(1, "[CABAC_PSKIP] CABAC terminate(1) bit overflow");
                                    `endif
                                    end
                                cabac_slice_active <= 1'b0;
                                if (DEBUG_CABAC_P16X16)
                                    $display("[CABACTERM] mb=%0d count=%0d bits=%024x bit_cnt=%0d ari_low=%0h ari_range=%0d ari_queue=%0d ari_outstanding=%0d ari_pending=%0d ari_pbyte=%0h",
                                             cabac_mb_counter, cabac_bits_count, cabac_bits_out[127:32], bit_cnt,
                                             cabac_debug_low, cabac_debug_range, cabac_debug_queue,
                                             cabac_debug_outstanding, cabac_debug_pending_valid, cabac_debug_pending_byte);
                                if (cabac_bits_valid) begin
                                    cabac_debug_header_bits();
                                    bit_buf <= bit_buf | ((cabac_bits_out[127:32]) >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + {1'b0, cabac_bits_count[6:0]};
                                    state <= S_EMIT;
                                    return_state <= S_TRAIL;
                                end
                                sub <= 6'd21;
                            end
                            6'd21: begin
                                cmd_done <= 1'b1;
                                busy     <= 1'b0;
                                state    <= S_IDLE;
                            end
                            default: state <= S_IDLE;
                        endcase
                    end

                    S_FLUSH: begin
                        if (bit_cnt >= 7'd8) begin
                            write_byte <= bit_buf[95:88];
                            do_write   <= 1'b1;
                            bit_buf    <= bit_buf << 8;
                            bit_cnt    <= bit_cnt - 7'd8;
                        end else if (bit_cnt > 7'd0) begin
                            write_byte <= bit_buf[95:88];
                            do_write   <= 1'b1;
                            bit_buf    <= 96'd0;
                            bit_cnt    <= 7'd0;
                        end else begin
                            cmd_done <= 1'b1;
                            busy     <= 1'b0;
                            state    <= S_IDLE;
                        end
                    end

                    default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule
