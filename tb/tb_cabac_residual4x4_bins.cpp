#include <verilated.h>
#include "Vh264_cabac_residual4x4_bins.h"
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

struct Event {
    int kind;
    int value;
    int idx;
    int level_abs;
    int sign;
};

struct Bin {
    int value;
    int bypass;
    int ctx;
};

static vluint64_t main_time = 0;
double sc_time_stamp() { return static_cast<double>(main_time); }

static void tick(Vh264_cabac_residual4x4_bins* dut) {
    dut->clk = 0;
    dut->eval();
    main_time++;
    dut->clk = 1;
    dut->eval();
    main_time++;
}

static void capture_bin(Vh264_cabac_residual4x4_bins* dut, std::vector<Bin>& bins) {
    if (dut->bin_valid) {
        bins.push_back(Bin{
            static_cast<int>(dut->bin_value),
            static_cast<int>(dut->bin_bypass),
            static_cast<int>(dut->bin_ctx_idx),
        });
    }
}

static std::vector<Bin> run_events(Vh264_cabac_residual4x4_bins* dut, const std::vector<Event>& events) {
    std::vector<Bin> bins;
    dut->bin_ready = 1;
    dut->event_valid = 0;

    for (const auto& ev : events) {
        for (int wait = 0; wait < 100 && !dut->event_ready; ++wait) {
            tick(dut);
            capture_bin(dut, bins);
        }
        if (!dut->event_ready) {
            std::cerr << "Timed out waiting for event_ready\n";
            std::exit(1);
        }
        dut->event_kind = ev.kind;
        dut->event_value = ev.value;
        dut->event_coeff_idx = ev.idx;
        dut->event_level_abs = ev.level_abs;
        dut->event_level_sign = ev.sign;
        dut->event_valid = 1;
        tick(dut);
        capture_bin(dut, bins);
        dut->event_valid = 0;
    }

    for (int drain = 0; drain < 100; ++drain) {
        tick(dut);
        capture_bin(dut, bins);
        if (dut->event_ready && !dut->bin_valid) {
            return bins;
        }
    }
    std::cerr << "Timed out draining residual bin sequencer\n";
    std::exit(1);
}

static void expect_eq(const std::vector<Bin>& got, const std::vector<Bin>& want, const std::string& name) {
    if (got.size() != want.size()) {
        std::cerr << name << ": bin count mismatch got=" << got.size() << " want=" << want.size() << "\n";
        std::exit(1);
    }
    for (size_t i = 0; i < want.size(); ++i) {
        if (got[i].value != want[i].value || got[i].bypass != want[i].bypass || got[i].ctx != want[i].ctx) {
            std::cerr << name << ": bin " << i << " mismatch\n"
                      << "  got  value=" << got[i].value << " bypass=" << got[i].bypass << " ctx=" << got[i].ctx << "\n"
                      << "  want value=" << want[i].value << " bypass=" << want[i].bypass << " ctx=" << want[i].ctx << "\n";
            std::exit(1);
        }
    }
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vh264_cabac_residual4x4_bins* dut = new Vh264_cabac_residual4x4_bins;

    dut->rst_n = 0;
    dut->clk = 0;
    dut->event_valid = 0;
    dut->bin_ready = 1;
    for (int i = 0; i < 4; ++i) tick(dut);
    dut->rst_n = 1;
    tick(dut);

    auto zero = run_events(dut, {
        {0, 0, 0, 0, 0},
    });
    expect_eq(zero, {
        {0, 0, 85},
    }, "zero_block");

    auto sparse = run_events(dut, {
        {0, 1, 0, 0, 0},
        {1, 1, 0, 0, 0},
        {2, 0, 0, 0, 0},
        {1, 0, 1, 0, 0},
        {1, 0, 2, 0, 0},
        {1, 1, 3, 0, 0},
        {2, 1, 3, 0, 0},
        {3, 1, 3, 2, 1},
        {4, 1, 3, 2, 1},
        {3, 1, 0, 1, 0},
        {4, 0, 0, 1, 0},
    });
    expect_eq(sparse, {
        {1, 0, 85},
        {1, 0, 105},
        {0, 0, 166},
        {0, 0, 106},
        {0, 0, 107},
        {1, 0, 108},
        {1, 0, 169},
        {1, 0, 227},
        {0, 0, 228},
        {1, 1, 0},
        {0, 0, 227},
        {0, 0, 228},
        {0, 1, 0},
    }, "sparse_block");

    std::cout << "[PASS] CABAC residual4x4 bin/context events matched expected zero and sparse blocks\n";
    delete dut;
    return 0;
}
