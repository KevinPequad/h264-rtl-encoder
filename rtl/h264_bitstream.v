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
    parameter CHROMA_FORMAT_IDC = 1
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

    // Bits from CAVLC encoder
    input  wire        cavlc_valid,
    input  wire [31:0] cavlc_bits,
    input  wire [5:0]  cavlc_count,

    // MB coding info
    /* verilator lint_off UNUSED */
    input  wire [7:0]  mb_qp_delta,
    /* verilator lint_on UNUSED */
    input  wire        mb_has_residual,

    // P-frame support
    input  wire        is_p_slice,
    input  wire [3:0]  frame_num,
    input  wire        is_inter_mb,
    input  wire signed [8:0] mvd_x,
    input  wire signed [8:0] mvd_y,

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
    // =====================================================================
    reg [37:0] cavlc_fifo [0:63]; // 32 bits data + 6 bits count
    reg [5:0]  fifo_wr_ptr;
    reg [5:0]  fifo_rd_ptr;
    wire [5:0] fifo_count = fifo_wr_ptr - fifo_rd_ptr;
    wire       fifo_empty = (fifo_wr_ptr == fifo_rd_ptr);
    wire       fifo_full  = (fifo_count == 6'd63);

    wire [37:0] fifo_rd_data = cavlc_fifo[fifo_rd_ptr];
    wire [31:0] fifo_rd_bits  = fifo_rd_data[37:6];
    wire [5:0]  fifo_rd_count = fifo_rd_data[5:0];
    reg        cavlc_buf_valid;
    reg [31:0] cavlc_buf_bits;
    reg [5:0]  cavlc_buf_count;

    wire use_high_profile = (BIT_DEPTH > 8) || (CHROMA_FORMAT_IDC != 1);
    wire use_high422_profile = (CHROMA_FORMAT_IDC == 2) || (BIT_DEPTH > 10);
    wire [7:0] sps_profile_idc = use_high422_profile ? 8'h7A :
                                 use_high_profile   ? 8'h6E : 8'h42;
    wire [7:0] sps_constraint_flags = use_high_profile ? 8'h00 : 8'hC0;
    wire [3:0] sps_id_and_chroma_bits = (CHROMA_FORMAT_IDC == 2) ? 4'b1011 : 4'b1010;
    wire [5:0] pic_order_cnt_lsb = {frame_num, 1'b0};

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
    wire [10:0] se_code1 = se_codenum + 11'd1;  // codeNum + 1

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
            fifo_wr_ptr      <= 6'd0;
            fifo_rd_ptr      <= 6'd0;
            cavlc_buf_valid  <= 1'b0;
            cavlc_buf_bits   <= 32'd0;
            cavlc_buf_count  <= 6'd0;
            skip_ep          <= 1'b0;
            se_input         <= 8'sd0;
            ue_input         <= 10'd0;
        end else begin
            bs_mem_wr <= 1'b0;
            cmd_done  <= 1'b0;

            // Push to FIFO on valid (if full, we drop, but 64 entries should be plenty)
            if (cavlc_valid && cavlc_count > 6'd0) begin
                if (!fifo_full) begin
                    cavlc_fifo[fifo_wr_ptr] <= {cavlc_bits, cavlc_count};
                    fifo_wr_ptr <= fifo_wr_ptr + 6'd1;
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
                        busy <= (!fifo_empty) || (bit_cnt >= 7'd8) || do_write;
                        if (cmd_write_sps) begin
                            state <= S_SPS; sub <= 6'd0; busy <= 1'b1;
                        end else if (cmd_write_pps) begin
                            state <= S_PPS; sub <= 6'd0; busy <= 1'b1;
                        end else if (cmd_write_slice_hdr) begin
                            state <= S_SLICE; sub <= 6'd0; busy <= 1'b1;
                        end else if (cmd_write_mb_header) begin
                            state <= S_MB_HDR; sub <= 6'd0; busy <= 1'b1;
                        end else if (cmd_write_trailing) begin
                            state <= S_TRAIL; sub <= 6'd0; busy <= 1'b1;
                        end else if (cmd_flush) begin
                            state <= S_FLUSH; busy <= 1'b1;
                        end else if (!fifo_empty) begin
                            bit_buf <= bit_buf | (({fifo_rd_bits, 64'd0} >> bit_cnt[6:0]));
                            bit_cnt <= bit_cnt + {1'b0, fifo_rd_count};
                            fifo_rd_ptr <= fifo_rd_ptr + 6'd1;
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
                            // level_idc: compute from resolution
                            // Level 31 (0x1F) for up to 720p, Level 30 (0x1E) for <= QVGA
                            6'd7:  begin
                                if (MB_COLS * MB_ROWS > 396)
                                    write_byte <= 8'h1F;  // level 3.1: up to 3600 MBs (1280x720)
                                else
                                    write_byte <= 8'h1E;  // level 3.0: up to 396 MBs
                                do_write <= 1'b1;
                                sub <= sub + 6'd1;
                            end
                            // sps_id=UE(0)='1'
                            // For High profiles: chroma_format_idc=UE(CHROMA_FORMAT_IDC),
                            //   bit_depth_luma_minus8, bit_depth_chroma_minus8,
                            //   qpprime_y_zero_transform_bypass=0,
                            //   seq_scaling_matrix_present=0
                            // Then: log2_max_frame_num_minus4=UE(0)='1'
                            // + poc_type=UE(2)='011' + max_num_ref_frames=UE(1)='010'
                            // + gaps_in_frame_num=0
                            6'd8: begin
                                if (use_high_profile) begin
                                    // sps_id=UE(0)='1' + chroma_format_idc=UE(1 or 2)
                                    bit_buf <= {sps_id_and_chroma_bits, 92'd0};
                                    bit_cnt <= 7'd4;
                                    // Set up UE for bit_depth_luma_minus8
                                    ue_input <= BIT_DEPTH - 8;
                                    sub <= 6'd20; // jump to High profile sub-states
                                end else begin
                                    // Baseline: all-in-one
                                    // sps_id + log2_max_frame_num + poc_type + max_ref + gaps
                                    // 1+1+3+3+1 = 9 bits: 110110100
                                    bit_buf <= {9'b110110100, 87'd0};
                                    bit_cnt <= 7'd9;
                                    ue_input <= MB_COLS - 1;
                                    sub <= sub + 6'd1;
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
                            // frame_mbs_only=1, direct_8x8_inference (1 if level>=30),
                            // frame_cropping=0, vui_present=0
                            // = 1,1,0,0 = 4 bits: 1100
                            6'd12: begin
                                bit_buf <= bit_buf | ({4'b1100, 92'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + 7'd4;
                                sub <= sub + 6'd1;
                            end
                            // RBSP trailing bits: stop bit '1' + alignment zeros
                            6'd13: begin
                                bit_buf <= bit_buf | ({1'b1, 95'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + 7'd1;
                                // Pad to byte boundary
                                sub <= sub + 6'd1;
                            end
                            6'd14: begin
                                if (bit_cnt[2:0] != 3'd0)
                                    bit_cnt <= bit_cnt + 7'd1;
                                else
                                    sub <= sub + 6'd1;
                            end
                            // Emit remaining bytes
                            6'd15: begin
                                state <= S_EMIT;
                                return_state <= S_SPS;
                                sub <= sub + 6'd1;
                            end
                            6'd16: begin cmd_done<=1'b1; busy<=1'b0; state<=S_IDLE; zero_cnt<=2'd0; end

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
                            // Then: log2_max_frame_num_minus4=UE(0)='1'
                            // + poc_type=UE(0)='1' (poc_type=0)
                            // + log2_max_pic_order_cnt_lsb_minus4=UE(2)='011' (max_poc_lsb=64)
                            // + max_num_ref_frames=UE(1)='010'
                            // + gaps_in_frame_num=0
                            // = 0,0 + 1,1,011,010,0 = 2+9 = 11 bits: 00110110100
                            6'd22: begin
                                bit_buf <= bit_buf | ({11'b00110110100, 85'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + 7'd11;
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
                                    // weighted_bipred=00, pic_init_qp=SE(0)'1',
                                    // pic_init_qs=SE(0)'1', chroma_qp_offset=SE(0)'1',
                                    // deblocking_filter_control=1, constrained_intra=0, redundant_pic_cnt=0,
                                    // transform_8x8_mode=0, pic_scaling_matrix_present=0,
                                    // second_chroma_qp_index_offset=SE(0)'1'
                                    // = 19 bits before rbsp_stop_one_bit.
                                    bit_buf <= {19'b1100111000111100001, 77'd0};
                                    bit_cnt <= 7'd19;
                                    sub <= 6'd10; // jump to emit+trailing
                                end else begin
                                    // Baseline PPS: hardcoded bytes CE 3C 80
                                    write_byte<=8'hCE; do_write<=1'b1; sub<=sub+6'd1;
                                end
                            end
                            6'd6:  begin write_byte<=8'h3C; do_write<=1'b1; sub<=sub+6'd1; end
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
                                else
                                    write_byte <= 8'h65; // nal_ref_idc=3, nal_unit_type=5 (IDR)
                                do_write <= 1'b1;
                                sub <= sub + 6'd1;
                            end
                            6'd5: begin
                                if (is_p_slice) begin
                                    if (use_high_profile) begin
                                        // High-profile P-slice: SPS has poc_type=0, need poc_lsb(6 bits)
                                        // first_mb=UE(0)'1', slice_type(P)=UE(0)'1', pps_id=UE(0)'1',
                                        // frame_num(4), poc_lsb(6), num_ref_override=0, ref_list_reorder=0,
                                        // adaptive_marking=0, qp_delta=SE(0)'1', disable_deblocking=UE(1)'010'
                                        bit_buf <= {3'b111, frame_num, pic_order_cnt_lsb, 4'b0001, 3'b010, 76'd0};
                                        bit_cnt <= 7'd20;
                                    end else begin
                                        // Baseline P-slice: SPS has poc_type=2, no poc_lsb
                                        bit_buf <= {3'b111, frame_num, 4'b0001, 3'b010, 82'd0};
                                        bit_cnt <= 7'd14;
                                    end
                                end else begin
                                    if (use_high_profile) begin
                                        // High-profile IDR: SPS has poc_type=0, need poc_lsb(6 bits)
                                        // first_mb=UE(0)'1', slice_type(I)=UE(2)'011', pps_id=UE(0)'1',
                                        // frame_num(4), idr_pic_id=UE(0)'1', poc_lsb(6),
                                        // no_output_of_prior_pics=0, long_term_ref=0,
                                        // qp_delta=SE(0)'1', disable_deblocking=UE(1)'010'
                                        bit_buf <= {1'b1, 3'b011, 1'b1, frame_num, 1'b1, pic_order_cnt_lsb, 2'b00, 1'b1, 3'b010, 74'd0};
                                        bit_cnt <= 7'd22;
                                    end else begin
                                        // Baseline IDR I-slice: SPS has poc_type=2, no poc_lsb
                                        bit_buf <= {16'b1011100001001010, 80'd0};
                                        bit_cnt <= 7'd16;
                                    end
                                end
                                sub <= sub + 6'd1;
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
                            default: state <= S_IDLE;
                        endcase
                    end

                    S_MB_HDR: begin
                        case (sub)
                            6'd0: begin
                                if (is_inter_mb) begin
                                    // Inter path: mb_skip_run=UE(0)='1' + P_L0_16x16=UE(0)='1' (2 bits)
                                    bit_buf <= bit_buf | ({2'b11, 94'd0} >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + 7'd2;
                                    sub <= 6'd10;  // jump to inter path
                                end else if (is_p_slice) begin
                                    // Intra in P-slice: mb_type offset +5
                                    // I_4x4 = 0+5 = 5 -> UE(5) = '00110' (5 bits)
                                    if (mb_has_residual) begin
                                        // mb_skip_run=UE(0)='1' + UE(5)='00110' + 16 pred '1'
                                        // + chroma=UE(0)'1' + CBP=47(intra)->UE(0)='1'
                                        // + qp_delta SE(0)='1'
                                        // Total: 1+5+16+1+1+1 = 25 bits
                                        bit_buf <= bit_buf | ({25'b1_00110_1111111111111111_1_1_1, 71'd0} >> bit_cnt[6:0]);
                                        bit_cnt <= bit_cnt + 7'd25;
                                    end else begin
                                        // UE(5) + 16x pred_flag + chroma_pred + CBP=0 codeNum=0 UE(0)='1'
                                        // I_4x4 in P with no residual: mb_type=UE(5)='00110'
                                        // + 16 pred flags '1' + chroma UE(0)='1' + CBP=0 -> no cbp/qp
                                        // Actually for CBP=0 in intra, codeNum for CBP=0 is '1' (UE(0))
                                        // But if CBP=0, no qp_delta follows, and no residual
                                        // Wait - mb_has_residual=0 means we use P_Skip or CBP=0
                                        // For intra MB with no residual, CBP=0 -> UE(0)='1'
                                        // mb_skip_run=UE(0)='1' + UE(5)='00110' + 16 pred + chroma=UE(0) + CBP=0->UE(0)='1'
                                        // 1+5+16+1+1 = 24 bits (no qp_delta when CBP=0)
                                        bit_buf <= bit_buf | ({24'b1_00110_1111111111111111_1_1, 72'd0} >> bit_cnt[6:0]);
                                        bit_cnt <= bit_cnt + 7'd24;
                                    end
                                    sub <= 6'd1;
                                end else begin
                                    // I-slice: original intra path
                                    if (mb_has_residual) begin
                                        // mb_type=UE(0) + 16 pred flags '1' + chroma=UE(0) + CBP=47(intra)->UE(0)='1'
                                        // 1+16+1+1 = 19 bits (qp_delta added in sub=1)
                                        bit_buf <= bit_buf | ({19'b1_1111111111111111_1_1, 77'd0} >> bit_cnt[6:0]);
                                        bit_cnt <= bit_cnt + 7'd19;
                                    end else begin
                                        bit_buf <= bit_buf | ({3'b010, 93'd0} >> bit_cnt[6:0]);
                                        bit_cnt <= bit_cnt + 7'd3;
                                    end
                                    sub <= 6'd1;
                                end
                            end
                            // Intra continuation (sub 1-3)
                            6'd1: begin
                                if (mb_has_residual && !is_p_slice) begin
                                    // qp_delta = SE(0) = '1'
                                    bit_buf <= bit_buf | ({1'b1, 95'd0} >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + 7'd1;
                                end
                                sub <= 6'd2;
                            end
                            6'd2: begin
                                state <= S_EMIT;
                                return_state <= S_MB_HDR;
                                sub <= 6'd3;
                            end
                            6'd3: begin
                                cmd_done <= 1'b1;
                                busy     <= 1'b0;
                                state    <= S_IDLE;
                            end

                            // ===== Inter MB path (sub 10+) =====
                            // After mb_type=UE(0), encode mvd_x
                            6'd10: begin
                                se_input <= mvd_x;
                                sub <= 6'd11;
                            end
                            6'd11: begin
                                // Load SE(mvd_x) into bit_buf
                                bit_buf <= bit_buf | ({se_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, se_total_bits};
                                // Prepare mvd_y
                                se_input <= mvd_y;
                                sub <= 6'd12;
                            end
                            6'd12: begin
                                // Emit to make room
                                state <= S_EMIT;
                                return_state <= S_MB_HDR;
                                sub <= 6'd13;
                            end
                            6'd13: begin
                                // Load SE(mvd_y) into bit_buf
                                bit_buf <= bit_buf | ({se_ue_bits, 75'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + {2'b0, se_total_bits};
                                sub <= 6'd14;
                            end
                            6'd14: begin
                                // Inter CBP: CBP=47 -> codeNum=12 -> UE(12)='0001101'
                                //   (luma all, chroma DC+AC)
                                //             CBP=0  -> codeNum=0  -> UE(0)='1'
                                if (mb_has_residual) begin
                                    bit_buf <= bit_buf | ({7'b0001101, 89'd0} >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + 7'd7;
                                end else begin
                                    bit_buf <= bit_buf | ({1'b1, 95'd0} >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + 7'd1;
                                end
                                sub <= 6'd15;
                            end
                            6'd15: begin
                                // qp_delta = SE(0) = '1' (only if CBP != 0)
                                if (mb_has_residual) begin
                                    bit_buf <= bit_buf | ({1'b1, 95'd0} >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + 7'd1;
                                end
                                sub <= 6'd16;
                            end
                            6'd16: begin
                                state <= S_EMIT;
                                return_state <= S_MB_HDR;
                                sub <= 6'd17;
                            end
                            6'd17: begin
                                cmd_done <= 1'b1;
                                busy     <= 1'b0;
                                state    <= S_IDLE;
                            end

                            default: state <= S_IDLE;
                        endcase
                    end

                    S_TRAIL: begin
                        case (sub)
                            6'd0: begin
                                bit_buf <= bit_buf | ({1'b1, 95'd0} >> bit_cnt[6:0]);
                                bit_cnt <= bit_cnt + 7'd1;
                                sub <= sub + 6'd1;
                            end
                            6'd1: begin
                                if (bit_cnt[2:0] != 3'd0) begin
                                    bit_cnt <= bit_cnt + 7'd1;
                                end else begin
                                    sub <= sub + 6'd1;
                                end
                            end
                            6'd2: begin
                                state <= S_EMIT;
                                return_state <= S_TRAIL;
                                sub <= sub + 6'd1;
                            end
                            6'd3: begin
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
