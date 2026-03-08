#include <verilated.h>
#include "Vh264_encoder_top.h"
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

// Resolution set at compile time via -DFRAME_W=... -DFRAME_H=...
#ifndef FRAME_W
#define FRAME_W 320
#endif
#ifndef FRAME_H
#define FRAME_H 176
#endif
#ifndef BIT_DEPTH
#define BIT_DEPTH 8
#endif
#ifndef CHROMA_FORMAT_IDC
#define CHROMA_FORMAT_IDC 1
#endif
static constexpr int FRAME_WIDTH  = FRAME_W;
static constexpr int FRAME_HEIGHT = FRAME_H;
static constexpr int BD           = BIT_DEPTH;
static constexpr int CHROMA_IDC   = CHROMA_FORMAT_IDC;
static constexpr int BYTES_PER_PEL = (BD > 8) ? 2 : 1;
static constexpr int LUMA_SIZE    = FRAME_WIDTH * FRAME_HEIGHT;
static constexpr int CHROMA_WIDTH = FRAME_WIDTH / 2;
static constexpr int CHROMA_HEIGHT = (CHROMA_IDC == 2) ? FRAME_HEIGHT : (FRAME_HEIGHT / 2);
static constexpr int CHROMA_SIZE  = CHROMA_WIDTH * CHROMA_HEIGHT;
static constexpr int FRAME_SIZE   = (LUMA_SIZE + 2 * CHROMA_SIZE) * BYTES_PER_PEL;
static constexpr int CHROMA_MID   = 1 << (BD - 1);  // 128 for 8-bit, 512 for 10-bit
static constexpr size_t DEFAULT_MAX_BITSTREAM = 64 * 1024 * 1024;

// Pixel type: uint16_t for >8-bit, uint8_t for 8-bit
using pixel_t = typename std::conditional<(BD > 8), uint16_t, uint8_t>::type;

static std::vector<uint8_t> raw_file_buf;  // Raw file bytes
static std::vector<pixel_t> raw_pixel_mem; // Unpacked pixels
static std::vector<uint8_t> bitstream_mem;
static std::vector<pixel_t> ref_frame_rd;   // Read buffer (previous frame)
static std::vector<pixel_t> ref_frame_wr;   // Write buffer (current frame reconstruction)
static std::vector<pixel_t> ref_cb_rd, ref_cb_wr;  // Chroma Cb reference
static std::vector<pixel_t> ref_cr_rd, ref_cr_wr;  // Chroma Cr reference
static volatile bool got_sigint = false;
static void sigint_handler(int) { got_sigint = true; }

int main(int argc, char** argv) {
    std::signal(SIGINT, sigint_handler);
    Verilated::commandArgs(argc, argv);

    int num_frames = 1;
    std::string input_file = "data/raw_frames.yuv";
    std::string output_file = "output/encoded.h264";
    uint64_t timeout_cycles = 50000000;

    for (int i = 1; i < argc; i++) {
        std::string arg = argv[i];
        if (arg.rfind("+frames=", 0) == 0) num_frames = std::atoi(arg.c_str() + 8);
        else if (arg.rfind("+input=", 0) == 0) input_file = arg.substr(7);
        else if (arg.rfind("+output=", 0) == 0) output_file = arg.substr(8);
        else if (arg.rfind("+timeout=", 0) == 0) timeout_cycles = std::strtoull(arg.c_str() + 9, nullptr, 10);
    }

    std::ifstream f(input_file, std::ios::binary);
    if (!f.is_open()) { fprintf(stderr, "[TB] ERROR: Cannot open %s\n", input_file.c_str()); return 1; }
    f.seekg(0, std::ios::end);
    size_t file_size = f.tellg();
    f.seekg(0, std::ios::beg);

    // For >8-bit, input YUV uses 16-bit LE samples; for 8-bit, 8-bit samples
    int avail_frames = file_size / FRAME_SIZE;
    if (num_frames > avail_frames) num_frames = avail_frames;

    int total_pixels = num_frames * (LUMA_SIZE + 2 * CHROMA_SIZE);
    raw_pixel_mem.resize(total_pixels);

    if constexpr (BD > 8) {
        // Read 16-bit LE samples
        raw_file_buf.resize(num_frames * FRAME_SIZE);
        f.read(reinterpret_cast<char*>(raw_file_buf.data()), num_frames * FRAME_SIZE);
        for (int i = 0; i < total_pixels; i++) {
            raw_pixel_mem[i] = raw_file_buf[i*2] | (raw_file_buf[i*2+1] << 8);
        }
    } else {
        raw_file_buf.resize(num_frames * FRAME_SIZE);
        f.read(reinterpret_cast<char*>(raw_file_buf.data()), num_frames * FRAME_SIZE);
        for (int i = 0; i < total_pixels; i++) {
            raw_pixel_mem[i] = raw_file_buf[i];
        }
    }
    f.close();

    bitstream_mem.assign(DEFAULT_MAX_BITSTREAM, 0);
    ref_frame_rd.assign(LUMA_SIZE, 0);
    ref_frame_wr.assign(LUMA_SIZE, 0);
    ref_cb_rd.assign(CHROMA_SIZE, CHROMA_MID);
    ref_cb_wr.assign(CHROMA_SIZE, CHROMA_MID);
    ref_cr_rd.assign(CHROMA_SIZE, CHROMA_MID);
    ref_cr_wr.assign(CHROMA_SIZE, CHROMA_MID);

    fprintf(stderr, "==========================================================\n");
    fprintf(stderr, "  H.264 RTL Encoder Testbench (%d-bit)\n", BD);
    fprintf(stderr, "  Frames: %d  Resolution: %dx%d  chroma_format_idc=%d\n",
            num_frames, FRAME_WIDTH, FRAME_HEIGHT, CHROMA_IDC);
    fprintf(stderr, "==========================================================\n");

    Vh264_encoder_top* dut = new Vh264_encoder_top;
    dut->clk = 0; dut->rst_n = 0; dut->start = 0;
    dut->frame_num_in = 0; dut->is_idr_in = 0; dut->ref_mem_rd_data = 0;
    dut->chr_cb_ref_rd_data = CHROMA_MID; dut->chr_cr_ref_rd_data = CHROMA_MID;

    uint64_t cycle = 0;
    int frame_idx = 0;
    uint32_t total_bs_bytes = 0;
    bool frame_active = false;

    for (int i = 0; i < 20; i++) {
        dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval();
        cycle++;
        if (cycle == 10) dut->rst_n = 1;
    }

    while (!got_sigint && cycle < timeout_cycles && frame_idx < num_frames) {
        if (!frame_active) {
            dut->start = 1;
            int idr_interval = 12; // IDR every 12 frames
            bool is_idr = (frame_idx % idr_interval == 0);
            dut->frame_num_in = (frame_idx % idr_interval) & 0xF;
            dut->is_idr_in = is_idr ? 1 : 0;
            frame_active = true;
            fprintf(stderr, "[TB] Frame %d (%s) start @ cycle %llu\n",
                    frame_idx, is_idr ? "IDR" : "P", (unsigned long long)cycle);
        }

        dut->clk = 1;

        { // Raw pixel memory read
            int pixels_per_frame = LUMA_SIZE + 2 * CHROMA_SIZE;
            size_t base = (size_t)frame_idx * pixels_per_frame;
            uint32_t addr = dut->raw_mem_addr;
            if (base + addr < raw_pixel_mem.size())
                dut->raw_mem_data = raw_pixel_mem[base + addr];
            else
                dut->raw_mem_data = 0;
        }

        { // Reference frame memory read (from previous frame's reconstruction)
            uint32_t addr = dut->ref_mem_rd_addr;
            if (addr < ref_frame_rd.size())
                dut->ref_mem_rd_data = ref_frame_rd[addr];
            else
                dut->ref_mem_rd_data = 0;
        }

        { // Chroma Cb reference read
            uint32_t addr = dut->chr_cb_ref_rd_addr;
            dut->chr_cb_ref_rd_data = (addr < ref_cb_rd.size()) ? ref_cb_rd[addr] : CHROMA_MID;
        }
        { // Chroma Cr reference read
            uint32_t addr = dut->chr_cr_ref_rd_addr;
            dut->chr_cr_ref_rd_data = (addr < ref_cr_rd.size()) ? ref_cr_rd[addr] : CHROMA_MID;
        }

        dut->eval();
        if (dut->start) dut->start = 0;

        if (dut->bs_mem_wr) {
            uint32_t addr = dut->bs_mem_addr;
            if (addr < bitstream_mem.size())
                bitstream_mem[addr] = dut->bs_mem_data;
        }

        if (dut->ref_mem_wr_en) {
            uint32_t addr = dut->ref_mem_wr_addr;
            if (addr < ref_frame_wr.size())
                ref_frame_wr[addr] = dut->ref_mem_wr_data;
        }

        if (dut->chr_cb_ref_wr_en) {
            uint32_t addr = dut->chr_cb_ref_wr_addr;
            if (addr < ref_cb_wr.size())
                ref_cb_wr[addr] = dut->chr_cb_ref_wr_data;
        }
        if (dut->chr_cr_ref_wr_en) {
            uint32_t addr = dut->chr_cr_ref_wr_addr;
            if (addr < ref_cr_wr.size())
                ref_cr_wr[addr] = dut->chr_cr_ref_wr_data;
        }

        if (dut->done) {
            total_bs_bytes = dut->bs_bytes_written;
            fprintf(stderr, "[TB] Frame %d done @ cycle %llu -- bs_bytes=%u\n",
                    frame_idx, (unsigned long long)cycle, total_bs_bytes);

            // Swap: write buffer becomes read buffer for next frame
            {
                uint64_t sum = 0; pixel_t mn = (pixel_t)((1<<BD)-1), mx = 0;
                for (int i = 0; i < LUMA_SIZE; i++) {
                    sum += ref_frame_wr[i];
                    if (ref_frame_wr[i] < mn) mn = ref_frame_wr[i];
                    if (ref_frame_wr[i] > mx) mx = ref_frame_wr[i];
                }
                fprintf(stderr, "[TB] Ref frame luma: avg=%llu min=%u max=%u\n",
                        (unsigned long long)(sum / LUMA_SIZE), (unsigned)mn, (unsigned)mx);
                // Dump encoder reconstruction as YUV for comparison with decoder
                {
                    static std::ofstream recon_yuv;
                    if (frame_idx == 0) {
                        recon_yuv.open("output/recon.yuv", std::ios::binary);
                    }
                    if (recon_yuv.is_open()) {
                        recon_yuv.write(reinterpret_cast<char*>(ref_frame_wr.data()), LUMA_SIZE * BYTES_PER_PEL);
                        recon_yuv.write(reinterpret_cast<char*>(ref_cb_wr.data()), CHROMA_SIZE * BYTES_PER_PEL);
                        recon_yuv.write(reinterpret_cast<char*>(ref_cr_wr.data()), CHROMA_SIZE * BYTES_PER_PEL);
                    }
                }
                // Swap: current reconstruction becomes next frame's reference
                ref_frame_rd = ref_frame_wr;
                ref_cb_rd = ref_cb_wr;
                ref_cr_rd = ref_cr_wr;
            }

            frame_idx++;
            frame_active = false;
        }

        dut->clk = 0; dut->eval(); cycle++;
    }

    fprintf(stderr, "==========================================================\n");
    fprintf(stderr, "[TB] %d frames encoded, %llu cycles, %u bytes\n",
            frame_idx, (unsigned long long)cycle, total_bs_bytes);
    fprintf(stderr, "==========================================================\n");

    std::ofstream out(output_file, std::ios::binary);
    if (out.is_open()) {
        out.write(reinterpret_cast<char*>(bitstream_mem.data()), total_bs_bytes);
        out.close();
        fprintf(stderr, "[TB] Wrote %u bytes to %s\n", total_bs_bytes, output_file.c_str());
    }

    delete dut;
    return 0;
}
