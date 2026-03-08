// h264_quantize.v — Forward Quantization for QP=26
// level = (|coeff| * MF + f) >> 19
// QP=26: QBITS=19, F_INTRA=174763
// MF values for QP%6=2: Index 0=10082, Index 1=4194, Index 2=6554

module h264_quantize #(
    parameter BIT_DEPTH = 8
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    output reg         done,

    // Input: 4x4 transform coefficients (16 * CW-bit signed)
    input  wire [16*CW-1:0] in_flat,

    // Output: 4x4 quantized levels (16 * 16 bits = 256 bits)
    output reg  [255:0] quant_flat
);

    localparam CW = BIT_DEPTH + 8;
    localparam QBITS = 19;
    localparam [31:0] F_INTRA = 32'd174763;

    reg [2:0] state;
    localparam S_IDLE  = 3'd0;
    localparam S_QUANT = 3'd1;
    localparam S_DONE  = 3'd2;

    reg [3:0] idx;

    function [15:0] get_mf;
        input [3:0] pos;
        begin
            if (pos[2] == 1'b0 && pos[0] == 1'b0)
                get_mf = 16'd10082; // Index 0
            else if (pos[2] == 1'b1 && pos[0] == 1'b1)
                get_mf = 16'd4194;  // Index 1
            else
                get_mf = 16'd6554;  // Index 2
        end
    endfunction

    reg signed [CW-1:0] coeff;
    reg [CW-1:0] coeff_abs;
    reg          coeff_sign;
    reg [CW+15:0] product;  // coeff_abs * MF (CW + 16 bits)
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
                    coeff      = inp[idx];
                    coeff_sign = coeff[CW-1];
                    coeff_abs  = coeff_sign ? (~coeff + {{(CW-1){1'b0}}, 1'b1}) : coeff;
                    product    = ({{16{1'b0}}, coeff_abs} * {{CW{1'b0}}, get_mf(idx)}) + {{(CW-16){1'b0}}, F_INTRA};
                    level      = product[QBITS +: 16];
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
