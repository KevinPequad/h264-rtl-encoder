# H.264 Verilog Encoder — Review Request

I built a custom H.264 Baseline Profile encoder in Verilog, simulated via Verilator. It encodes 320x176 YUV420 frames as all-intra I-frames with DC-only 16x16 prediction, CAVLC entropy coding, QP=26. The pipeline is: fetch → intra_pred → (transform → quant → zigzag → cavlc → inverse_quant → inverse_transform → reconstruct) per 4x4 sub-block → bitstream output.

**The encoder produces an MP4 file that ffprobe recognizes as valid H.264 (Constrained Baseline, 320x176, 480 frames, 20 seconds), but ffmpeg's decoder reports errors:**

```
[h264] top block unavailable for requested intra mode
[h264] error while decoding MB 0 0
[h264] concealing 220 DC, 220 AC, 220 MV errors in I frame
```

This means ALL 220 macroblocks in every frame are erroring out. The output "plays" but is fully error-concealed (not actually decoded). I need help identifying what's wrong with the bitstream.

## Hex dump of first 256 bytes of encoded.h264:

```
00000000: 00 00 00 01 67 42 c0 1e dc 14 17 10 00 00 00 01
00000010: 68 ce 38 80 00 00 00 01 65 b8 48 e8 a0 00 20 23
00000020: 14 00 04 04 62 80 00 80 8c 50 00 10 11 8a 00 02
00000030: 02 31 40 00 40 46 28 00 08 08 c5 00 01 01 18 a0
00000040: 00 20 23 14 00 04 04 62 80 00 80 8c 50 00 10 11
00000050: 8a 00 02 02 31 40 00 40 46 28 00 08 08 c5 00 01
00000060: 01 18 e8 a0 00 20 1f 14 00 04 03 e2 80 00 80 7c
00000070: 50 00 10 0f 8a 00 02 01 f1 40 00 40 3e 28 00 08
```

## SPS bytes (after NAL header 0x67):
`42 C0 1E DC 14 17 10`

## PPS bytes (after NAL header 0x68):
`CE 38 80`

## Slice header (after NAL header 0x65):
13 bits: `1_011_1_0000_1_00_1` then byte-aligned via bitstream emitter.

---

## Complete Verilog source files:

### 1. h264_bitstream.v — Bitstream Assembler / NAL Unit Writer

```verilog
module h264_bitstream (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        cmd_write_sps,
    input  wire        cmd_write_pps,
    input  wire        cmd_write_slice_hdr,
    input  wire        cmd_write_mb_header,
    input  wire        cmd_write_trailing,
    input  wire        cmd_flush,
    input  wire        cavlc_valid,
    input  wire [31:0] cavlc_bits,
    input  wire [5:0]  cavlc_count,
    input  wire [7:0]  mb_qp_delta,
    input  wire        mb_has_residual,
    output reg         busy,
    output reg         cmd_done,
    output reg  [23:0] bs_mem_addr,
    output reg  [7:0]  bs_mem_data,
    output reg         bs_mem_wr,
    output reg  [23:0] bs_bytes_written
);

    reg [95:0] bit_buf;
    reg [6:0]  bit_cnt;
    reg [1:0]  zero_cnt;

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
    reg        do_write;
    reg [7:0]  write_byte;
    reg        cavlc_buf_valid;
    reg [31:0] cavlc_buf_bits;
    reg [5:0]  cavlc_buf_count;
    reg        skip_ep;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // ... reset all to 0 ...
        end else begin
            bs_mem_wr <= 1'b0;
            cmd_done  <= 1'b0;

            // Buffer incoming CAVLC bits
            if (cavlc_valid && cavlc_count > 6'd0 && state != S_IDLE && !cavlc_buf_valid) begin
                cavlc_buf_valid <= 1'b1;
                cavlc_buf_bits  <= cavlc_bits;
                cavlc_buf_count <= cavlc_count;
            end

            if (do_write) begin
                // Emulation prevention: if two 0x00 bytes then next <= 0x03, insert 0x03
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
                        // Accept commands or CAVLC bits
                    end

                    S_EMIT: begin
                        if (bit_cnt >= 7'd8) begin
                            write_byte <= bit_buf[95:88];
                            do_write   <= 1'b1;
                            bit_buf    <= bit_buf << 8;
                            bit_cnt    <= bit_cnt - 7'd8;
                        end else if (cavlc_buf_valid) begin
                            bit_buf <= bit_buf | (({cavlc_buf_bits, 64'd0} >> bit_cnt[6:0]));
                            bit_cnt <= bit_cnt + {1'b0, cavlc_buf_count};
                            cavlc_buf_valid <= 1'b0;
                        end else begin
                            state <= return_state;
                        end
                    end

                    // SPS: start code written directly (bypass EP)
                    S_SPS: begin
                        case (sub)
                            6'd0:  begin bs_mem_data<=8'h00; bs_mem_wr<=1'b1; bs_mem_addr<=bs_bytes_written; bs_bytes_written<=bs_bytes_written+24'd1; sub<=sub+6'd1; end
                            6'd1:  begin bs_mem_data<=8'h00; bs_mem_wr<=1'b1; bs_mem_addr<=bs_bytes_written; bs_bytes_written<=bs_bytes_written+24'd1; sub<=sub+6'd1; end
                            6'd2:  begin bs_mem_data<=8'h00; bs_mem_wr<=1'b1; bs_mem_addr<=bs_bytes_written; bs_bytes_written<=bs_bytes_written+24'd1; sub<=sub+6'd1; end
                            6'd3:  begin bs_mem_data<=8'h01; bs_mem_wr<=1'b1; bs_mem_addr<=bs_bytes_written; bs_bytes_written<=bs_bytes_written+24'd1; sub<=sub+6'd1; zero_cnt<=2'd0; end
                            // NAL header 0x67 = SPS
                            6'd4:  begin write_byte<=8'h67; do_write<=1'b1; sub<=sub+6'd1; end
                            // SPS RBSP bytes
                            6'd5:  begin write_byte<=8'h42; do_write<=1'b1; sub<=sub+6'd1; end  // profile_idc=66 (Baseline)
                            6'd6:  begin write_byte<=8'hC0; do_write<=1'b1; sub<=sub+6'd1; end  // constraint_set0_flag=1, constraint_set1_flag=1
                            6'd7:  begin write_byte<=8'h1E; do_write<=1'b1; sub<=sub+6'd1; end  // level_idc=30
                            6'd8:  begin write_byte<=8'hDC; do_write<=1'b1; sub<=sub+6'd1; end
                            6'd9:  begin write_byte<=8'h14; do_write<=1'b1; sub<=sub+6'd1; end
                            6'd10: begin write_byte<=8'h17; do_write<=1'b1; sub<=sub+6'd1; end
                            6'd11: begin write_byte<=8'h10; do_write<=1'b1; sub<=sub+6'd1; end
                            6'd12: begin cmd_done<=1'b1; busy<=1'b0; state<=S_IDLE; zero_cnt<=2'd0; end
                            default: state <= S_IDLE;
                        endcase
                    end

                    // PPS: start code + NAL header 0x68
                    S_PPS: begin
                        case (sub)
                            6'd0-3: // start code 00 00 00 01 (same as SPS)
                            6'd4:  begin write_byte<=8'h68; do_write<=1'b1; sub<=sub+6'd1; end
                            6'd5:  begin write_byte<=8'hCE; do_write<=1'b1; sub<=sub+6'd1; end
                            6'd6:  begin write_byte<=8'h38; do_write<=1'b1; sub<=sub+6'd1; end
                            6'd7:  begin write_byte<=8'h80; do_write<=1'b1; sub<=sub+6'd1; end
                            6'd8:  begin cmd_done<=1'b1; busy<=1'b0; state<=S_IDLE; zero_cnt<=2'd0; end
                        endcase
                    end

                    // Slice header: start code + NAL header 0x65 (IDR) + 13 bits RBSP
                    S_SLICE: begin
                        case (sub)
                            6'd0-3: // start code
                            6'd4:  begin write_byte<=8'h65; do_write<=1'b1; sub<=sub+6'd1; end
                            6'd5: begin
                                // 13 bits: first_mb_in_slice=ue(0)=1, slice_type=ue(2)=011,
                                // pps_id=ue(0)=1, frame_num=u(4)=0000, idr_pic_id=ue(0)=1,
                                // no_output_of_prior_pics=0, long_term_ref=0, qp_delta=se(0)=1
                                bit_buf <= {13'b1011100001001, 83'd0};
                                bit_cnt <= 7'd13;
                                sub <= sub + 6'd1;
                            end
                            6'd6: begin state <= S_EMIT; return_state <= S_SLICE; sub <= sub + 6'd1; end
                            6'd7: begin cmd_done <= 1'b1; busy <= 1'b0; state <= S_IDLE; end
                        endcase
                    end

                    // MB header
                    S_MB_HDR: begin
                        case (sub)
                            6'd0: begin
                                if (mb_has_residual) begin
                                    // ue(13) = 0001110 (7 bits) — I_16x16_0_0_1
                                    bit_buf <= bit_buf | ({7'b0001110, 89'd0} >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + 7'd7;
                                end else begin
                                    // ue(1) = 010 (3 bits)
                                    bit_buf <= bit_buf | ({3'b010, 93'd0} >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + 7'd3;
                                end
                                sub <= sub + 6'd1;
                            end
                            6'd1: begin
                                if (mb_has_residual) begin
                                    // mb_qp_delta = se(0) = 1 (1 bit)
                                    bit_buf <= bit_buf | ({1'b1, 95'd0} >> bit_cnt[6:0]);
                                    bit_cnt <= bit_cnt + 7'd1;
                                end
                                sub <= sub + 6'd1;
                            end
                            6'd2: begin state <= S_EMIT; return_state <= S_MB_HDR; sub <= sub + 6'd1; end
                            6'd3: begin cmd_done <= 1'b1; busy <= 1'b0; state <= S_IDLE; end
                        endcase
                    end

                    // Trailing bits
                    S_TRAIL: begin
                        // Stop bit (1) + zero padding to byte boundary
                    end

                    S_FLUSH: begin
                        // Emit remaining bits in buffer
                    end
                endcase
            end
        end
    end
endmodule
```

### 2. h264_encoder_top.v — Top-Level FSM

```verilog
module h264_encoder_top (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    output reg         done,
    output wire [19:0] raw_mem_addr,
    input  wire [7:0]  raw_mem_data,
    output wire [23:0] bs_mem_addr,
    output wire [7:0]  bs_mem_data,
    output wire        bs_mem_wr,
    output wire [23:0] bs_bytes_written
);

    parameter FRAME_WIDTH  = 320;
    parameter FRAME_HEIGHT = 176;
    parameter MB_COLS      = 20;
    parameter MB_ROWS      = 11;

    // FSM: IDLE → WRITE_SPS → WAIT_SPS → WRITE_PPS → WAIT_PPS → WRITE_SLICE →
    //      WAIT_SLICE → FETCH_MB → WAIT_FETCH → PREDICT → WAIT_PRED → MB_HDR →
    //      ENCODE_SBLK (loops 16 sub-blocks) → NEXT_MB → TRAILING → DONE

    // Key detail: mb_has_residual is ALWAYS set to 1 (hardcoded)
    // This means mb_type is always coded as ue(13) = I_16x16_0_0_1

    // Neighbor availability:
    //   top_avail  = (mb_y > 0)
    //   left_avail = (mb_x > 0)

    // Sub-block processing pipeline per 4x4 block:
    //   transform → quant → zigzag+inverse_quant(parallel) → cavlc →
    //   wait_iq → inverse_transform → reconstruct

    // After all 220 MBs: trailing bits → flush → done
endmodule
```

### 3. h264_intra_pred.v — DC-only Intra Prediction

```verilog
// DC prediction for 16x16 macroblock:
// - If top+left available: dc = (sum_top + sum_left + 16) >> 5
// - If only top: dc = (sum_top + 8) >> 4
// - If only left: dc = (sum_left + 8) >> 4
// - If neither: dc = 128
// Fills entire 16x16 block with dc_value
// Residual = original - dc_value (9-bit signed per pixel)
```

### 4. h264_transform.v — Forward 4x4 Integer DCT

```verilog
// Row-first butterfly: p = a+b+c+d, q = 2a+b-c-2d, r = a-b-c+d, s = a-2b+2c-d
// Then column-wise same butterfly
// Output: 16-bit signed coefficients
```

### 5. h264_quantize.v — Forward Quantization (QP=26)

```verilog
// level = (|coeff| * MF + f_intra) >> qbits
// QP=26: qbits=19, f_intra=174763
// MF: even-even & odd-odd positions = 5243, cross = 6554
```

### 6. h264_zigzag.v — Zigzag Scan + Statistics

```verilog
// Standard H.264 4x4 zigzag: 0,1,4,8,5,2,3,6,9,12,13,10,7,11,14,15
// Computes: total_coeffs, trailing_ones (max 3, from end of scan, ±1 only),
//           last_nonzero_idx
```

### 7. h264_cavlc.v — CAVLC Entropy Coding

```verilog
// Full CAVLC implementation with:
// - coeff_token table (nC=0..1 range only, hardcoded)
// - Trailing one signs
// - Level VLC (suffix_length adaptation)
// - total_zeros table
// - run_before table
// Output: MSB-justified bits fragments to bitstream assembler
```

### 8. h264_inverse_quant.v — Inverse Quantization

```verilog
// For QP=26: level * LevelScale (10 for diagonal, 8 for cross positions)
// Since QP/6=4, shift factor = 2^(4-4) = 1
```

### 9. h264_inverse_transform.v — Inverse 4x4 DCT

```verilog
// Column-first then row-wise butterfly with rounding:
// e0=a+c, e1=a-c, e2=(b>>1)-d, e3=b+(d>>1)
// out = (result + 32) >> 6
```

### 10. h264_reconstruct.v — Pixel Reconstruction

```verilog
// clipped = clamp(prediction[pixel] + inverse_transform_residual[pixel], 0, 255)
// Tracks bottom row (for top neighbor of row below) and right column (for left neighbor)
```

### 11. h264_fetch.v — Macroblock Fetch

```verilog
// Reads 16x16 luma + 8x8 Cb + 8x8 Cr from byte-addressed YUV420 memory
// One byte per cycle
```

---

## Specific Questions:

1. **SPS/PPS byte encoding**: Are my hardcoded SPS bytes (`67 42 C0 1E DC 14 17 10`) and PPS bytes (`68 CE 38 80`) correct for Baseline profile, 320x176, QP=26? Can you decode them bit by bit?

2. **Slice header**: The 13-bit slice header `1_011_1_0000_1_00_1` — is this correct for an IDR I-slice with first_mb_in_slice=0, slice_type=I(2), pps_id=0, frame_num=0, idr_pic_id=0, qp_delta=0?

3. **mb_type encoding**: I always code mb_type as ue(13) = `0001110` which should be I_16x16_0_0_1 (DC prediction, CBP luma=15, CBP chroma=0). Is this the right mb_type value for an I-slice macroblock using Intra_16x16 DC prediction with residual?

4. **The "top block unavailable" error**: For MB(0,0), there's no top neighbor. I set `top_avail=0` and use DC=128 for prediction. But the mb_type I_16x16_0_0_1 signals "Intra16x16PredMode=0" which is **vertical prediction** (not DC!). Is this the root cause? Should I use a different mb_type value to signal DC prediction mode?

5. **CAVLC correctness**: My coeff_token table is for nC=0..1. I always pass nC=0. Is this correct for Intra_16x16 blocks?

6. **Overall bitstream structure**: For each MB I emit: mb_header (mb_type + qp_delta) then 16× CAVLC blocks. Is there anything missing (like coded_block_pattern, sub_mb_type, etc.) for Intra_16x16 mode?

7. **Any other H.264 compliance issues** you can spot that would cause the decoder to fail on every single macroblock?
