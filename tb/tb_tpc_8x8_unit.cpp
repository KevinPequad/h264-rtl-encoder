#include <verilated.h>
#include "Vh264_tpc_8x8_unit_top.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <exception>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

using Block = std::array<int64_t, 64>;

int bit_depth = 8;
std::vector<int> qp_sweep = {0, 6, 12, 18, 24, 30, 36, 42, 48, 51};

const int quant8_scan_class[16] = {
    0,3,4,3, 3,1,5,1, 4,5,2,5, 3,1,5,1
};
const int quant8_scale[6][6] = {
    { 13107, 11428, 20972, 12222, 16777, 15481 },
    { 11916, 10826, 19174, 11058, 14980, 14290 },
    { 10082,  8943, 15978,  9675, 12710, 11985 },
    {  9362,  8228, 14913,  8931, 11984, 11259 },
    {  8192,  7346, 13159,  7740, 10486,  9777 },
    {  7282,  6428, 11570,  6830,  9118,  8640 }
};
const int dequant8_scale[6][6] = {
    { 20, 18, 32, 19, 25, 24 },
    { 22, 19, 35, 21, 28, 26 },
    { 26, 23, 42, 24, 33, 31 },
    { 28, 25, 45, 26, 35, 33 },
    { 32, 28, 51, 30, 40, 38 },
    { 36, 32, 58, 34, 46, 43 }
};

const int scan8_frame[64] = {
     0,  1,  8, 16,  9,  2,  3, 10,
    17, 24, 32, 25, 18, 11,  4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13,  6,  7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63
};
const int scan8_field[64] = {
     0,  8, 16,  1,  9, 24, 32, 17,
     2, 25, 40, 48, 56, 33, 10,  3,
    18, 41, 49, 57, 26, 11,  4, 19,
    34, 42, 50, 58, 27, 12,  5, 20,
    35, 43, 51, 59, 28, 13,  6, 21,
    36, 44, 52, 60, 29, 14, 22, 37,
    45, 53, 61, 30,  7, 15, 38, 46,
    54, 62, 23, 31, 39, 47, 55, 63
};

[[noreturn]] void fail(const std::string& msg) {
    throw std::runtime_error(msg);
}

int effective_qp(int qp) {
    return qp + 6 * (bit_depth - 8);
}

int quant_class(int pos) {
    return quant8_scan_class[((pos >> 1) & 12) | (pos & 3)];
}

void dct8_1d(const int64_t src[8], int64_t dst[8]) {
    int64_t s07 = src[0] + src[7];
    int64_t s16 = src[1] + src[6];
    int64_t s25 = src[2] + src[5];
    int64_t s34 = src[3] + src[4];
    int64_t a0 = s07 + s34;
    int64_t a1 = s16 + s25;
    int64_t a2 = s07 - s34;
    int64_t a3 = s16 - s25;
    int64_t d07 = src[0] - src[7];
    int64_t d16 = src[1] - src[6];
    int64_t d25 = src[2] - src[5];
    int64_t d34 = src[3] - src[4];
    int64_t a4 = d16 + d25 + d07 + (d07 >> 1);
    int64_t a5 = d07 - d34 - d25 - (d25 >> 1);
    int64_t a6 = d07 + d34 - d16 - (d16 >> 1);
    int64_t a7 = d16 - d25 + d34 + (d34 >> 1);
    dst[0] =  a0 + a1;
    dst[1] =  a4 + (a7 >> 2);
    dst[2] =  a2 + (a3 >> 1);
    dst[3] =  a5 + (a6 >> 2);
    dst[4] =  a0 - a1;
    dst[5] =  a6 - (a5 >> 2);
    dst[6] = (a2 >> 1) - a3;
    dst[7] = (a4 >> 2) - a7;
}

void idct8_1d_raw(const int64_t src[8], int64_t dst[8]) {
    int64_t a0 = src[0] + src[4];
    int64_t a2 = src[0] - src[4];
    int64_t a4 = (src[2] >> 1) - src[6];
    int64_t a6 = (src[6] >> 1) + src[2];
    int64_t b0 = a0 + a6;
    int64_t b2 = a2 + a4;
    int64_t b4 = a2 - a4;
    int64_t b6 = a0 - a6;
    int64_t a1 = -src[3] + src[5] - src[7] - (src[7] >> 1);
    int64_t a3 =  src[1] + src[7] - src[3] - (src[3] >> 1);
    int64_t a5 = -src[1] + src[7] + src[5] + (src[5] >> 1);
    int64_t a7 =  src[3] + src[5] + src[1] + (src[1] >> 1);
    int64_t b1 = (a7 >> 2) + a1;
    int64_t b3 =  a3 + (a5 >> 2);
    int64_t b5 = (a3 >> 2) - a5;
    int64_t b7 =  a7 - (a1 >> 2);
    dst[0] = b0 + b7;
    dst[1] = b2 + b5;
    dst[2] = b4 + b3;
    dst[3] = b6 + b1;
    dst[4] = b6 - b1;
    dst[5] = b4 - b3;
    dst[6] = b2 - b5;
    dst[7] = b0 - b7;
}

Block fwd8x8(const Block& in) {
    Block tmp{};
    Block out{};
    for (int r = 0; r < 8; ++r) {
        int64_t src[8], dst[8];
        for (int c = 0; c < 8; ++c) src[c] = in[r*8+c];
        dct8_1d(src, dst);
        for (int c = 0; c < 8; ++c) tmp[r*8+c] = dst[c];
    }
    for (int c = 0; c < 8; ++c) {
        int64_t src[8], dst[8];
        for (int r = 0; r < 8; ++r) src[r] = tmp[r*8+c];
        dct8_1d(src, dst);
        for (int r = 0; r < 8; ++r) out[r*8+c] = dst[r];
    }
    return out;
}

Block inv8x8(const Block& in) {
    Block tmp{};
    Block out{};
    for (int c = 0; c < 8; ++c) {
        int64_t src[8], dst[8];
        for (int r = 0; r < 8; ++r) src[r] = in[r*8+c];
        idct8_1d_raw(src, dst);
        for (int r = 0; r < 8; ++r) tmp[r*8+c] = dst[r];
    }
    for (int r = 0; r < 8; ++r) {
        int64_t src[8], dst[8];
        for (int c = 0; c < 8; ++c) src[c] = tmp[r*8+c];
        idct8_1d_raw(src, dst);
        for (int c = 0; c < 8; ++c) out[r*8+c] = (dst[c] + 32) >> 6;
    }
    return out;
}

Block quant8x8(const Block& coeff, int qp) {
    int eqp = effective_qp(qp);
    int qbits = 16 + eqp / 6;
    int64_t f = ((int64_t(1) << qbits) + 1) / 3;
    Block out{};
    for (int i = 0; i < 64; ++i) {
        int cls = quant_class(i);
        int64_t mf = quant8_scale[eqp % 6][cls];
        int64_t v = coeff[i];
        int64_t a = v < 0 ? -v : v;
        int64_t level = (a * mf + f) >> qbits;
        out[i] = v < 0 ? -level : level;
    }
    return out;
}

Block dequant8x8(const Block& qcoeff, int qp) {
    int eqp = effective_qp(qp);
    int shift = eqp / 6 - 6;
    Block out{};
    for (int i = 0; i < 64; ++i) {
        int cls = quant_class(i);
        // Default flat 8x8 scaling list is 16, matching x264 set.c's
        // h->dequant8_mf = def_dequant8 * scaling_list.
        int64_t prod = qcoeff[i] * int64_t(dequant8_scale[eqp % 6][cls] << 4);
        if (shift >= 0) out[i] = prod << shift;
        else {
            int rshift = -shift;
            int64_t bias = int64_t(1) << (rshift - 1);
            out[i] = (prod + bias) >> rshift;
        }
    }
    return out;
}

Block scan8x8(const Block& in, bool field) {
    Block out{};
    const int* map = field ? scan8_field : scan8_frame;
    for (int i = 0; i < 64; ++i)
        out[i] = in[map[i]];
    return out;
}

struct ScanStats {
    int total = 0;
    int trailing_ones = 0;
    int last = 0;
};

ScanStats stats_for_scan(const Block& scan) {
    ScanStats st;
    int last = -1;
    for (int i = 0; i < 64; ++i) {
        if (scan[i] != 0) {
            ++st.total;
            last = i;
        }
    }
    if (last < 0) {
        st.last = 0;
        return st;
    }
    st.last = last;
    for (int i = last; i >= 0 && st.trailing_ones < 3; --i) {
        if (scan[i] == 1 || scan[i] == -1) ++st.trailing_ones;
        else if (scan[i] != 0) break;
    }
    return st;
}

std::vector<Block> residual_vectors() {
    int maxv = (1 << bit_depth) - 1;
    int half = maxv / 2;
    std::vector<Block> v;
    Block b{};

    b.fill(0); b[0] = half; v.push_back(b);                         // DC-only
    b.fill(0); b[9] = -half; v.push_back(b);                         // single AC
    for (int i = 0; i < 64; ++i) b[i] = ((i + (i / 8)) & 1) ? -half : half; v.push_back(b); // checkerboard
    for (int r = 0; r < 8; ++r) for (int c = 0; c < 8; ++c) b[r*8+c] = (r < 4) ? half : -half; v.push_back(b); // edge
    b.fill(0); b[0]=maxv/3; b[7]=-maxv/4; b[18]=maxv/5; b[27]=-maxv/6; b[63]=maxv/7; v.push_back(b); // sparse
    for (int i = 0; i < 64; ++i) b[i] = ((i * 37 + 11) % (maxv + 1)) - half; v.push_back(b); // dense pseudo-random
    for (int i = 0; i < 64; ++i) b[i] = (i * maxv) / 63 - half; v.push_back(b); // ramp pos/neg
    for (int i = 0; i < 64; ++i) b[i] = (i & 1) ? -maxv : maxv; v.push_back(b); // saturation-clipping extremes
    return v;
}

std::vector<int> parse_qp_sweep(const std::string& s) {
    std::vector<int> out;
    std::stringstream ss(s);
    std::string item;
    while (std::getline(ss, item, ',')) {
        if (!item.empty()) out.push_back(std::stoi(item));
    }
    if (out.empty()) fail("empty qp_sweep");
    return out;
}

class Driver {
public:
    Vh264_tpc_8x8_unit_top top;
    vluint64_t main_time = 0;

    Driver() {
        top.clk = 0;
        top.rst_n = 0;
        top.clear = 1;
        top.qp = 0;
        top.field_scan = 0;
        top.wr_idx = 0;
        top.wr_residual = 0;
        top.wr_coeff = 0;
        top.wr_quant = 0;
        top.wr_residual_en = 0;
        top.wr_coeff_en = 0;
        top.wr_quant_en = 0;
        top.start_fwd = 0;
        top.start_inv = 0;
        top.start_quant = 0;
        top.start_dequant = 0;
        top.start_scan = 0;
        top.rd_idx = 0;
        tick();
        tick();
        top.rst_n = 1;
        tick();
        top.clear = 0;
        tick();
    }

    ~Driver() { top.final(); }

    void eval() { top.eval(); }
    void tick() {
        top.clk = 0; top.eval(); ++main_time;
        top.clk = 1; top.eval(); ++main_time;
    }
    void clear() {
        top.clear = 1;
        tick();
        top.clear = 0;
        tick();
    }
    void write_residual(int idx, int64_t val) {
        top.wr_idx = idx;
        top.wr_residual = static_cast<uint32_t>(static_cast<int32_t>(val));
        top.wr_residual_en = 1;
        tick();
        top.wr_residual_en = 0;
    }
    void write_coeff(int idx, int64_t val) {
        top.wr_idx = idx;
        top.wr_coeff = static_cast<uint32_t>(static_cast<int32_t>(val));
        top.wr_coeff_en = 1;
        tick();
        top.wr_coeff_en = 0;
    }
    void write_quant(int idx, int64_t val) {
        top.wr_idx = idx;
        top.wr_quant = static_cast<uint32_t>(static_cast<int32_t>(val));
        top.wr_quant_en = 1;
        tick();
        top.wr_quant_en = 0;
    }
    int32_t read_fwd(int idx) { top.rd_idx = idx; eval(); return static_cast<int32_t>(top.fwd_out); }
    int32_t read_inv(int idx) { top.rd_idx = idx; eval(); return static_cast<int32_t>(top.inv_out); }
    int32_t read_quant(int idx) { top.rd_idx = idx; eval(); return static_cast<int32_t>(top.quant_out); }
    int32_t read_dequant(int idx) { top.rd_idx = idx; eval(); return static_cast<int32_t>(top.dequant_out); }
    int32_t read_scan(int idx) { top.rd_idx = idx; eval(); return static_cast<int32_t>(top.scan_out); }

    void wait_fwd() { wait_done([&]{ return top.done_fwd != 0; }, "fwd"); }
    void wait_inv() { wait_done([&]{ return top.done_inv != 0; }, "inv"); }
    void wait_quant() { wait_done([&]{ return top.done_quant != 0; }, "quant"); }
    void wait_dequant() { wait_done([&]{ return top.done_dequant != 0; }, "dequant"); }
    void wait_scan() { wait_done([&]{ return top.done_scan != 0; }, "scan"); }

    template <typename Fn>
    void wait_done(Fn done, const char* name) {
        for (int i = 0; i < 500; ++i) {
            eval();
            if (done()) return;
            tick();
        }
        fail(std::string("timeout waiting for ") + name);
    }
};

void compare_block(const Block& got, const Block& exp, const std::string& what) {
    for (int i = 0; i < 64; ++i) {
        if (got[i] != exp[i]) {
            std::ostringstream oss;
            oss << what << " mismatch idx=" << i << " got=" << got[i] << " exp=" << exp[i];
            fail(oss.str());
        }
    }
}

Block read_fwd_block(Driver& d) { Block b{}; for (int i=0;i<64;++i) b[i]=d.read_fwd(i); return b; }
Block read_inv_block(Driver& d) { Block b{}; for (int i=0;i<64;++i) b[i]=d.read_inv(i); return b; }
Block read_quant_block(Driver& d) { Block b{}; for (int i=0;i<64;++i) b[i]=d.read_quant(i); return b; }
Block read_dequant_block(Driver& d) { Block b{}; for (int i=0;i<64;++i) b[i]=d.read_dequant(i); return b; }
Block read_scan_block(Driver& d) { Block b{}; for (int i=0;i<64;++i) b[i]=d.read_scan(i); return b; }

void run_fwd_inv() {
    Driver d;
    auto vectors = residual_vectors();
    int n = 0;
    for (const Block& residual : vectors) {
        d.clear();
        for (int i = 0; i < 64; ++i) d.write_residual(i, residual[i]);
        d.top.start_fwd = 1; d.tick(); d.top.start_fwd = 0; d.wait_fwd();
        Block got_fwd = read_fwd_block(d);
        Block exp_fwd = fwd8x8(residual);
        compare_block(got_fwd, exp_fwd, "fwd vector " + std::to_string(n));

        d.clear();
        for (int i = 0; i < 64; ++i) d.write_coeff(i, got_fwd[i]);
        d.top.start_inv = 1; d.tick(); d.top.start_inv = 0; d.wait_inv();
        Block got_inv = read_inv_block(d);
        Block exp_inv = inv8x8(exp_fwd);
        compare_block(got_inv, exp_inv, "inv vector " + std::to_string(n));
        ++n;
    }
    std::cout << "PASS tpc_8x8_fwd_inv_unit_" << bit_depth << "b vectors=" << n
              << " sources=x264/common/dct.c:DCT8_1D,IDCT8_1D" << std::endl;
}

void run_quant_dequant() {
    Driver d;
    auto vectors = residual_vectors();
    int cases = 0;
    int vec_idx = 0;
    for (const Block& residual : vectors) {
        Block coeff = fwd8x8(residual);
        for (int qp : qp_sweep) {
            d.clear();
            d.top.qp = qp;
            for (int i = 0; i < 64; ++i) d.write_coeff(i, coeff[i]);
            d.top.start_quant = 1; d.tick(); d.top.start_quant = 0; d.wait_quant();
            Block got_q = read_quant_block(d);
            Block exp_q = quant8x8(coeff, qp);
            compare_block(got_q, exp_q, "quant vector " + std::to_string(vec_idx) + " qp " + std::to_string(qp));

            d.clear();
            d.top.qp = qp;
            for (int i = 0; i < 64; ++i) d.write_quant(i, got_q[i]);
            d.top.start_dequant = 1; d.tick(); d.top.start_dequant = 0; d.wait_dequant();
            Block got_dq = read_dequant_block(d);
            Block exp_dq = dequant8x8(exp_q, qp);
            compare_block(got_dq, exp_dq, "dequant vector " + std::to_string(vec_idx) + " qp " + std::to_string(qp));
            ++cases;
        }
        ++vec_idx;
    }
    std::cout << "PASS tpc_8x8_quant_dequant_unit_" << bit_depth << "b cases=" << cases
              << " qp_sweep=";
    for (size_t i = 0; i < qp_sweep.size(); ++i) std::cout << (i ? "," : "") << qp_sweep[i];
    std::cout << " sources=x264/common/set.c:quant8_scale,dequant8_scale; common/quant.c:dequant_8x8" << std::endl;
}

void run_one_scan_pattern(Driver& d, const Block& raster, bool field, const std::string& name) {
    d.clear();
    d.top.field_scan = field ? 1 : 0;
    for (int i = 0; i < 64; ++i) d.write_quant(i, raster[i]);
    d.top.start_scan = 1; d.tick(); d.top.start_scan = 0; d.wait_scan();
    Block got = read_scan_block(d);
    Block exp = scan8x8(raster, field);
    compare_block(got, exp, "scan " + name);
    ScanStats st = stats_for_scan(exp);
    if (d.top.scan_total_coeffs != st.total || d.top.scan_trailing_ones != st.trailing_ones || d.top.scan_last_nonzero_idx != st.last) {
        std::ostringstream oss;
        oss << "scan stats " << name << " got tc=" << int(d.top.scan_total_coeffs)
            << " t1=" << int(d.top.scan_trailing_ones) << " last=" << int(d.top.scan_last_nonzero_idx)
            << " exp tc=" << st.total << " t1=" << st.trailing_ones << " last=" << st.last;
        fail(oss.str());
    }
}

void run_scan() {
    Driver d;
    Block raster{};
    for (int i = 0; i < 64; ++i) raster[i] = i + 1;
    run_one_scan_pattern(d, raster, false, "frame_dense");
    run_one_scan_pattern(d, raster, true, "field_dense");

    raster.fill(0);
    // Build a frame-scan sparse block with a nonzero before three trailing ones.
    raster[scan8_frame[59]] = 2;
    raster[scan8_frame[60]] = 1;
    raster[scan8_frame[61]] = -1;
    raster[scan8_frame[62]] = 1;
    run_one_scan_pattern(d, raster, false, "frame_trailing_ones");

    raster.fill(0);
    raster[scan8_field[59]] = -3;
    raster[scan8_field[60]] = 1;
    raster[scan8_field[61]] = 1;
    raster[scan8_field[62]] = -1;
    run_one_scan_pattern(d, raster, true, "field_trailing_ones");

    raster.fill(0);
    run_one_scan_pattern(d, raster, false, "frame_zero");
    run_one_scan_pattern(d, raster, true, "field_zero");

    std::cout << "PASS tpc_8x8_scan_unit patterns=6 sources=H.264_8x8_frame_field_scan;x264/common/macroblock.h:x264_zigzag_scan8_transposed" << std::endl;
}

} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    std::string mode = "all";
    try {
        for (int i = 1; i < argc; ++i) {
            std::string a(argv[i]);
            if (a.rfind("+mode=", 0) == 0) mode = a.substr(6);
            else if (a.rfind("+bit_depth=", 0) == 0) bit_depth = std::stoi(a.substr(11));
            else if (a.rfind("+qp_sweep=", 0) == 0) qp_sweep = parse_qp_sweep(a.substr(10));
        }
        if (bit_depth != 8 && bit_depth != 10) fail("bit_depth must be 8 or 10");
        if (mode == "fwd_inv") run_fwd_inv();
        else if (mode == "quant_dequant") run_quant_dequant();
        else if (mode == "scan") run_scan();
        else if (mode == "all") { run_fwd_inv(); run_quant_dequant(); run_scan(); }
        else fail("unknown +mode=" + mode);
    } catch (const std::exception& e) {
        std::cerr << "FAIL: " << e.what() << std::endl;
        return 1;
    }
    return 0;
}
