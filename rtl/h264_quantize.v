// h264_quantize.v — Forward Quantization for a configurable intra/inter QP.
// The effective QP must include the H.264 high-bit-depth QpBdOffset so the
// RTL reconstruction math matches what a standards-compliant decoder derives
// from SPS/PPS when BIT_DEPTH > 8.

module h264_quantize #(
    parameter BIT_DEPTH = 8
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    output reg         done,

    // Base QP before QpBdOffset; valid range 0..51.
    input  wire [5:0]  qp,

    // Input: 4x4 transform coefficients (16 * CW-bit signed)
    input  wire [16*CW-1:0] in_flat,

    // Output: 4x4 quantized levels (16 * 16 bits = 256 bits)
    output reg  [255:0] quant_flat
);

    localparam CW = BIT_DEPTH + 8;
    localparam integer QP_BD_OFFSET = 6 * (BIT_DEPTH - 8);

    reg [2:0] state;
    localparam S_IDLE  = 3'd0;
    localparam S_QUANT = 3'd1;
    localparam S_DONE  = 3'd2;

    reg [3:0] idx;

    reg [6:0] qpe;
    reg [2:0] qpm;
    reg [4:0] qbits;
    reg [31:0] f_intra;

    function [15:0] get_mf;
        input [3:0] pos;
        begin
            case (qpm)
                0: begin
                    if (pos[2] == 1'b0 && pos[0] == 1'b0)
                        get_mf = 16'd13107;
                    else if (pos[2] == 1'b1 && pos[0] == 1'b1)
                        get_mf = 16'd5243;
                    else
                        get_mf = 16'd8066;
                end
                1: begin
                    if (pos[2] == 1'b0 && pos[0] == 1'b0)
                        get_mf = 16'd11916;
                    else if (pos[2] == 1'b1 && pos[0] == 1'b1)
                        get_mf = 16'd4660;
                    else
                        get_mf = 16'd7490;
                end
                2: begin
                    if (pos[2] == 1'b0 && pos[0] == 1'b0)
                        get_mf = 16'd10082;
                    else if (pos[2] == 1'b1 && pos[0] == 1'b1)
                        get_mf = 16'd4194;
                    else
                        get_mf = 16'd6554;
                end
                3: begin
                    if (pos[2] == 1'b0 && pos[0] == 1'b0)
                        get_mf = 16'd9362;
                    else if (pos[2] == 1'b1 && pos[0] == 1'b1)
                        get_mf = 16'd3647;
                    else
                        get_mf = 16'd5825;
                end
                4: begin
                    if (pos[2] == 1'b0 && pos[0] == 1'b0)
                        get_mf = 16'd8192;
                    else if (pos[2] == 1'b1 && pos[0] == 1'b1)
                        get_mf = 16'd3355;
                    else
                        get_mf = 16'd5243;
                end
                default: begin
                    if (pos[2] == 1'b0 && pos[0] == 1'b0)
                        get_mf = 16'd7282;
                    else if (pos[2] == 1'b1 && pos[0] == 1'b1)
                        get_mf = 16'd2893;
                    else
                        get_mf = 16'd4559;
                end
            endcase
        end
    endfunction

    reg signed [CW-1:0] coeff;
    reg [CW-1:0] coeff_abs;
    reg          coeff_sign;
    reg [47:0] product;
    reg [15:0] level;

    // Unpack inputs
    wire signed [CW-1:0] inp [0:15];
    genvar gi;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : unpack
            assign inp[gi] = $signed(in_flat[gi*CW +: CW]);
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            done       <= 1'b0;
            idx        <= 4'd0;
            quant_flat <= 256'd0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (start) begin
                        state <= S_QUANT;
                        idx   <= 4'd0;
                    end
                end

                // verilator lint_off BLKSEQ
                S_QUANT: begin
                    qpe        = {1'b0, qp} + QP_BD_OFFSET;
                    qpm        = qpe % 7'd6;
                    qbits      = 5'd15 + (qpe / 7'd6);
                    f_intra    = ((32'd1 << qbits) + 32'd1) / 32'd3;
                    coeff      = inp[idx];
                    coeff_sign = coeff[CW-1];
                    coeff_abs  = coeff_sign ? (~coeff + {{(CW-1){1'b0}}, 1'b1}) : coeff;
                    product    = ({{32{1'b0}}, coeff_abs} * get_mf(idx)) + f_intra;
                    level      = product >> qbits;
                // verilator lint_on BLKSEQ

                    quant_flat[idx*16 +: 16] <= coeff_sign ? (~level + 16'd1) : level;

                    if (idx == 4'd15)
                        state <= S_DONE;
                    else
                        idx <= idx + 4'd1;
                end

                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
