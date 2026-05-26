// h264_cabac_residual4x4_bins.v
//
// CABAC residual syntax bin/context front-end for one residual block.
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

    // Context-index bases for the residual category being emitted.
    // The current integrated luma instance supplies frame-coded luma 4x4
    // constants; chroma DC/AC integration overrides these with the H.264
    // category-specific context ranges.
    input  wire [8:0] ctx_cbf_base,
    input  wire [1:0] ctx_cbf_sel,
    input  wire [8:0] ctx_sig_base,
    input  wire [8:0] ctx_last_base,
    input  wire [8:0] ctx_level_gt1,
    input  wire [8:0] ctx_level_gt2,
    input  wire [3:0] ctx_sig_last_max,

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

    // Residual context-index maps for coded/significant/last flags.
    // These are ctxIdx values, not local storage indices. The luma default is
    // ctx 85 / 105..119 / 166..180; chroma DC/AC selects different bases.
    function automatic [8:0] sig_ctx_idx;
        input [3:0] idx;
        begin
            sig_ctx_idx = ctx_sig_base + ((idx < ctx_sig_last_max) ? {5'd0, idx} : {5'd0, ctx_sig_last_max});
        end
    endfunction

    function automatic [8:0] last_ctx_idx;
        input [3:0] idx;
        begin
            last_ctx_idx = ctx_last_base + ((idx < ctx_sig_last_max) ? {5'd0, idx} : {5'd0, ctx_sig_last_max});
        end
    endfunction

    function automatic [3:0] suffix_len_for;
        input [COEFF_W-1:0] value;
        reg [COEFF_W-1:0] tmp;
        integer i;
        begin
            // Minimal unary-prefix + fixed binary suffix scaffold for
            // coeff_abs_level_minus1 values greater than 2. The first two bins
            // (greater-than-one and greater-than-two) are regular-context bins;
            // remaining payload is bypass. This is intentionally simple and
            // deterministic for integration bring-up. Keep the length detector
            // bounded/synthesis-friendly; do not use a data-dependent while loop.
            tmp = (value > {{(COEFF_W-2){1'b0}}, 2'd2}) ? (value - {{(COEFF_W-2){1'b0}}, 2'd3}) : {COEFF_W{1'b0}};
            suffix_len_for = 4'd0;
            for (i = 0; i < COEFF_W; i = i + 1) begin
                if (tmp[i])
                    suffix_len_for = i[3:0] + 4'd1;
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
                        if (!bin_valid && event_valid) begin
                            case (event_kind)
                                EV_CBF: begin
                                    emit_bin(event_value, 1'b0, ctx_cbf_base + {7'd0, ctx_cbf_sel});
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
                                    emit_bin(event_level_abs > {{(COEFF_W-1){1'b0}}, 1'b1}, 1'b0, ctx_level_gt1);
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
                        emit_bin(pending_abs > {{(COEFF_W-2){1'b0}}, 2'd2}, 1'b0, ctx_level_gt2);
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
