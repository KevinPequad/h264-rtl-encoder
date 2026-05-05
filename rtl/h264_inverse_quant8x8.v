// h264_inverse_quant8x8.v — standalone H.264 8x8 inverse quantizer.
// Default flat scaling uses x264 common/set.c dequant8_scale and common/quant.c dequant_8x8.

module h264_inverse_quant8x8 #(
    parameter BIT_DEPTH = 8,
    parameter QW = 32
) (
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    output reg  done,
    input  wire [5:0] qp,
    input  wire [64*QW-1:0] quant_flat,
    output reg  [64*CW-1:0] dequant_flat
);
    localparam CW = BIT_DEPTH + 14;
    localparam integer QP_BD_OFFSET = 6 * (BIT_DEPTH - 8);

    function [2:0] qclass;
        input [5:0] pos;
        reg [3:0] key;
        begin
            key = ((pos >> 1) & 4'd12) | (pos & 4'd3);
            case (key)
                4'd0: qclass=3'd0; 4'd1: qclass=3'd3; 4'd2: qclass=3'd4; 4'd3: qclass=3'd3;
                4'd4: qclass=3'd3; 4'd5: qclass=3'd1; 4'd6: qclass=3'd5; 4'd7: qclass=3'd1;
                4'd8: qclass=3'd4; 4'd9: qclass=3'd5; 4'd10:qclass=3'd2; 4'd11:qclass=3'd5;
                4'd12:qclass=3'd3; 4'd13:qclass=3'd1; 4'd14:qclass=3'd5; default:qclass=3'd1;
            endcase
        end
    endfunction

    function signed [15:0] scale8;
        input [2:0] qm, cls;
        begin
            case (qm)
                3'd0: case(cls) 3'd0:scale8=16'sd20;3'd1:scale8=16'sd18;3'd2:scale8=16'sd32;3'd3:scale8=16'sd19;3'd4:scale8=16'sd25;default:scale8=16'sd24; endcase
                3'd1: case(cls) 3'd0:scale8=16'sd22;3'd1:scale8=16'sd19;3'd2:scale8=16'sd35;3'd3:scale8=16'sd21;3'd4:scale8=16'sd28;default:scale8=16'sd26; endcase
                3'd2: case(cls) 3'd0:scale8=16'sd26;3'd1:scale8=16'sd23;3'd2:scale8=16'sd42;3'd3:scale8=16'sd24;3'd4:scale8=16'sd33;default:scale8=16'sd31; endcase
                3'd3: case(cls) 3'd0:scale8=16'sd28;3'd1:scale8=16'sd25;3'd2:scale8=16'sd45;3'd3:scale8=16'sd26;3'd4:scale8=16'sd35;default:scale8=16'sd33; endcase
                3'd4: case(cls) 3'd0:scale8=16'sd32;3'd1:scale8=16'sd28;3'd2:scale8=16'sd51;3'd3:scale8=16'sd30;3'd4:scale8=16'sd40;default:scale8=16'sd38; endcase
                default: case(cls) 3'd0:scale8=16'sd36;3'd1:scale8=16'sd32;3'd2:scale8=16'sd58;3'd3:scale8=16'sd34;3'd4:scale8=16'sd46;default:scale8=16'sd43; endcase
            endcase
        end
    endfunction

    integer i;
    reg [6:0] qpe;
    reg [2:0] qpm;
    reg signed [5:0] sh;
    reg signed [QW-1:0] level;
    reg signed [63:0] prod, scaled, rbias;
    reg done_pending;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done <= 1'b0; done_pending <= 1'b0; dequant_flat <= {(64*CW){1'b0}};
        end else begin
            done <= done_pending;
            done_pending <= start;
            if (start) begin
                qpe = {1'b0, qp} + QP_BD_OFFSET;
                qpm = qpe % 7'd6;
                sh = $signed({1'b0,(qpe / 7'd6)}) - 6'sd6;
                for (i = 0; i < 64; i = i + 1) begin
                    level = $signed(quant_flat[i*QW +: QW]);
                    prod = level * (scale8(qpm, qclass(i[5:0])) <<< 4);
                    if (sh >= 0) scaled = prod <<< sh;
                    else begin
                        rbias = 64'sd1 <<< ((-sh) - 1);
                        scaled = (prod + rbias) >>> (-sh);
                    end
                    dequant_flat[i*CW +: CW] <= scaled[CW-1:0];
                end
            end
        end
    end
endmodule
