// h264_inverse_quant.v — Inverse Quantization
// For QP=26: QP/6=4, QP%6=2
// H.264 spec 8.5.8: d_ij = (level_ij * LevelScale(QP%6, i, j)) << (QP/6)
// For QP=26, QP/6=4, so shift is << 4.

module h264_inverse_quant (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    output reg         done,

    // Input: 4x4 quantized levels (256 bits = 16 * 16-bit signed)
    input  wire [255:0] quant_flat,

    // Output: 4x4 dequantized transform coefficients (256 bits)
    output reg  [255:0] dequant_flat
);

    reg [2:0] state;
    localparam S_IDLE    = 3'd0;
    localparam S_DEQUANT = 3'd1;
    localparam S_DONE    = 3'd2;

    reg [3:0] idx;

    function signed [15:0] get_scale;
        input [3:0] pos;
        begin
            if (pos[2] == 1'b0 && pos[0] == 1'b0)
                get_scale = 16'sd13; // Index 0
            else if (pos[2] == 1'b1 && pos[0] == 1'b1)
                get_scale = 16'sd20; // Index 1
            else
                get_scale = 16'sd16; // Index 2
        end
    endfunction

    reg signed [15:0] level;
    reg signed [15:0] scale;
    reg signed [31:0] product;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            done        <= 1'b0;
            idx         <= 4'd0;
            dequant_flat <= 256'd0;
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
                    level   = $signed(quant_flat[idx*16 +: 16]);
                    scale   = get_scale(idx);
                    product = level * scale;
                // verilator lint_on BLKSEQ
                    dequant_flat[idx*16 +: 16] <= (product[15:0] << 4);

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
