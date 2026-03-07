// h264_intra_pred.v — Intra Prediction (DC mode for 4x4 block)
// Computes DC prediction for a 4x4 block
// Produces predicted block and signed residual (original - predicted)
// All arrays are flattened for Verilator compatibility

module h264_intra_pred (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    output reg         done,

    input  wire        top_avail,
    input  wire        left_avail,

    // Input: 4x4 original block (flattened, each pixel 8 bits = 128 bits)
    input  wire [127:0]  orig_4x4,

    // Neighbor pixels
    input  wire [31:0]   top_4,       // 4 * 8 = 32 bits
    input  wire [31:0]   left_4,      // 4 * 8 = 32 bits

    // Outputs (flattened)
    output reg  [127:0]  pred_4x4,    // 16 * 8 = 128 bits
    output reg  [143:0]  resid_4x4    // 16 * 9 = 144 bits (signed 9-bit per pixel)
);

    reg [2:0] state;
    localparam S_IDLE    = 3'd0;
    localparam S_SUM     = 3'd1;
    localparam S_COMPUTE = 3'd2;
    localparam S_FILL    = 3'd3;
    localparam S_DONE    = 3'd4;

    reg [10:0] sum_top;
    reg [10:0] sum_left;
    reg [7:0]  dc_value;
    reg [2:0]  cnt;
    reg [4:0]  fill_idx;

    wire [7:0] top_pix  [0:3];
    wire [7:0] left_pix [0:3];

    // Unpack neighbor pixels from flat inputs
    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : unpack_neighbors
            assign top_pix[gi]  = top_4[gi*8 +: 8];
            assign left_pix[gi] = left_4[gi*8 +: 8];
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            done     <= 1'b0;
            sum_top  <= 11'd0;
            sum_left <= 11'd0;
            dc_value <= 8'd128;
            cnt      <= 3'd0;
            fill_idx <= 5'd0;
            pred_4x4   <= 128'd0;
            resid_4x4  <= 144'd0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: begin
                    if (start) begin
                        state    <= S_SUM;
                        sum_top  <= 11'd0;
                        sum_left <= 11'd0;
                        cnt      <= 3'd0;
                    end
                end

                S_SUM: begin
                    if (cnt < 3'd4) begin
                        if (top_avail)
                            sum_top <= sum_top + {3'd0, top_pix[cnt[1:0]]};
                        if (left_avail)
                            sum_left <= sum_left + {3'd0, left_pix[cnt[1:0]]};
                        cnt <= cnt + 3'd1;
                    end else begin
                        state <= S_COMPUTE;
                    end
                end

                S_COMPUTE: begin
                    if (top_avail && left_avail) begin
                        dc_value <= (sum_top + sum_left + 11'd4) >> 3;
                    end else if (top_avail) begin
                        dc_value <= (sum_top + 11'd2) >> 2;
                    end else if (left_avail) begin
                        dc_value <= (sum_left + 11'd2) >> 2;
                    end else begin
                        dc_value <= 8'd128;
                    end
                    fill_idx <= 5'd0;
                    state    <= S_FILL;
                end

                S_FILL: begin
                    if (fill_idx < 5'd16) begin
                        pred_4x4[fill_idx*8 +: 8] <= dc_value;
                        resid_4x4[fill_idx*9 +: 9] <=
                            {1'b0, orig_4x4[fill_idx*8 +: 8]} -
                            {1'b0, dc_value};
                        fill_idx <= fill_idx + 5'd1;
                    end else begin
                        state <= S_DONE;
                    end
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
