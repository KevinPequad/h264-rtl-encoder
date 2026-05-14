// h264_quantize8x8.v — standalone H.264 8x8 forward quantizer.
// Default flat scaling uses x264 common/set.c quant8_scale classes.

module h264_quantize8x8 #(
    parameter BIT_DEPTH = 8,
    parameter QW = 32
) (
    input  wire clk,
    input  wire rst_n,
    input  wire start,
    output reg  done,
    input  wire [5:0] qp,
    input  wire [64*CW-1:0] in_flat,
    output reg  [64*QW-1:0] quant_flat
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

    function [15:0] mf8;
        input [2:0] qm, cls;
        begin
            case (qm)
                3'd0: case(cls) 3'd0:mf8=16'd13107;3'd1:mf8=16'd11428;3'd2:mf8=16'd20972;3'd3:mf8=16'd12222;3'd4:mf8=16'd16777;default:mf8=16'd15481; endcase
                3'd1: case(cls) 3'd0:mf8=16'd11916;3'd1:mf8=16'd10826;3'd2:mf8=16'd19174;3'd3:mf8=16'd11058;3'd4:mf8=16'd14980;default:mf8=16'd14290; endcase
                3'd2: case(cls) 3'd0:mf8=16'd10082;3'd1:mf8=16'd8943;3'd2:mf8=16'd15978;3'd3:mf8=16'd9675;3'd4:mf8=16'd12710;default:mf8=16'd11985; endcase
                3'd3: case(cls) 3'd0:mf8=16'd9362;3'd1:mf8=16'd8228;3'd2:mf8=16'd14913;3'd3:mf8=16'd8931;3'd4:mf8=16'd11984;default:mf8=16'd11259; endcase
                3'd4: case(cls) 3'd0:mf8=16'd8192;3'd1:mf8=16'd7346;3'd2:mf8=16'd13159;3'd3:mf8=16'd7740;3'd4:mf8=16'd10486;default:mf8=16'd9777; endcase
                default: case(cls) 3'd0:mf8=16'd7282;3'd1:mf8=16'd6428;3'd2:mf8=16'd11570;3'd3:mf8=16'd6830;3'd4:mf8=16'd9118;default:mf8=16'd8640; endcase
            endcase
        end
    endfunction

    integer i;
    reg [6:0] qpe;
    reg [2:0] qpm;
    reg [4:0] qbits;
    reg signed [CW-1:0] coeff;
    reg [CW-1:0] absc;
    reg [63:0] prod, bias;
    reg signed [QW-1:0] level;
    reg done_pending;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done <= 1'b0; done_pending <= 1'b0; quant_flat <= {(64*QW){1'b0}};
        end else begin
            done <= done_pending;
            done_pending <= start;
            if (start) begin
                qpe = {1'b0, qp} + QP_BD_OFFSET;
                qpm = qpe % 7'd6;
                qbits = 5'd16 + (qpe / 7'd6);
                bias = ((64'd1 << qbits) + 64'd1) / 64'd3;
                for (i = 0; i < 64; i = i + 1) begin
                    coeff = $signed(in_flat[i*CW +: CW]);
                    absc = coeff[CW-1] ? (~coeff + {{(CW-1){1'b0}},1'b1}) : coeff;
                    prod = ({{(64-CW){1'b0}}, absc} * {{48{1'b0}}, mf8(qpm, qclass(i[5:0]))}) + bias;
                    level = prod >> qbits;
                    quant_flat[i*QW +: QW] <= coeff[CW-1] ? -level : level;
                end
            end
        end
    end
endmodule
