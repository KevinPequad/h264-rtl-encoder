// h264_inverse_quant.v — Inverse Quantization for the configurable-QP RTL path.
// The effective QP must include QpBdOffset so the encoder reconstruction path
// matches the decoder's derived QP at high bit depth.

module h264_inverse_quant #(
    parameter BIT_DEPTH = 8
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    output reg         done,

    // Base QP before QpBdOffset; valid range 0..51.
    input  wire [5:0]  qp,

    // Input: 4x4 quantized levels (256 bits = 16 * 16-bit signed)
    input  wire [255:0] quant_flat,

    // Output: 4x4 dequantized transform coefficients (16 * CW-bit signed)
    output reg  [16*CW-1:0] dequant_flat
);

    localparam CW = BIT_DEPTH + 8;
    localparam integer QP_BD_OFFSET = 6 * (BIT_DEPTH - 8);

    reg [2:0] state;
    localparam S_IDLE    = 3'd0;
    localparam S_DEQUANT = 3'd1;
    localparam S_DONE    = 3'd2;

    reg [3:0] idx;

    reg [6:0] qpe;
    reg [2:0] qpm;
    reg signed [5:0] iq_shift;

    function signed [15:0] get_scale;
        input [3:0] pos;
        begin
            case (qpm)
                0: begin
                    if (pos[2] == 1'b0 && pos[0] == 1'b0)
                        get_scale = 16'sd10;
                    else if (pos[2] == 1'b1 && pos[0] == 1'b1)
                        get_scale = 16'sd16;
                    else
                        get_scale = 16'sd13;
                end
                1: begin
                    if (pos[2] == 1'b0 && pos[0] == 1'b0)
                        get_scale = 16'sd11;
                    else if (pos[2] == 1'b1 && pos[0] == 1'b1)
                        get_scale = 16'sd18;
                    else
                        get_scale = 16'sd14;
                end
                2: begin
                    if (pos[2] == 1'b0 && pos[0] == 1'b0)
                        get_scale = 16'sd13;
                    else if (pos[2] == 1'b1 && pos[0] == 1'b1)
                        get_scale = 16'sd20;
                    else
                        get_scale = 16'sd16;
                end
                3: begin
                    if (pos[2] == 1'b0 && pos[0] == 1'b0)
                        get_scale = 16'sd14;
                    else if (pos[2] == 1'b1 && pos[0] == 1'b1)
                        get_scale = 16'sd23;
                    else
                        get_scale = 16'sd18;
                end
                4: begin
                    if (pos[2] == 1'b0 && pos[0] == 1'b0)
                        get_scale = 16'sd16;
                    else if (pos[2] == 1'b1 && pos[0] == 1'b1)
                        get_scale = 16'sd25;
                    else
                        get_scale = 16'sd20;
                end
                default: begin
                    if (pos[2] == 1'b0 && pos[0] == 1'b0)
                        get_scale = 16'sd18;
                    else if (pos[2] == 1'b1 && pos[0] == 1'b1)
                        get_scale = 16'sd29;
                    else
                        get_scale = 16'sd23;
                end
            endcase
        end
    endfunction

    reg signed [15:0] level;
    reg signed [15:0] scale;
    reg signed [31:0] product;
    reg signed [47:0] scaled;
    reg signed [31:0] round_bias;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            done         <= 1'b0;
            idx          <= 4'd0;
            dequant_flat <= {(16*CW){1'b0}};
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (start) begin
                        state <= S_DEQUANT;
                        idx   <= 4'd0;
                    end
                end

                // verilator lint_off BLKSEQ
                S_DEQUANT: begin
                    qpe      = {1'b0, qp} + QP_BD_OFFSET;
                    qpm      = qpe % 7'd6;
                    iq_shift = $signed({1'b0,(qpe / 7'd6)}) - 6'sd4;
                    level    = $signed(quant_flat[idx*16 +: 16]);
                    scale    = get_scale(idx);
                    product  = level * (scale <<< 4);
                    if (iq_shift >= 0) begin
                        scaled = product <<< iq_shift;
                    end else begin
                        round_bias = 32'sd1 <<< ((-iq_shift) - 1);
                        scaled = (product + round_bias) >>> (-iq_shift);
                    end
                // verilator lint_on BLKSEQ
                    dequant_flat[idx*CW +: CW] <= scaled[CW-1:0];

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
