// h264_cabac_residual4x4_scan.v
//
// CABAC residual syntax front-end helper for one luma 4x4 scan block.
// This module does not arithmetic-code bins. It walks an already-scanned
// coefficient vector and emits the ordered syntax events needed by a
// later CABAC bin/context sequencer. The active coefficient count is supplied
// by max_coeff_minus1 so the same helper can cover luma 4x4, chroma DC, and
// chroma AC scans:
//   - coded_block_flag
//   - significant_coeff_flag / last_significant_coeff_flag scan map
//   - coeff_abs/sign events in reverse significant-coefficient order
//
// The top-level CABAC integration must convert these events into the exact
// H.264 CABAC contexts/binarizations while preserving the slice arithmetic
// coder state.

module h264_cabac_residual4x4_scan #(
    parameter COEFF_W = 16
) (
    input  wire clk,
    input  wire rst_n,
    input  wire start,

    input  wire signed [COEFF_W-1:0] coeff0,
    input  wire signed [COEFF_W-1:0] coeff1,
    input  wire signed [COEFF_W-1:0] coeff2,
    input  wire signed [COEFF_W-1:0] coeff3,
    input  wire signed [COEFF_W-1:0] coeff4,
    input  wire signed [COEFF_W-1:0] coeff5,
    input  wire signed [COEFF_W-1:0] coeff6,
    input  wire signed [COEFF_W-1:0] coeff7,
    input  wire signed [COEFF_W-1:0] coeff8,
    input  wire signed [COEFF_W-1:0] coeff9,
    input  wire signed [COEFF_W-1:0] coeff10,
    input  wire signed [COEFF_W-1:0] coeff11,
    input  wire signed [COEFF_W-1:0] coeff12,
    input  wire signed [COEFF_W-1:0] coeff13,
    input  wire signed [COEFF_W-1:0] coeff14,
    input  wire signed [COEFF_W-1:0] coeff15,
    input  wire [3:0] max_coeff_minus1,

    output reg        event_valid,
    input  wire       event_ready,
    output reg [2:0]  event_kind,
    output reg        event_value,
    output reg [3:0]  event_coeff_idx,
    output reg [COEFF_W-1:0] event_level_abs,
    output reg        event_level_sign,

    output reg done,
    output reg busy
);

    localparam [2:0] EV_CBF   = 3'd0;
    localparam [2:0] EV_SIG   = 3'd1;
    localparam [2:0] EV_LAST  = 3'd2;
    localparam [2:0] EV_LEVEL = 3'd3;
    localparam [2:0] EV_SIGN  = 3'd4;

    localparam [2:0] S_IDLE       = 3'd0;
    localparam [2:0] S_CBF        = 3'd1;
    localparam [2:0] S_SIG        = 3'd2;
    localparam [2:0] S_LAST       = 3'd3;
    localparam [2:0] S_LEVEL_FIND = 3'd4;
    localparam [2:0] S_LEVEL      = 3'd5;
    localparam [2:0] S_SIGN       = 3'd6;
    localparam [2:0] S_DONE       = 3'd7;

    reg [2:0] state;
    reg [3:0] scan_idx;
    reg [3:0] last_idx;
    reg signed [5:0] level_idx;
    reg nz_any;

    function automatic signed [COEFF_W-1:0] coeff_at;
        input [3:0] idx;
        begin
            case (idx)
                4'd0:  coeff_at = coeff0;
                4'd1:  coeff_at = coeff1;
                4'd2:  coeff_at = coeff2;
                4'd3:  coeff_at = coeff3;
                4'd4:  coeff_at = coeff4;
                4'd5:  coeff_at = coeff5;
                4'd6:  coeff_at = coeff6;
                4'd7:  coeff_at = coeff7;
                4'd8:  coeff_at = coeff8;
                4'd9:  coeff_at = coeff9;
                4'd10: coeff_at = coeff10;
                4'd11: coeff_at = coeff11;
                4'd12: coeff_at = coeff12;
                4'd13: coeff_at = coeff13;
                4'd14: coeff_at = coeff14;
                default: coeff_at = coeff15;
            endcase
        end
    endfunction

    function automatic coeff_nonzero_at;
        input [3:0] idx;
        begin
            coeff_nonzero_at = (coeff_at(idx) != {COEFF_W{1'b0}});
        end
    endfunction

    function automatic coeff_sign_at;
        input [3:0] idx;
        reg signed [COEFF_W-1:0] c;
        begin
            c = coeff_at(idx);
            coeff_sign_at = c[COEFF_W-1];
        end
    endfunction

    function automatic [COEFF_W-1:0] coeff_abs_at;
        input [3:0] idx;
        reg signed [COEFF_W-1:0] c;
        begin
            c = coeff_at(idx);
            if (c[COEFF_W-1])
                coeff_abs_at = (~c) + {{(COEFF_W-1){1'b0}}, 1'b1};
            else
                coeff_abs_at = c[COEFF_W-1:0];
        end
    endfunction

    function automatic any_nonzero;
        integer i;
        begin
            any_nonzero = 1'b0;
            for (i = 0; i < 16; i = i + 1) begin
                if ((i <= max_coeff_minus1) && coeff_nonzero_at(i[3:0]))
                    any_nonzero = 1'b1;
            end
        end
    endfunction

    function automatic [3:0] find_last_nonzero;
        integer i;
        begin
            find_last_nonzero = 4'd0;
            for (i = 0; i < 16; i = i + 1) begin
                if ((i <= max_coeff_minus1) && coeff_nonzero_at(i[3:0]))
                    find_last_nonzero = i[3:0];
            end
        end
    endfunction

    task automatic emit_event;
        input [2:0] kind_i;
        input       value_i;
        input [3:0] idx_i;
        begin
            event_valid <= 1'b1;
            event_kind <= kind_i;
            event_value <= value_i;
            event_coeff_idx <= idx_i;
            if ((kind_i == EV_LEVEL) || (kind_i == EV_SIGN)) begin
                event_level_abs <= coeff_abs_at(idx_i);
                event_level_sign <= coeff_sign_at(idx_i);
            end else begin
                event_level_abs <= {COEFF_W{1'b0}};
                event_level_sign <= 1'b0;
            end
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            event_valid <= 1'b0;
            event_kind <= EV_CBF;
            event_value <= 1'b0;
            event_coeff_idx <= 4'd0;
            event_level_abs <= {COEFF_W{1'b0}};
            event_level_sign <= 1'b0;
            done <= 1'b0;
            busy <= 1'b0;
            state <= S_IDLE;
            scan_idx <= 4'd0;
            last_idx <= 4'd0;
            level_idx <= 6'sd0;
            nz_any <= 1'b0;
        end else begin
            done <= 1'b0;

            if (event_valid && !event_ready) begin
                event_valid <= event_valid;
            end else begin
                event_valid <= 1'b0;

                case (state)
                    S_IDLE: begin
                        if (start) begin
                            nz_any <= any_nonzero();
                            last_idx <= find_last_nonzero();
                            scan_idx <= 4'd0;
                            level_idx <= {2'b00, find_last_nonzero()};
                            busy <= 1'b1;
                            state <= S_CBF;
                        end
                    end

                    S_CBF: begin
                        emit_event(EV_CBF, nz_any, 4'd0);
                        if (nz_any)
                            state <= S_SIG;
                        else
                            state <= S_DONE;
                    end

                    S_SIG: begin
                        // H.264 CABAC infers the final coefficient position as
                        // significant when coded_block_flag is set; sig/last
                        // flags are only emitted before max_coeff_minus1.
                        if (scan_idx == max_coeff_minus1) begin
                            state <= S_LEVEL_FIND;
                        end else begin
                            emit_event(EV_SIG, coeff_nonzero_at(scan_idx), scan_idx);
                            if (coeff_nonzero_at(scan_idx))
                                state <= S_LAST;
                            else if (scan_idx == last_idx)
                                state <= S_LEVEL_FIND;
                            else
                                scan_idx <= scan_idx + 4'd1;
                        end
                    end

                    S_LAST: begin
                        emit_event(EV_LAST, (scan_idx == last_idx), scan_idx);
                        if (scan_idx == last_idx) begin
                            level_idx <= {2'b00, last_idx};
                            state <= S_LEVEL_FIND;
                        end else begin
                            scan_idx <= scan_idx + 4'd1;
                            state <= S_SIG;
                        end
                    end

                    S_LEVEL_FIND: begin
                        if (level_idx < 0) begin
                            state <= S_DONE;
                        end else if (coeff_nonzero_at(level_idx[3:0])) begin
                            state <= S_LEVEL;
                        end else begin
                            level_idx <= level_idx - 6'sd1;
                        end
                    end

                    S_LEVEL: begin
                        emit_event(EV_LEVEL, 1'b1, level_idx[3:0]);
                        state <= S_SIGN;
                    end

                    S_SIGN: begin
                        emit_event(EV_SIGN, coeff_sign_at(level_idx[3:0]), level_idx[3:0]);
                        level_idx <= level_idx - 6'sd1;
                        state <= S_LEVEL_FIND;
                    end

                    S_DONE: begin
                        done <= 1'b1;
                        busy <= 1'b0;
                        state <= S_IDLE;
                    end

                    default: begin
                        state <= S_IDLE;
                        busy <= 1'b0;
                    end
                endcase
            end
        end
    end

endmodule
