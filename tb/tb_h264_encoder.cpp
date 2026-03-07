// ---------------------------------------------------------------------------
// tb_h264_encoder.cpp -- Verilator testbench for h264_encoder_top
// ---------------------------------------------------------------------------

#include <verilated.h>
#include <verilated_vcd_c.h>
#include "Vh264_encoder_top.h"

#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

static constexpr int FRAME_WIDTH      = 320;
static constexpr int FRAME_HEIGHT     = 176;
static constexpr int FRAME_SIZE       = FRAME_WIDTH * FRAME_HEIGHT * 3 / 2;
static constexpr size_t DEFAULT_MAX_BITSTREAM = 16 * 1024 * 1024;

static std::vector<uint8_t> raw_pixel_mem;
static std::vector<uint8_t> bitstream_mem;
static volatile bool got_sigint = false;
static void sigint_handler(int) { got_sigint = true; }

static int16_t read_wide_s16(const uint32_t* data, int idx) {
    int word = idx / 2;
    int half = idx % 2;
    return static_cast<int16_t>((data[word] >> (half * 16)) & 0xFFFF);
}

void dump_signed_4x4(const char* name, const uint32_t* data) {
    fprintf(stderr, "    %s:\n      ", name);
    for (int i = 0; i < 16; ++i) {
        fprintf(stderr, "%5d ", static_cast<int>(read_wide_s16(data, i)));
        if (i % 4 == 3 && i < 15) fprintf(stderr, "\n      ");
    }
    fprintf(stderr, "\n");
}

int main(int argc, char** argv) {
    std::signal(SIGINT, sigint_handler);
    Verilated::commandArgs(argc, argv);

    raw_pixel_mem.clear();
    bitstream_mem.assign(DEFAULT_MAX_BITSTREAM, 0);

    std::ifstream f("data/raw_frames.yuv", std::ios::binary);
    raw_pixel_mem.assign(FRAME_SIZE, 0);
    f.read(reinterpret_cast<char*>(raw_pixel_mem.data()), FRAME_SIZE);

    Vh264_encoder_top* dut = new Vh264_encoder_top;
    dut->clk = 0; dut->rst_n = 0; dut->start = 0;

    uint64_t cycle = 0;
    bool frame_started = false;
    int dbg_prev_sub_blk = -1;
    int dbg_prev_blk_state = -1;

    while (!got_sigint && cycle < 1000000) {
        dut->clk = 1;
        if (cycle == 10) dut->rst_n = 1;
        if (cycle == 12) { dut->start = 1; frame_started = true; }
        else dut->start = 0;

        dut->raw_mem_data = raw_pixel_mem[dut->raw_mem_addr];
        dut->eval();

        if (frame_started && dut->h264_encoder_top__DOT__mb_x == 0 && dut->h264_encoder_top__DOT__mb_y == 0) {
            int sblk = dut->h264_encoder_top__DOT__sub_blk;
            int bst  = dut->h264_encoder_top__DOT__blk_state;
            if (sblk != dbg_prev_sub_blk || bst != dbg_prev_blk_state) {
                if (bst == 4) { // BS_CAVLC
                    fprintf(stderr, "[DBG] sblk=%d BS_CAVLC: tc=%d t1=%d\n", 
                        sblk, 
                        dut->h264_encoder_top__DOT__total_coeffs,
                        dut->h264_encoder_top__DOT__trailing_ones);
                    dump_signed_4x4("scan_flat", dut->h264_encoder_top__DOT__scan_flat);
                }
                dbg_prev_sub_blk = sblk;
                dbg_prev_blk_state = bst;
            }
        }

        if (dut->bs_mem_wr) bitstream_mem[dut->bs_mem_addr] = dut->bs_mem_data;
        if (dut->done) break;

        dut->clk = 0;
        dut->eval();
        cycle++;
    }

    std::ofstream out("output/test_xform.h264", std::ios::binary);
    out.write(reinterpret_cast<char*>(bitstream_mem.data()), dut->bs_bytes_written);
    
    delete dut;
    return 0;
}
