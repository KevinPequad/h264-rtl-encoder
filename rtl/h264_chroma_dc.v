// h264_chroma_dc.v — 2x2 Hadamard Transform + Quantization for Chroma DC
// Forward: takes 4 DC values from 4x4 blocks, applies 2x2 Hadamard
// Quantization uses chroma DC formula: level = (|coeff| * MF + 2f) >> (qBits+1)
// For QP=26: MF=10082, qBits=19, f_intra=2^(14+4)/3=87381, 2f=174762
// So: level = (|coeff| * 10082 + 174762) >> 20
//
// Inverse: dequant then inverse Hadamard
// For QP=26: d = level * LevelScale(0,0) = level * 13
// Then: d << (QP/6 - 1) = d << 3  (for QP >= 6, chroma DC has extra /2)
// Inverse Hadamard output is (a+b+c+d)/2 etc.

module h264_chroma_dc (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    input  wire        do_inverse,  // 0=forward, 1=inverse
    output reg         done,

    // Forward: 4 DC values from transform output (position [0,0] of each 4x4)
    input  wire signed [15:0] dc_in_0,
    input  wire signed [15:0] dc_in_1,
    input  wire signed [15:0] dc_in_2,
    input  wire signed [15:0] dc_in_3,

    // Forward output: 4 quantized Hadamard coefficients
    output reg  signed [15:0] dc_out_0,
    output reg  signed [15:0] dc_out_1,
    output reg  signed [15:0] dc_out_2,
    output reg  signed [15:0] dc_out_3
);

    reg [1:0] state;
    localparam S_IDLE = 2'd0;
    localparam S_EXEC = 2'd1;
    localparam S_DONE = 2'd2;

    // Forward Hadamard (no division):
    // [a b; c d] -> [a+b+c+d, a-b+c-d; a+b-c-d, a-b-c+d]
    wire signed [16:0] h0 = {dc_in_0[15], dc_in_0} + {dc_in_1[15], dc_in_1} + {dc_in_2[15], dc_in_2} + {dc_in_3[15], dc_in_3};
    wire signed [16:0] h1 = {dc_in_0[15], dc_in_0} - {dc_in_1[15], dc_in_1} + {dc_in_2[15], dc_in_2} - {dc_in_3[15], dc_in_3};
    wire signed [16:0] h2 = {dc_in_0[15], dc_in_0} + {dc_in_1[15], dc_in_1} - {dc_in_2[15], dc_in_2} - {dc_in_3[15], dc_in_3};
    wire signed [16:0] h3 = {dc_in_0[15], dc_in_0} - {dc_in_1[15], dc_in_1} - {dc_in_2[15], dc_in_2} + {dc_in_3[15], dc_in_3};

    // Forward quantization for chroma DC
    // QP=26: MF[0][0]=10082, qBits=19, 2*f_intra = 2 * (2^18 / 3) = 174762
    // level = (|coeff| * 10082 + 174762) >> 20
    localparam [31:0] MF_00 = 32'd10082;
    localparam [31:0] F2_INTRA = 32'd174762;
    localparam QBITS_PLUS1 = 20;

    function signed [15:0] fwd_quant;
        input signed [16:0] val;
        reg [16:0] abs_val;
        reg sign;
        reg [39:0] product;
        reg [15:0] level;
        begin
            sign = val[16];
            abs_val = sign ? (~val[16:0] + 17'd1) : val[16:0];
            product = ({23'd0, abs_val} * MF_00) + {8'd0, F2_INTRA};
            level = product[QBITS_PLUS1 +: 16];
            fwd_quant = sign ? (~level + 16'd1) : level;
        end
    endfunction

    // Inverse dequantization for chroma DC
    // Same as AC inverse quant: d = level * LevelScale(0,0) << (QP/6)
    // For QP=26: d = level * 13 << 4 = level * 208
    // After Hadamard butterfly, divide by 2 gives: hadamard_sum * 208 / 2 = sum * 104
    // This matches openh264: WelsDequantIHadamard2x2Dc uses kuiMF = g_kuiDequantCoeff[QP][0] = 208
    //   result = (hadamard_sum * 208) >> 1
    function signed [15:0] inv_dequant;
        input signed [15:0] level;
        reg signed [31:0] product;
        begin
            // level * 13 << 4 = level * 208
            product = level * 16'sd208;
            inv_dequant = product[15:0];
        end
    endfunction

    // Inverse Hadamard: same as forward but divide by 2
    wire signed [16:0] ih0 = ({dc_in_0[15], dc_in_0} + {dc_in_1[15], dc_in_1} + {dc_in_2[15], dc_in_2} + {dc_in_3[15], dc_in_3});
    wire signed [16:0] ih1 = ({dc_in_0[15], dc_in_0} - {dc_in_1[15], dc_in_1} + {dc_in_2[15], dc_in_2} - {dc_in_3[15], dc_in_3});
    wire signed [16:0] ih2 = ({dc_in_0[15], dc_in_0} + {dc_in_1[15], dc_in_1} - {dc_in_2[15], dc_in_2} - {dc_in_3[15], dc_in_3});
    wire signed [16:0] ih3 = ({dc_in_0[15], dc_in_0} - {dc_in_1[15], dc_in_1} - {dc_in_2[15], dc_in_2} + {dc_in_3[15], dc_in_3});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            done <= 1'b0;
            dc_out_0 <= 16'sd0;
            dc_out_1 <= 16'sd0;
            dc_out_2 <= 16'sd0;
            dc_out_3 <= 16'sd0;
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
                        // Inverse: dequantize inputs then inverse Hadamard (divide by 2)
                        // Inputs are quantized Hadamard coeffs
                        // Step 1: dequant each
                        // Step 2: inverse Hadamard (/2)
                        // We use ih* which takes dc_in as input, so caller must
                        // provide dequantized values. We'll do dequant + Hadamard here.
                        // Actually, let's do it in one shot:
                        // First dequant the 4 inputs, then the Hadamard wires use dc_in
                        // which are the raw inputs. So we need to pre-dequant.
                        // Solution: do dequant in this cycle, Hadamard next cycle.
                        // But to keep it simple, let's just compute inline:
                        begin : inv_block
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

endmodule
