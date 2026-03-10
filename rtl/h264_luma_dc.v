module h264_luma_dc #(
    parameter BIT_DEPTH = 8
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 start,
    input  wire                 do_inverse,
    output reg                  done,
    input  wire [16*CW-1:0]     dc_in_flat,
    output reg  [16*16-1:0]     dc_out_flat
);

    localparam CW = BIT_DEPTH + 8;
    localparam QBITS = 19;
    localparam [31:0] F_INTRA = 32'd174763;
    localparam signed [15:0] LEVEL_SCALE_DC = 16'sd13;

    localparam S_IDLE = 2'd0;
    localparam S_EXEC = 2'd1;
    localparam S_DONE = 2'd2;

    reg [1:0] state;

    wire signed [CW-1:0] din [0:15];

    genvar gi;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : unpack_in
            assign din[gi] = $signed(dc_in_flat[gi*CW +: CW]);
        end
    endgenerate

    function signed [15:0] fwd_quant;
        input signed [CW+4:0] val;
        reg [CW+4:0] abs_val;
        reg sign;
        reg [CW+20:0] product;
        reg [15:0] level;
        begin
            sign = val[CW+4];
            abs_val = sign ? (~val + {{(CW+4){1'b0}}, 1'b1}) : val;
            product = ({{16{1'b0}}, abs_val} * 16'd10082) + F_INTRA;
            level = product[QBITS +: 16];
            fwd_quant = sign ? (~level + 16'd1) : level;
        end
    endfunction

    function signed [15:0] scale_dc;
        input signed [CW+3:0] val;
        reg signed [CW+19:0] product;
        begin
            product = val * LEVEL_SCALE_DC;
            scale_dc = (product + 22'sd2) >>> 2;
        end
    endfunction

    wire signed [CW+1:0] r00 = {din[0][CW-1], din[0]} + {din[1][CW-1], din[1]} + {din[2][CW-1], din[2]} + {din[3][CW-1], din[3]};
    wire signed [CW+1:0] r01 = {din[0][CW-1], din[0]} + {din[1][CW-1], din[1]} - {din[2][CW-1], din[2]} - {din[3][CW-1], din[3]};
    wire signed [CW+1:0] r02 = {din[0][CW-1], din[0]} - {din[1][CW-1], din[1]} - {din[2][CW-1], din[2]} + {din[3][CW-1], din[3]};
    wire signed [CW+1:0] r03 = {din[0][CW-1], din[0]} - {din[1][CW-1], din[1]} + {din[2][CW-1], din[2]} - {din[3][CW-1], din[3]};

    wire signed [CW+1:0] r10 = {din[4][CW-1], din[4]} + {din[5][CW-1], din[5]} + {din[6][CW-1], din[6]} + {din[7][CW-1], din[7]};
    wire signed [CW+1:0] r11 = {din[4][CW-1], din[4]} + {din[5][CW-1], din[5]} - {din[6][CW-1], din[6]} - {din[7][CW-1], din[7]};
    wire signed [CW+1:0] r12 = {din[4][CW-1], din[4]} - {din[5][CW-1], din[5]} - {din[6][CW-1], din[6]} + {din[7][CW-1], din[7]};
    wire signed [CW+1:0] r13 = {din[4][CW-1], din[4]} - {din[5][CW-1], din[5]} + {din[6][CW-1], din[6]} - {din[7][CW-1], din[7]};

    wire signed [CW+1:0] r20 = {din[8][CW-1], din[8]} + {din[9][CW-1], din[9]} + {din[10][CW-1], din[10]} + {din[11][CW-1], din[11]};
    wire signed [CW+1:0] r21 = {din[8][CW-1], din[8]} + {din[9][CW-1], din[9]} - {din[10][CW-1], din[10]} - {din[11][CW-1], din[11]};
    wire signed [CW+1:0] r22 = {din[8][CW-1], din[8]} - {din[9][CW-1], din[9]} - {din[10][CW-1], din[10]} + {din[11][CW-1], din[11]};
    wire signed [CW+1:0] r23 = {din[8][CW-1], din[8]} - {din[9][CW-1], din[9]} + {din[10][CW-1], din[10]} - {din[11][CW-1], din[11]};

    wire signed [CW+1:0] r30 = {din[12][CW-1], din[12]} + {din[13][CW-1], din[13]} + {din[14][CW-1], din[14]} + {din[15][CW-1], din[15]};
    wire signed [CW+1:0] r31 = {din[12][CW-1], din[12]} + {din[13][CW-1], din[13]} - {din[14][CW-1], din[14]} - {din[15][CW-1], din[15]};
    wire signed [CW+1:0] r32 = {din[12][CW-1], din[12]} - {din[13][CW-1], din[13]} - {din[14][CW-1], din[14]} + {din[15][CW-1], din[15]};
    wire signed [CW+1:0] r33 = {din[12][CW-1], din[12]} - {din[13][CW-1], din[13]} + {din[14][CW-1], din[14]} - {din[15][CW-1], din[15]};

    wire signed [CW+3:0] h00 = {r00[CW+1], r00} + {r10[CW+1], r10} + {r20[CW+1], r20} + {r30[CW+1], r30};
    wire signed [CW+3:0] h01 = {r01[CW+1], r01} + {r11[CW+1], r11} + {r21[CW+1], r21} + {r31[CW+1], r31};
    wire signed [CW+3:0] h02 = {r02[CW+1], r02} + {r12[CW+1], r12} + {r22[CW+1], r22} + {r32[CW+1], r32};
    wire signed [CW+3:0] h03 = {r03[CW+1], r03} + {r13[CW+1], r13} + {r23[CW+1], r23} + {r33[CW+1], r33};

    wire signed [CW+3:0] h10 = {r00[CW+1], r00} + {r10[CW+1], r10} - {r20[CW+1], r20} - {r30[CW+1], r30};
    wire signed [CW+3:0] h11 = {r01[CW+1], r01} + {r11[CW+1], r11} - {r21[CW+1], r21} - {r31[CW+1], r31};
    wire signed [CW+3:0] h12 = {r02[CW+1], r02} + {r12[CW+1], r12} - {r22[CW+1], r22} - {r32[CW+1], r32};
    wire signed [CW+3:0] h13 = {r03[CW+1], r03} + {r13[CW+1], r13} - {r23[CW+1], r23} - {r33[CW+1], r33};

    wire signed [CW+3:0] h20 = {r00[CW+1], r00} - {r10[CW+1], r10} - {r20[CW+1], r20} + {r30[CW+1], r30};
    wire signed [CW+3:0] h21 = {r01[CW+1], r01} - {r11[CW+1], r11} - {r21[CW+1], r21} + {r31[CW+1], r31};
    wire signed [CW+3:0] h22 = {r02[CW+1], r02} - {r12[CW+1], r12} - {r22[CW+1], r22} + {r32[CW+1], r32};
    wire signed [CW+3:0] h23 = {r03[CW+1], r03} - {r13[CW+1], r13} - {r23[CW+1], r23} + {r33[CW+1], r33};

    wire signed [CW+3:0] h30 = {r00[CW+1], r00} - {r10[CW+1], r10} + {r20[CW+1], r20} - {r30[CW+1], r30};
    wire signed [CW+3:0] h31 = {r01[CW+1], r01} - {r11[CW+1], r11} + {r21[CW+1], r21} - {r31[CW+1], r31};
    wire signed [CW+3:0] h32 = {r02[CW+1], r02} - {r12[CW+1], r12} + {r22[CW+1], r22} - {r32[CW+1], r32};
    wire signed [CW+3:0] h33 = {r03[CW+1], r03} - {r13[CW+1], r13} + {r23[CW+1], r23} - {r33[CW+1], r33};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            done <= 1'b0;
            dc_out_flat <= 256'd0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: if (start) state <= S_EXEC;

                S_EXEC: begin
                    if (!do_inverse) begin
                        dc_out_flat[0*16 +: 16] <= fwd_quant(h00);
                        dc_out_flat[1*16 +: 16] <= fwd_quant(h01);
                        dc_out_flat[2*16 +: 16] <= fwd_quant(h02);
                        dc_out_flat[3*16 +: 16] <= fwd_quant(h03);
                        dc_out_flat[4*16 +: 16] <= fwd_quant(h10);
                        dc_out_flat[5*16 +: 16] <= fwd_quant(h11);
                        dc_out_flat[6*16 +: 16] <= fwd_quant(h12);
                        dc_out_flat[7*16 +: 16] <= fwd_quant(h13);
                        dc_out_flat[8*16 +: 16] <= fwd_quant(h20);
                        dc_out_flat[9*16 +: 16] <= fwd_quant(h21);
                        dc_out_flat[10*16 +: 16] <= fwd_quant(h22);
                        dc_out_flat[11*16 +: 16] <= fwd_quant(h23);
                        dc_out_flat[12*16 +: 16] <= fwd_quant(h30);
                        dc_out_flat[13*16 +: 16] <= fwd_quant(h31);
                        dc_out_flat[14*16 +: 16] <= fwd_quant(h32);
                        dc_out_flat[15*16 +: 16] <= fwd_quant(h33);
                    end else begin
                        dc_out_flat[0*16 +: 16] <= scale_dc(h00);
                        dc_out_flat[1*16 +: 16] <= scale_dc(h01);
                        dc_out_flat[2*16 +: 16] <= scale_dc(h02);
                        dc_out_flat[3*16 +: 16] <= scale_dc(h03);
                        dc_out_flat[4*16 +: 16] <= scale_dc(h10);
                        dc_out_flat[5*16 +: 16] <= scale_dc(h11);
                        dc_out_flat[6*16 +: 16] <= scale_dc(h12);
                        dc_out_flat[7*16 +: 16] <= scale_dc(h13);
                        dc_out_flat[8*16 +: 16] <= scale_dc(h20);
                        dc_out_flat[9*16 +: 16] <= scale_dc(h21);
                        dc_out_flat[10*16 +: 16] <= scale_dc(h22);
                        dc_out_flat[11*16 +: 16] <= scale_dc(h23);
                        dc_out_flat[12*16 +: 16] <= scale_dc(h30);
                        dc_out_flat[13*16 +: 16] <= scale_dc(h31);
                        dc_out_flat[14*16 +: 16] <= scale_dc(h32);
                        dc_out_flat[15*16 +: 16] <= scale_dc(h33);
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
