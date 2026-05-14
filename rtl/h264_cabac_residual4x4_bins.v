// h264_cabac_residual4x4_bins.v
//
// CABAC residual syntax bin/context front-end for one luma 4x4 block.
// This consumes ordered residual scan events (as produced by
// h264_cabac_residual4x4_scan) and emits explicit CABAC bins with context ids
// or bypass marking. It is a standalone integration scaffold: the top-level
// bitstream writer can later feed these bins into h264_cabac_core and map
// ctx_idx onto persistent context-state registers.

module h264_cabac_residual4x4_bins #(
    parameter COEFF_W = 16
) (
    input  wire clk,
    input  wire rst_n,

    input  wire       event_valid,
    output wire       event_ready,
    input  wire [2:0] event_kind,
    input  wire       event_value,
    input  wire [3:0] event_coeff_idx,
    input  wire [COEFF_W-1:0] event_level_abs,
    input  wire       event_level_sign,

    output reg        bin_valid,
    input  wire       bin_ready,
    output reg        bin_value,
    output reg        bin_bypass,
    output reg [8:0]  bin_ctx_idx,
    output reg        done
);

    localparam [2:0] EV_CBF   = 3'd0;
    localparam [2:0] EV_SIG   = 3'd1;
    localparam [2:0] EV_LAST  = 3'd2;
    localparam [2:0] EV_LEVEL = 3'd3;
    localparam [2:0] EV_SIGN  = 3'd4;

    localparam [2:0] S_IDLE       = 3'd0;
    localparam [2:0] S_LEVEL_GT1  = 3'd1;
    localparam [2:0] S_LEVEL_SUFFIX = 3'd2;

    reg [2:0] state;
    reg [COEFF_W-1:0] pending_abs;
    reg [COEFF_W-1:0] suffix_value;
    reg [3:0] suffix_bit_idx;
    reg [3:0] suffix_bits_total;

    // Luma 4x4 context-index maps for coded/significant/last flags.
    // These are ctxIdx values, not local storage indices.
    function automatic [8:0] sig_ctx_idx;
        input [3:0] idx;
        begin
            // ctxIdx 105..119 for frame-coded luma 4x4 significant_coeff_flag.
            sig_ctx_idx = 9'd105 + ((idx < 4'd15) ? {5'd0, idx} : 9'd14);
        end
    endfunction

    function automatic [8:0] last_ctx_idx;
        input [3:0] idx;
        begin
            // ctxIdx 166..180 for frame-coded luma 4x4 last_significant_coeff_flag.
            last_ctx_idx = 9'd166 + ((idx < 4'd15) ? {5'd0, idx} : 9'd14);
        end
    endfunction

    function automatic [3:0] suffix_len_for;
        input [COEFF_W-1:0] value;
        reg [COEFF_W-1:0] tmp;
        begin
            // Minimal unary-prefix + fixed binary suffix scaffold for
            // coeff_abs_level_minus1 values greater than 2. The first two bins
            // (greater-than-one and greater-than-two) are regular-context bins;
            // remaining payload is bypass. This is intentionally simple and
            // deterministic for integration bring-up.
            tmp = (value > {{(COEFF_W-2){1'b0}}, 2'd2}) ? (value - {{(COEFF_W-2){1'b0}}, 2'd3}) : {COEFF_W{1'b0}};
            suffix_len_for = 4'd0;
            while (tmp != {COEFF_W{1'b0}}) begin
                suffix_len_for = suffix_len_for + 4'd1;
                tmp = tmp >> 1;
            end
        end
    endfunction

    assign event_ready = !bin_valid && (state == S_IDLE);

    task automatic emit_bin;
        input value_i;
        input bypass_i;
        input [8:0] ctx_i;
        begin
            bin_valid <= 1'b1;
            bin_value <= value_i;
            bin_bypass <= bypass_i;
            bin_ctx_idx <= ctx_i;
        end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bin_valid <= 1'b0;
            bin_value <= 1'b0;
            bin_bypass <= 1'b0;
            bin_ctx_idx <= 9'd0;
            done <= 1'b0;
            state <= S_IDLE;
            pending_abs <= {COEFF_W{1'b0}};
            suffix_value <= {COEFF_W{1'b0}};
            suffix_bit_idx <= 4'd0;
            suffix_bits_total <= 4'd0;
        end else begin
            done <= 1'b0;
            if (bin_valid && !bin_ready) begin
                bin_valid <= bin_valid;
            end else begin
                bin_valid <= 1'b0;
                case (state)
                    S_IDLE: begin
                        if (event_valid) begin
                            case (event_kind)
                                EV_CBF: begin
                                    emit_bin(event_value, 1'b0, 9'd85);
                                    if (!event_value)
                                        done <= 1'b1;
                                end
                                EV_SIG: begin
                                    emit_bin(event_value, 1'b0, sig_ctx_idx(event_coeff_idx));
                                end
                                EV_LAST: begin
                                    emit_bin(event_value, 1'b0, last_ctx_idx(event_coeff_idx));
                                end
                                EV_LEVEL: begin
                                    pending_abs <= event_level_abs;
                                    emit_bin(event_level_abs > {{(COEFF_W-1){1'b0}}, 1'b1}, 1'b0, 9'd227);
                                    state <= S_LEVEL_GT1;
                                end
                                EV_SIGN: begin
                                    emit_bin(event_level_sign, 1'b1, 9'd0);
                                end
                                default: begin
                                    done <= 1'b1;
                                end
                            endcase
                        end
                    end

                    S_LEVEL_GT1: begin
                        emit_bin(pending_abs > {{(COEFF_W-2){1'b0}}, 2'd2}, 1'b0, 9'd228);
                        if (pending_abs > {{(COEFF_W-2){1'b0}}, 2'd2}) begin
                            suffix_value <= pending_abs - {{(COEFF_W-2){1'b0}}, 2'd3};
                            suffix_bits_total <= suffix_len_for(pending_abs);
                            suffix_bit_idx <= 4'd0;
                            state <= S_LEVEL_SUFFIX;
                        end else begin
                            state <= S_IDLE;
                        end
                    end

                    S_LEVEL_SUFFIX: begin
                        if (suffix_bit_idx < suffix_bits_total) begin
                            emit_bin(suffix_value[suffix_bits_total - 4'd1 - suffix_bit_idx], 1'b1, 9'd0);
                            suffix_bit_idx <= suffix_bit_idx + 4'd1;
                        end else begin
                            state <= S_IDLE;
                        end
                    end

                    default: begin
                        state <= S_IDLE;
                    end
                endcase
            end
        end
    end

endmodule
