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
    parameter FRAME_RATE = 24
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

    // MB coding info
    /* verilator lint_off UNUSED */
    input  wire [7:0]  mb_qp_delta,
    /* verilator lint_on UNUSED */
    input  wire        mb_has_residual,

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
    input  wire [1:0]  mb_ref_idx_l0,
    input  wire [1:0]  mb_ref_idx_l1,
    input  wire signed [8:0] mvd_x_l0,
    input  wire signed [8:0] mvd_y_l0,
    input  wire signed [8:0] mvd_x_l1,
    input  wire signed [8:0] mvd_y_l1,
    input  wire [1:0]  slice_num_ref_idx_l0_active_minus1,
    input  wire        hold_fifo_drain,
    input  wire        is_intra16_mb,
    input  wire        is_ipcm_mb,
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

    reg [3:0]  state;
    reg [3:0]  return_state;
    reg [5:0]  sub;

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

    wire use_high_profile = (BIT_DEPTH > 8) || (CHROMA_FORMAT_IDC != 1);
    wire use_high444_profile = (CHROMA_FORMAT_IDC == 3);
    wire use_high422_profile = (CHROMA_FORMAT_IDC == 2) || (BIT_DEPTH > 10);
    wire use_main_profile = weighted_pred_enable && !use_high_profile;
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
    wire luma_weight_non_default = (luma_weight != $signed(9'd1 << luma_log2_weight_denom)) || (luma_offset != 9'sd0);
    wire chroma_weight_non_default =
        (chroma_weight_cb != $signed(9'd1 << chroma_log2_weight_denom)) || (chroma_offset_cb != 9'sd0) ||
        (chroma_weight_cr != $signed(9'd1 << chroma_log2_weight_denom)) || (chroma_offset_cr != 9'sd0);
    wire [7:0] sps_profile_idc = use_high444_profile ? 8'hF4 :
                                 use_high422_profile ? 8'h7A :
                                 use_high_profile   ? 8'h6E :
                                 use_main_profile   ? 8'h4D : 8'h42;
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
    wire [9:0]  mvd_x_l1_codenum_w = (mvd_x_l1 == 9'sd0) ? 10'd0 :
                                     (mvd_x_l1[8])       ? ({(~mvd_x_l1 + 9'd1), 1'b0}) :
                                                            ({mvd_x_l1, 1'b0} - 10'd1);
    wire [9:0]  mvd_y_l1_codenum_w = (mvd_y_l1 == 9'sd0) ? 10'd0 :
                                     (mvd_y_l1[8])       ? ({(~mvd_y_l1 + 9'd1), 1'b0}) :
                                                            ({mvd_y_l1, 1'b0} - 10'd1);

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
            sub              <= 6'd0;
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
        end else begin
            bs_mem_wr <= 1'b0;
            cmd_done  <= 1'b0;

            // Push to FIFO on valid (if full, we drop, but 64 entries should be plenty)
            if (cavlc_valid && cavlc_count > 6'd0) begin
                if (!fifo_full) begin
                    cavlc_fifo[fifo_wr_ptr] <= {cavlc_bits, cavlc_count};
                    fifo_wr_ptr <= fifo_wr_ptr + {{(CAVLC_FIFO_PTR_W-1){1'b0}}, 1'b1};
                end
            end

            if (do_write) begin
                if (zero_cnt >= 2'd2 && write_byte <= 8'h03) begin
`ifdef VERILATOR
                    if (dbg_fifo_deq_idx >= 1470 && dbg_fifo_deq_idx <= 1495)
                        $display("[BSWR] epb byte=03 bitcnt=%0d bytes=%0d", bit_cnt, bs_bytes_written);
`endif
                    bs_mem_data      <= 8'h03;
                    bs_mem_wr        <= 1'b1;
                    bs_mem_addr      <= bs_bytes_written;
                    bs_bytes_written <= bs_bytes_written + 24'd1;
                    zero_cnt         <= 2'd0;
                end else begin
`ifdef VERILATOR
                    if (dbg_fifo_deq_idx >= 1470 && dbg_fifo_deq_idx <= 1495)
                        $display("[BSWR] byte=%02x bitcnt=%0d bytes=%0d", write_byte, bit_cnt, bs_bytes_written);
`endif
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
                            state <= S_PPS; sub <= 6'd0; busy <= 1'b1;
                        end else if (cmd_write_slice_hdr) begin
                            state <= S_SLICE; sub <= 6'd0; busy <= 1'b1;
                        end else if (cmd_write_mb_header) begin
                            state <= S_MB_HDR; sub <= 6'd0; busy <= 1'b1; ipcm_sample_idx <= 10'd0;
                        end else if (cmd_write_trailing) begin
                            state <= S_TRAIL; sub <= 6'd0; busy <= 1'b1;
                        end else if (cmd_flush) begin
                            state <= S_FLUSH; busy <= 1'b1;
                        end else if (!hold_fifo_drain && !fifo_empty) begin
`ifdef VERILATOR
                            if (dbg_fifo_deq_idx >= 1470 && dbg_fifo_deq_idx <= 1495)
                                $display("[BSDQ] idx=%0d rdptr=%0d cnt=%0d bitcnt=%0d bits=%08x bytes=%0d", dbg_fifo_deq_idx, fifo_rd_ptr, fifo_rd_count, bit_cnt, fifo_rd_bits, bs_bytes_written);
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
                            // Emit remaining bytes
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
                            6'd4:  begin write_byte<=8'h68; do_write<=1'b1; sub<=sub+6'd1; end
                            6'd5: begin
                                if (use_high_profile) begin
                                    // High-profile PPS: baseline fields plus transform_8x8_mode_flag,
                                    // pic_scaling_matrix_present_flag, second_chroma_qp_index_offset.
                                    // Fields before rbsp_stop_one_bit:
                                    // entropy_coding_mode=0 (CAVLC), pic_order_present=0,
                                    // num_slice_groups=UE(0)'1', num_ref_idx_l0=UE(0)'1',
                                    // num_ref_idx_l1=UE(0)'1', weighted_pred=0,
                                    // weighted_bipred is explicit (01) when weighted prediction is enabled.
                                    // pic_init_qs=SE(0)'1', chroma_qp_offset=SE(0)'1',
                                    // deblocking_filter_control=1, constrained_intra=0, redundant_pic_cnt=0,
                                    // transform_8x8_mode=0, pic_scaling_matrix_present=0,
                                    // second_chroma_qp_index_offset=SE(0)'1'
                                    // = 19 bits before rbsp_stop_one_bit.
                                    bit_buf <= {7'b1100111, weighted_pred_flag,
                                                (weighted_bipred_idc == 2'b01) ? 8'b01111100 : 8'b00111100,
                                                3'b001, 77'd0};
                                    bit_cnt <= 7'd19;
                                    sub <= 6'd10; // jump to emit+trailing
                                end else begin
                                    // Baseline/Main PPS: first byte varies only with weighted_pred_flag.
                                    write_byte <= weighted_pred_flag ? 8'hCF : 8'hCE;
                                    do_write <= 1'b1;
                                    sub <= sub + 6'd1;
                                end
                            end
                            6'd6:  begin write_byte<=weighted_pred_enable ? 8'h7C : 8'h3C; do_write<=1'b1; sub<=sub+6'd1; end
                            6'd7:  begin write_byte<=8'h80; do_write<=1'b1; sub<=sub+6'd1; end
                            6'd8:  begin cmd_done<=1'b1; busy<=1'b0; state<=S_IDLE; zero_cnt<=2'd0; end
                            // High 10 PPS path: add RBSP trailing and emit
                            6'd10: begin
                                // Add RBSP stop bit
                                bit_buf <= bit_buf | ({1'b1, 95'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + 7'd1;
                                sub <= sub + 6'd1;
                            end
                            6'd11: begin
                                // Pad to byte boundary
                                if (bit_cnt[2:0] != 3'd0)
                                    bit_cnt <= bit_cnt + 7'd1;
                                else
                                    sub <= sub + 6'd1;
                            end
                            6'd12: begin
                                state <= S_EMIT;
                                return_state <= S_PPS;
                                sub <= sub + 6'd1;
                            end
                            6'd13: begin cmd_done<=1'b1; busy<=1'b0; state<=S_IDLE; zero_cnt<=2'd0; end
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
                                    if (weighted_pred_flag) begin
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
                                        // B-slice base header up to ref_pic_list_reordering_flag_l1:
                                        // first_mb=UE(0), slice_type(B)=UE(1), pps_id=UE(0), frame_num(8),
                                        // pic_order_cnt_lsb(9), direct_spatial_mv_pred_flag=1,
                                        // num_ref_idx_active_override_flag=0,
                                        // ref_pic_list_reordering_flag_l0=0,
                                        // ref_pic_list_reordering_flag_l1=0.
                                        bit_buf <= {1'b1, 3'b010, 1'b1, frame_num, pic_order_cnt_lsb, 4'b1000, 70'd0};
                                        bit_cnt <= 7'd26;
                                        ue_input <= {6'd0, luma_log2_weight_denom};
                                        sub <= 6'd8;
                                    end else begin
                                        // Non-reference B-slice header on the current intra/I_PCM-only B path:
                                        // first_mb=UE(0), slice_type(B)=UE(1), pps_id=UE(0), frame_num(8),
                                        // pic_order_cnt_lsb(9), direct_spatial_mv_pred_flag=1,
                                        // num_ref_idx_active_override_flag=0, ref_pic_list_reordering_flag_l0=0,
                                        // ref_pic_list_reordering_flag_l1=0, optional adaptive_ref_pic_marking_mode_flag,
                                        // slice_qp_delta=SE(0), deblocking=UE(1)
                                        if (is_b_ref_slice) begin
                                            bit_buf <= {1'b1, 3'b010, 1'b1, frame_num, pic_order_cnt_lsb, 6'b100001, 3'b010, 65'd0};
                                            bit_cnt <= 7'd31;
                                        end else begin
                                            bit_buf <= {1'b1, 3'b010, 1'b1, frame_num, pic_order_cnt_lsb, 5'b10001, 3'b010, 66'd0};
                                            bit_cnt <= 7'd30;
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
                            default: state <= S_IDLE;
                        endcase
                    end

                    S_MB_HDR: begin
                        case (sub)
                            6'd0: begin
                                if (slice_has_skip_run && is_skip_mb) begin
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
                                        // Current P inter path uses P_L0_16x16, which is mb_type=0.
                                        bit_buf <= bit_buf | ({1'b1, 95'd0} >> bit_cnt[6:0]);
                                        bit_cnt <= bit_cnt + 7'd1;
                                        sub <= 6'd10;  // jump to inter path
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
                                sub <= 6'd10;
                            end

                            // ===== Inter MB path (sub 10+) =====
                            // After the inter mb_type, P-slices may need ref_idx_l0 before the
                            // motion-vector-difference syntax. The current B-slice subset uses one
                            // active reference per list, so it emits only the relevant MVD pairs.
                            // For exactly two active refs, ref_idx_l0 uses TE(v) with x=1,
                            // which is a single bit encoded as (1 ^ ref_idx).
                            // For three active refs, TE(v) falls back to UE(v) of ref_idx.
                            6'd10: begin
                                if (is_b_slice) begin
                                    ue_input <= is_b_l1_mb ? mvd_x_l1_codenum_w : mvd_x_l0_codenum_w;
                                    sub <= 6'd12;
                                end else if (slice_multi_ref_enable) begin
                                    if (slice_num_ref_idx_l0_active_minus1 == 2'd1) begin
                                        bit_buf <= bit_buf | ({(~mb_ref_idx_l0[0]), 95'd0} >> bit_cnt[6:0]);
                                        bit_cnt <= bit_cnt + 7'd1;
                                        sub <= 6'd11;
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
                                // qp_delta = SE(0) = '1' (only if CBP != 0)
                                if (mb_has_residual) begin
                                    bit_buf <= bit_buf | ({1'b1, 95'd0} >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + 7'd1;
                                end
                                sub <= 6'd17;
                            end
                            6'd17: begin
                                state <= S_EMIT;
                                return_state <= S_MB_HDR;
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
                                sub <= 6'd11;
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

                    S_TRAIL: begin
                        case (sub)
                            6'd0: begin
                                if (slice_has_skip_run && pending_skip_run != 13'd0) begin
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
