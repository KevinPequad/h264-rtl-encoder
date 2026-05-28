// h264_chroma_dc.v — Chroma DC Hadamard Transform + Quantization
// CHROMA_FORMAT_IDC=1 (4:2:0): 2x2 Hadamard, 4 inputs/outputs
// CHROMA_FORMAT_IDC=2 (4:2:2): 2x4 Hadamard, 8 inputs/outputs (H.264 spec 8.5.11.2)
//
// Forward: takes DC values from 4x4 blocks, applies Hadamard, then quantizes
// Inverse: dequantizes, then inverse Hadamard
//
// 2-cycle pipeline: start -> compute -> done

module h264_chroma_dc #(
    parameter BIT_DEPTH = 8,
    parameter CHROMA_FORMAT_IDC = 1  // 1 = 4:2:0 (2x2), 2 = 4:2:2 (2x4)
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    input  wire        do_inverse,  // 0=forward, 1=inverse
    output reg         done,

    // DC inputs (CW-bit signed)
    // 4:2:0 uses dc_in_0..3, 4:2:2 uses dc_in_0..7
    input  wire signed [CW-1:0] dc_in_0,
    input  wire signed [CW-1:0] dc_in_1,
    input  wire signed [CW-1:0] dc_in_2,
    input  wire signed [CW-1:0] dc_in_3,
    input  wire signed [CW-1:0] dc_in_4,
    input  wire signed [CW-1:0] dc_in_5,
    input  wire signed [CW-1:0] dc_in_6,
    input  wire signed [CW-1:0] dc_in_7,

    // DC outputs (16-bit signed)
    // 4:2:0 uses dc_out_0..3, 4:2:2 uses dc_out_0..7
    output reg  signed [15:0] dc_out_0,
    output reg  signed [15:0] dc_out_1,
    output reg  signed [15:0] dc_out_2,
    output reg  signed [15:0] dc_out_3,
    output reg  signed [15:0] dc_out_4,
    output reg  signed [15:0] dc_out_5,
    output reg  signed [15:0] dc_out_6,
    output reg  signed [15:0] dc_out_7
);

    localparam CW = BIT_DEPTH + 8;

    reg [1:0] state;
    localparam S_IDLE = 2'd0;
    localparam S_EXEC = 2'd1;
    localparam S_DONE = 2'd2;

    // Forward quantization for chroma DC
    // QP=26: MF[0][0]=10082, qBits=19, 2*f_intra = 2 * (2^18 / 3) = 174762
    // level = (|coeff| * 10082 + 174762) >> 20
    localparam [31:0] MF_00 = 32'd10082;
    localparam [31:0] F2_INTRA = 32'd174762;
    localparam QBITS_PLUS1 = 20;

    function signed [15:0] fwd_quant;
        input signed [CW:0] val;
        reg [CW:0] abs_val;
        reg sign;
        reg [CW+32:0] product;
        reg [15:0] level;
        begin
            sign = val[CW];
            abs_val = sign ? (~val[CW:0] + {{CW{1'b0}}, 1'b1}) : val[CW:0];
            product = (abs_val * MF_00) + F2_INTRA;
            level = product[QBITS_PLUS1 +: 16];
            fwd_quant = sign ? (~level + 16'd1) : level;
        end
    endfunction

    // Inverse dequantization for chroma DC
    // For QP=26: d = level * 13 << 4 = level * 208
    function signed [15:0] inv_dequant;
        input signed [CW-1:0] level;
        reg signed [31:0] product;
        begin
            product = $signed(level[15:0]) * 16'sd208;
            inv_dequant = product[15:0];
        end
    endfunction

    // =========================================================================
    // 4:2:0 path — 2x2 Hadamard (CHROMA_FORMAT_IDC == 1)
    // =========================================================================
    generate if (CHROMA_FORMAT_IDC == 1) begin : gen_420

        // Forward 2x2 Hadamard (no division):
        // [d0 d1; d2 d3] -> [d0+d1+d2+d3, d0-d1+d2-d3; d0+d1-d2-d3, d0-d1-d2+d3]
        wire signed [CW:0] h0 = {dc_in_0[CW-1], dc_in_0} + {dc_in_1[CW-1], dc_in_1} + {dc_in_2[CW-1], dc_in_2} + {dc_in_3[CW-1], dc_in_3};
        wire signed [CW:0] h1 = {dc_in_0[CW-1], dc_in_0} - {dc_in_1[CW-1], dc_in_1} + {dc_in_2[CW-1], dc_in_2} - {dc_in_3[CW-1], dc_in_3};
        wire signed [CW:0] h2 = {dc_in_0[CW-1], dc_in_0} + {dc_in_1[CW-1], dc_in_1} - {dc_in_2[CW-1], dc_in_2} - {dc_in_3[CW-1], dc_in_3};
        wire signed [CW:0] h3 = {dc_in_0[CW-1], dc_in_0} - {dc_in_1[CW-1], dc_in_1} - {dc_in_2[CW-1], dc_in_2} + {dc_in_3[CW-1], dc_in_3};

        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                state <= S_IDLE;
                done <= 1'b0;
                dc_out_0 <= 16'sd0;
                dc_out_1 <= 16'sd0;
                dc_out_2 <= 16'sd0;
                dc_out_3 <= 16'sd0;
                dc_out_4 <= 16'sd0;
                dc_out_5 <= 16'sd0;
                dc_out_6 <= 16'sd0;
                dc_out_7 <= 16'sd0;
            end else begin
                done <= 1'b0;
                case (state)
                    S_IDLE: if (start) state <= S_EXEC;
                    S_EXEC: begin
                        if (!do_inverse) begin
                            // Forward: Hadamard then quantize
                            dc_out_0 <= fwd_quant(h0);
                            dc_out_1 <= fwd_quant(h1);
                            dc_out_2 <= fwd_quant(h2);
                            dc_out_3 <= fwd_quant(h3);
                        end else begin
                            begin : inv_block_420
                                reg signed [15:0] dq0, dq1, dq2, dq3;
                                reg signed [16:0] r0, r1, r2, r3;
                                dq0 = inv_dequant(dc_in_0);
                                dq1 = inv_dequant(dc_in_1);
                                dq2 = inv_dequant(dc_in_2);
                                dq3 = inv_dequant(dc_in_3);
                                r0 = ({dq0[15], dq0} + {dq1[15], dq1} + {dq2[15], dq2} + {dq3[15], dq3});
                                r1 = ({dq0[15], dq0} - {dq1[15], dq1} + {dq2[15], dq2} - {dq3[15], dq3});
                                r2 = ({dq0[15], dq0} + {dq1[15], dq1} - {dq2[15], dq2} - {dq3[15], dq3});
                                r3 = ({dq0[15], dq0} - {dq1[15], dq1} - {dq2[15], dq2} + {dq3[15], dq3});
                                // Divide by 2 (arithmetic right shift)
                                dc_out_0 <= (r0 + (r0[16] ? 17'sd1 : 17'sd0)) >>> 1;
                                dc_out_1 <= (r1 + (r1[16] ? 17'sd1 : 17'sd0)) >>> 1;
                                dc_out_2 <= (r2 + (r2[16] ? 17'sd1 : 17'sd0)) >>> 1;
                                dc_out_3 <= (r3 + (r3[16] ? 17'sd1 : 17'sd0)) >>> 1;
                            end
                        end
                        // Extra outputs unused for 4:2:0
                        dc_out_4 <= 16'sd0;
                        dc_out_5 <= 16'sd0;
                        dc_out_6 <= 16'sd0;
                        dc_out_7 <= 16'sd0;
                        state <= S_DONE;
                    end
                    S_DONE: begin
                        done <= 1'b1;
                        state <= S_IDLE;
                    end
                    default: state <= S_IDLE;
                endcase
            end
        end

    end else if (CHROMA_FORMAT_IDC == 2) begin : gen_422

        // =====================================================================
        // 4:2:2 path — 2x4 Hadamard (H.264 spec 8.5.11.2)
        // =====================================================================
        // Input mapping: 2 columns x 4 rows
        //   [d0 d1]  row 0
        //   [d2 d3]  row 1
        //   [d4 d5]  row 2
        //   [d6 d7]  row 3

        // Sign-extend inputs to CW+1 bits for intermediate sums
        wire signed [CW:0] d0_ext = {dc_in_0[CW-1], dc_in_0};
        wire signed [CW:0] d1_ext = {dc_in_1[CW-1], dc_in_1};
        wire signed [CW:0] d2_ext = {dc_in_2[CW-1], dc_in_2};
        wire signed [CW:0] d3_ext = {dc_in_3[CW-1], dc_in_3};
        wire signed [CW:0] d4_ext = {dc_in_4[CW-1], dc_in_4};
        wire signed [CW:0] d5_ext = {dc_in_5[CW-1], dc_in_5};
        wire signed [CW:0] d6_ext = {dc_in_6[CW-1], dc_in_6};
        wire signed [CW:0] d7_ext = {dc_in_7[CW-1], dc_in_7};

        // Step 1: Column transform — 4-point Hadamard on each column
        // Column 0 (d0, d2, d4, d6):
        wire signed [CW+1:0] e0_c0 = {d0_ext[CW], d0_ext} + {d2_ext[CW], d2_ext} + {d4_ext[CW], d4_ext} + {d6_ext[CW], d6_ext};
        wire signed [CW+1:0] e1_c0 = {d0_ext[CW], d0_ext} - {d2_ext[CW], d2_ext} + {d4_ext[CW], d4_ext} - {d6_ext[CW], d6_ext};
        wire signed [CW+1:0] e2_c0 = {d0_ext[CW], d0_ext} + {d2_ext[CW], d2_ext} - {d4_ext[CW], d4_ext} - {d6_ext[CW], d6_ext};
        wire signed [CW+1:0] e3_c0 = {d0_ext[CW], d0_ext} - {d2_ext[CW], d2_ext} - {d4_ext[CW], d4_ext} + {d6_ext[CW], d6_ext};

        // Column 1 (d1, d3, d5, d7):
        wire signed [CW+1:0] e0_c1 = {d1_ext[CW], d1_ext} + {d3_ext[CW], d3_ext} + {d5_ext[CW], d5_ext} + {d7_ext[CW], d7_ext};
        wire signed [CW+1:0] e1_c1 = {d1_ext[CW], d1_ext} - {d3_ext[CW], d3_ext} + {d5_ext[CW], d5_ext} - {d7_ext[CW], d7_ext};
        wire signed [CW+1:0] e2_c1 = {d1_ext[CW], d1_ext} + {d3_ext[CW], d3_ext} - {d5_ext[CW], d5_ext} - {d7_ext[CW], d7_ext};
        wire signed [CW+1:0] e3_c1 = {d1_ext[CW], d1_ext} - {d3_ext[CW], d3_ext} - {d5_ext[CW], d5_ext} + {d7_ext[CW], d7_ext};

        // Step 2: Row transform — 2-point Hadamard on each row
        // f[r,0] = e[r,0] + e[r,1],  f[r,1] = e[r,0] - e[r,1]
        // Sign-extend to CW+2 to avoid overflow from the addition
        wire signed [CW+2:0] f0_c0 = {e0_c0[CW+1], e0_c0} + {e0_c1[CW+1], e0_c1};
        wire signed [CW+2:0] f0_c1 = {e0_c0[CW+1], e0_c0} - {e0_c1[CW+1], e0_c1};
        wire signed [CW+2:0] f1_c0 = {e1_c0[CW+1], e1_c0} + {e1_c1[CW+1], e1_c1};
        wire signed [CW+2:0] f1_c1 = {e1_c0[CW+1], e1_c0} - {e1_c1[CW+1], e1_c1};
        wire signed [CW+2:0] f2_c0 = {e2_c0[CW+1], e2_c0} + {e2_c1[CW+1], e2_c1};
        wire signed [CW+2:0] f2_c1 = {e2_c0[CW+1], e2_c0} - {e2_c1[CW+1], e2_c1};
        wire signed [CW+2:0] f3_c0 = {e3_c0[CW+1], e3_c0} + {e3_c1[CW+1], e3_c1};
        wire signed [CW+2:0] f3_c1 = {e3_c0[CW+1], e3_c0} - {e3_c1[CW+1], e3_c1};

        // Truncate forward Hadamard outputs to CW+1 bits for fwd_quant input
        // fwd_quant takes signed [CW:0], so we take the lower CW+1 bits
        wire signed [CW:0] fh0 = f0_c0[CW:0];
        wire signed [CW:0] fh1 = f0_c1[CW:0];
        wire signed [CW:0] fh2 = f1_c0[CW:0];
        wire signed [CW:0] fh3 = f1_c1[CW:0];
        wire signed [CW:0] fh4 = f2_c0[CW:0];
        wire signed [CW:0] fh5 = f2_c1[CW:0];
        wire signed [CW:0] fh6 = f3_c0[CW:0];
        wire signed [CW:0] fh7 = f3_c1[CW:0];

        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                state <= S_IDLE;
                done <= 1'b0;
                dc_out_0 <= 16'sd0;
                dc_out_1 <= 16'sd0;
                dc_out_2 <= 16'sd0;
                dc_out_3 <= 16'sd0;
                dc_out_4 <= 16'sd0;
                dc_out_5 <= 16'sd0;
                dc_out_6 <= 16'sd0;
                dc_out_7 <= 16'sd0;
            end else begin
                done <= 1'b0;
                case (state)
                    S_IDLE: if (start) state <= S_EXEC;
                    S_EXEC: begin
                        if (!do_inverse) begin
                            // Forward: 2x4 Hadamard then quantize
                            // Output order: row-major [row0col0, row0col1, row1col0, ...]
                            dc_out_0 <= fwd_quant(fh0);
                            dc_out_1 <= fwd_quant(fh1);
                            dc_out_2 <= fwd_quant(fh2);
                            dc_out_3 <= fwd_quant(fh3);
                            dc_out_4 <= fwd_quant(fh4);
                            dc_out_5 <= fwd_quant(fh5);
                            dc_out_6 <= fwd_quant(fh6);
                            dc_out_7 <= fwd_quant(fh7);
                        end else begin
                            begin : inv_block_422
                                // Inverse: dequant, then row inverse, then column inverse
                                reg signed [15:0] dq0, dq1, dq2, dq3;
                                reg signed [15:0] dq4, dq5, dq6, dq7;

                                // Step 1: Inverse quantize all 8 coefficients
                                dq0 = inv_dequant(dc_in_0);
                                dq1 = inv_dequant(dc_in_1);
                                dq2 = inv_dequant(dc_in_2);
                                dq3 = inv_dequant(dc_in_3);
                                dq4 = inv_dequant(dc_in_4);
                                dq5 = inv_dequant(dc_in_5);
                                dq6 = inv_dequant(dc_in_6);
                                dq7 = inv_dequant(dc_in_7);

                                begin : inv_transform_422
                                    // Step 2: Row inverse — 2-point Hadamard on each row
                                    // Input layout (row-major): [dq0,dq1], [dq2,dq3], [dq4,dq5], [dq6,dq7]
                                    reg signed [16:0] g0_c0, g0_c1, g1_c0, g1_c1;
                                    reg signed [16:0] g2_c0, g2_c1, g3_c0, g3_c1;

                                    g0_c0 = {dq0[15], dq0} + {dq1[15], dq1};
                                    g0_c1 = {dq0[15], dq0} - {dq1[15], dq1};
                                    g1_c0 = {dq2[15], dq2} + {dq3[15], dq3};
                                    g1_c1 = {dq2[15], dq2} - {dq3[15], dq3};
                                    g2_c0 = {dq4[15], dq4} + {dq5[15], dq5};
                                    g2_c1 = {dq4[15], dq4} - {dq5[15], dq5};
                                    g3_c0 = {dq6[15], dq6} + {dq7[15], dq7};
                                    g3_c1 = {dq6[15], dq6} - {dq7[15], dq7};

                                    begin : inv_col_422
                                        // Step 3: Column inverse — 4-point Hadamard on each column
                                        reg signed [18:0] out0_c0, out0_c1, out1_c0, out1_c1;
                                        reg signed [18:0] out2_c0, out2_c1, out3_c0, out3_c1;

                                        // Column 0:
                                        out0_c0 = {g0_c0[16], g0_c0[16], g0_c0} + {g1_c0[16], g1_c0[16], g1_c0} + {g2_c0[16], g2_c0[16], g2_c0} + {g3_c0[16], g3_c0[16], g3_c0};
                                        out1_c0 = {g0_c0[16], g0_c0[16], g0_c0} - {g1_c0[16], g1_c0[16], g1_c0} + {g2_c0[16], g2_c0[16], g2_c0} - {g3_c0[16], g3_c0[16], g3_c0};
                                        out2_c0 = {g0_c0[16], g0_c0[16], g0_c0} + {g1_c0[16], g1_c0[16], g1_c0} - {g2_c0[16], g2_c0[16], g2_c0} - {g3_c0[16], g3_c0[16], g3_c0};
                                        out3_c0 = {g0_c0[16], g0_c0[16], g0_c0} - {g1_c0[16], g1_c0[16], g1_c0} - {g2_c0[16], g2_c0[16], g2_c0} + {g3_c0[16], g3_c0[16], g3_c0};

                                        // Column 1:
                                        out0_c1 = {g0_c1[16], g0_c1[16], g0_c1} + {g1_c1[16], g1_c1[16], g1_c1} + {g2_c1[16], g2_c1[16], g2_c1} + {g3_c1[16], g3_c1[16], g3_c1};
                                        out1_c1 = {g0_c1[16], g0_c1[16], g0_c1} - {g1_c1[16], g1_c1[16], g1_c1} + {g2_c1[16], g2_c1[16], g2_c1} - {g3_c1[16], g3_c1[16], g3_c1};
                                        out2_c1 = {g0_c1[16], g0_c1[16], g0_c1} + {g1_c1[16], g1_c1[16], g1_c1} - {g2_c1[16], g2_c1[16], g2_c1} - {g3_c1[16], g3_c1[16], g3_c1};
                                        out3_c1 = {g0_c1[16], g0_c1[16], g0_c1} - {g1_c1[16], g1_c1[16], g1_c1} - {g2_c1[16], g2_c1[16], g2_c1} + {g3_c1[16], g3_c1[16], g3_c1};

                                        // Divide by 2 (arithmetic right shift), output row-major
                                        dc_out_0 <= (out0_c0 + (out0_c0[18] ? 19'sd1 : 19'sd0)) >>> 1;
                                        dc_out_1 <= (out0_c1 + (out0_c1[18] ? 19'sd1 : 19'sd0)) >>> 1;
                                        dc_out_2 <= (out1_c0 + (out1_c0[18] ? 19'sd1 : 19'sd0)) >>> 1;
                                        dc_out_3 <= (out1_c1 + (out1_c1[18] ? 19'sd1 : 19'sd0)) >>> 1;
                                        dc_out_4 <= (out2_c0 + (out2_c0[18] ? 19'sd1 : 19'sd0)) >>> 1;
                                        dc_out_5 <= (out2_c1 + (out2_c1[18] ? 19'sd1 : 19'sd0)) >>> 1;
                                        dc_out_6 <= (out3_c0 + (out3_c0[18] ? 19'sd1 : 19'sd0)) >>> 1;
                                        dc_out_7 <= (out3_c1 + (out3_c1[18] ? 19'sd1 : 19'sd0)) >>> 1;
                                    end
                                end
                            end
                        end
                        state <= S_DONE;
                    end
                    S_DONE: begin
                        done <= 1'b1;
                        state <= S_IDLE;
                    end
                    default: state <= S_IDLE;
                endcase
            end
        end

    end endgenerate

endmodule
