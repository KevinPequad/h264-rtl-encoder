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

static void expect_int(int got, int want, const std::string& name) {
    if (got != want) {
        std::cerr << name << ": got=" << got << " want=" << want << "\n";
        std::exit(1);
    }
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

static void check_bin_ready_backpressure(Vh264_cabac_residual4x4_bins* dut) {
    dut->bin_ready = 0;
    dut->event_kind = 0;
    dut->event_value = 1;
    dut->event_coeff_idx = 0;
    dut->event_level_abs = 0;
    dut->event_level_sign = 0;
    dut->event_valid = 1;
    tick(dut);
    dut->event_valid = 0;

    for (int held = 0; held < 4; ++held) {
        expect_int(static_cast<int>(dut->bin_valid), 1, "backpressure.bin_valid_held");
        expect_int(static_cast<int>(dut->bin_value), 1, "backpressure.bin_value_held");
        expect_int(static_cast<int>(dut->bin_bypass), 0, "backpressure.bin_bypass_held");
        expect_int(static_cast<int>(dut->bin_ctx_idx), 85, "backpressure.bin_ctx_held");
        expect_int(static_cast<int>(dut->event_ready), 0, "backpressure.event_ready_blocked");
        tick(dut);
    }

    dut->bin_ready = 1;
    tick(dut);
    expect_int(static_cast<int>(dut->bin_valid), 0, "backpressure.bin_valid_released");
    expect_int(static_cast<int>(dut->event_ready), 1, "backpressure.event_ready_released");
}

static void expect_bin_outputs(Vh264_cabac_residual4x4_bins* dut, int value, int bypass, int ctx, const std::string& name) {
    expect_int(static_cast<int>(dut->bin_valid), 1, name + ".bin_valid");
    expect_int(static_cast<int>(dut->bin_value), value, name + ".bin_value");
    expect_int(static_cast<int>(dut->bin_bypass), bypass, name + ".bin_bypass");
    expect_int(static_cast<int>(dut->bin_ctx_idx), ctx, name + ".bin_ctx");
}

static void check_level_suffix_backpressure(Vh264_cabac_residual4x4_bins* dut) {
    dut->bin_ready = 1;
    dut->event_kind = 3;
    dut->event_value = 1;
    dut->event_coeff_idx = 0;
    dut->event_level_abs = 10;
    dut->event_level_sign = 0;
    dut->event_valid = 1;
    tick(dut);
    dut->event_valid = 0;
    expect_bin_outputs(dut, 1, 0, 227, "suffix_backpressure.gt1");

    dut->bin_ready = 0;
    for (int held = 0; held < 3; ++held) {
        tick(dut);
        expect_bin_outputs(dut, 1, 0, 227, "suffix_backpressure.gt1_held");
        expect_int(static_cast<int>(dut->event_ready), 0, "suffix_backpressure.gt1_event_ready_blocked");
    }

    dut->bin_ready = 1;
    tick(dut);
    expect_bin_outputs(dut, 1, 0, 232, "suffix_backpressure.gt2");

    dut->bin_ready = 0;
    for (int held = 0; held < 2; ++held) {
        tick(dut);
        expect_bin_outputs(dut, 1, 0, 232, "suffix_backpressure.gt2_held");
        expect_int(static_cast<int>(dut->event_ready), 0, "suffix_backpressure.gt2_event_ready_blocked");
    }

    dut->bin_ready = 1;
    tick(dut);
    expect_bin_outputs(dut, 1, 1, 0, "suffix_backpressure.suffix0");

    dut->bin_ready = 0;
    tick(dut);
    expect_bin_outputs(dut, 1, 1, 0, "suffix_backpressure.suffix0_held");
    expect_int(static_cast<int>(dut->event_ready), 0, "suffix_backpressure.suffix0_event_ready_blocked");

    dut->bin_ready = 1;
    tick(dut);
    expect_bin_outputs(dut, 1, 1, 0, "suffix_backpressure.suffix1");
    tick(dut);
    expect_bin_outputs(dut, 1, 1, 0, "suffix_backpressure.suffix2");
    tick(dut);
    expect_int(static_cast<int>(dut->bin_valid), 0, "suffix_backpressure.drained_bin_valid");
    expect_int(static_cast<int>(dut->event_ready), 1, "suffix_backpressure.drained_event_ready");
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vh264_cabac_residual4x4_bins* dut = new Vh264_cabac_residual4x4_bins;

    dut->rst_n = 0;
    dut->clk = 0;
    dut->event_valid = 0;
    dut->bin_ready = 1;
    dut->ctx_cbf_base = 85;
    dut->ctx_cbf_sel = 0;
    dut->ctx_sig_base = 105;
    dut->ctx_last_base = 166;
    dut->ctx_level_gt1 = 227;
    dut->ctx_level_gt2 = 232;
    dut->ctx_sig_last_max = 14;
    for (int i = 0; i < 4; ++i) tick(dut);
    dut->rst_n = 1;
    tick(dut);

    check_bin_ready_backpressure(dut);
    check_level_suffix_backpressure(dut);

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
        {0, 0, 232},
        {1, 1, 0},
        {0, 0, 227},
        {0, 0, 232},
        {0, 1, 0},
    }, "sparse_block");

    dut->ctx_cbf_sel = 3;
    tick(dut);
    auto cbf_ctx_sel = run_events(dut, {
        {0, 1, 0, 0, 0},
    });
    expect_eq(cbf_ctx_sel, {
        {1, 0, 88},
    }, "coded_block_flag_context_increment");

    dut->ctx_cbf_sel = 0;

    dut->ctx_cbf_base = 97;
    dut->ctx_sig_base = 149;
    dut->ctx_last_base = 210;
    dut->ctx_level_gt1 = 257;
    dut->ctx_level_gt2 = 262;
    dut->ctx_sig_last_max = 2;
    tick(dut);
    auto chroma_dc_zero = run_events(dut, {
        {0, 0, 0, 0, 0},
    });
    expect_eq(chroma_dc_zero, {
        {0, 0, 97},
    }, "chroma_dc_zero_cbf_context");

    for (int sel = 1; sel < 4; ++sel) {
        dut->ctx_cbf_sel = sel;
        tick(dut);
        auto chroma_dc_cbf_sel = run_events(dut, {
            {0, 1, 0, 0, 0},
        });
        expect_eq(chroma_dc_cbf_sel, {
            {1, 0, 97 + sel},
        }, "chroma_dc_cbf_context_increment_" + std::to_string(sel));
    }
    dut->ctx_cbf_sel = 0;
    tick(dut);

    auto chroma_dc = run_events(dut, {
        {0, 1, 0, 0, 0},
        {1, 1, 0, 0, 0},
        {2, 0, 0, 0, 0},
        {1, 0, 1, 0, 0},
        {1, 1, 2, 0, 0},
        {2, 1, 2, 0, 0},
        {3, 1, 2, 3, 0},
        {4, 0, 2, 3, 0},
    });
    expect_eq(chroma_dc, {
        {1, 0, 97},
        {1, 0, 149},
        {0, 0, 210},
        {0, 0, 150},
        {1, 0, 151},
        {1, 0, 212},
        {1, 0, 257},
        {1, 0, 262},
        {0, 1, 0},
    }, "chroma_dc_context_override");

    auto chroma_dc_coeff3_clamp = run_events(dut, {
        {0, 1, 0, 0, 0},
        {1, 0, 0, 0, 0},
        {1, 0, 1, 0, 0},
        {1, 0, 2, 0, 0},
        {1, 1, 3, 0, 0},
        {2, 1, 3, 0, 0},
        {3, 1, 3, 2, 0},
        {4, 0, 3, 2, 0},
    });
    expect_eq(chroma_dc_coeff3_clamp, {
        {1, 0, 97},
        {0, 0, 149},
        {0, 0, 150},
        {0, 0, 151},
        {1, 0, 151},
        {1, 0, 212},
        {1, 0, 257},
        {0, 0, 262},
        {0, 1, 0},
    }, "chroma_dc_coeff3_context_clamp");

    auto chroma_dc_coeff7_clamp = run_events(dut, {
        {0, 1, 0, 0, 0},
        {1, 0, 0, 0, 0},
        {1, 0, 1, 0, 0},
        {1, 0, 2, 0, 0},
        {1, 0, 3, 0, 0},
        {1, 0, 4, 0, 0},
        {1, 0, 5, 0, 0},
        {1, 0, 6, 0, 0},
        {1, 1, 7, 0, 0},
        {2, 1, 7, 0, 0},
        {3, 1, 7, 2, 0},
        {4, 0, 7, 2, 0},
    });
    expect_eq(chroma_dc_coeff7_clamp, {
        {1, 0, 97},
        {0, 0, 149},
        {0, 0, 150},
        {0, 0, 151},
        {0, 0, 151},
        {0, 0, 151},
        {0, 0, 151},
        {0, 0, 151},
        {1, 0, 151},
        {1, 0, 212},
        {1, 0, 257},
        {0, 0, 262},
        {0, 1, 0},
    }, "chroma_dc_coeff7_422_context_clamp");

    dut->ctx_cbf_base = 101;
    dut->ctx_sig_base = 152;
    dut->ctx_last_base = 213;
    dut->ctx_level_gt1 = 266;
    dut->ctx_level_gt2 = 277;
    dut->ctx_sig_last_max = 14;
    tick(dut);
    auto chroma_ac_zero = run_events(dut, {
        {0, 0, 0, 0, 0},
    });
    expect_eq(chroma_ac_zero, {
        {0, 0, 101},
    }, "chroma_ac_zero_cbf_context");

    for (int sel = 1; sel < 4; ++sel) {
        dut->ctx_cbf_sel = sel;
        tick(dut);
        auto chroma_ac_cbf_sel = run_events(dut, {
            {0, 1, 0, 0, 0},
        });
        expect_eq(chroma_ac_cbf_sel, {
            {1, 0, 101 + sel},
        }, "chroma_ac_cbf_context_increment_" + std::to_string(sel));
    }
    dut->ctx_cbf_sel = 0;
    tick(dut);

    auto chroma_ac = run_events(dut, {
        {0, 1, 0, 0, 0},
        {1, 1, 0, 0, 0},
        {2, 0, 0, 0, 0},
        {1, 0, 1, 0, 0},
        {1, 0, 2, 0, 0},
        {1, 0, 3, 0, 0},
        {1, 1, 4, 0, 0},
        {2, 1, 4, 0, 0},
        {3, 1, 4, 4, 1},
        {4, 1, 4, 4, 1},
        {3, 1, 0, 1, 0},
        {4, 0, 0, 1, 0},
    });
    expect_eq(chroma_ac, {
        {1, 0, 101},
        {1, 0, 152},
        {0, 0, 213},
        {0, 0, 153},
        {0, 0, 154},
        {0, 0, 155},
        {1, 0, 156},
        {1, 0, 217},
        {1, 0, 266},
        {1, 0, 277},
        {1, 1, 0},
        {1, 1, 0},
        {0, 0, 266},
        {0, 0, 277},
        {0, 1, 0},
    }, "chroma_ac_context_override");

    auto chroma_ac_tail = run_events(dut, {
        {0, 1, 0, 0, 0},
        {1, 0, 0, 0, 0},
        {1, 0, 1, 0, 0},
        {1, 0, 2, 0, 0},
        {1, 0, 3, 0, 0},
        {1, 0, 4, 0, 0},
        {1, 0, 5, 0, 0},
        {1, 0, 6, 0, 0},
        {1, 0, 7, 0, 0},
        {1, 0, 8, 0, 0},
        {1, 0, 9, 0, 0},
        {1, 0, 10, 0, 0},
        {1, 0, 11, 0, 0},
        {1, 0, 12, 0, 0},
        {1, 0, 13, 0, 0},
        {1, 1, 14, 0, 0},
        {2, 1, 14, 0, 0},
        {3, 1, 14, 2, 0},
        {4, 0, 14, 2, 0},
    });
    expect_eq(chroma_ac_tail, {
        {1, 0, 101},
        {0, 0, 152},
        {0, 0, 153},
        {0, 0, 154},
        {0, 0, 155},
        {0, 0, 156},
        {0, 0, 157},
        {0, 0, 158},
        {0, 0, 159},
        {0, 0, 160},
        {0, 0, 161},
        {0, 0, 162},
        {0, 0, 163},
        {0, 0, 164},
        {0, 0, 165},
        {1, 0, 166},
        {1, 0, 227},
        {1, 0, 266},
        {0, 0, 277},
        {0, 1, 0},
    }, "chroma_ac_tail_context_clamp");

    tick(dut);
    auto chroma_ac_suffix_payload = run_events(dut, {
        {0, 1, 0, 0, 0},
        {1, 1, 0, 0, 0},
        {2, 1, 0, 0, 0},
        {3, 1, 0, 5, 1},
        {4, 1, 0, 5, 1},
    });
    expect_eq(chroma_ac_suffix_payload, {
        {1, 0, 101},
        {1, 0, 152},
        {1, 0, 213},
        {1, 0, 266},
        {1, 0, 277},
        {1, 1, 0},
        {0, 1, 0},
        {1, 1, 0},
    }, "chroma_ac_multi_bit_suffix_payload");

    tick(dut);
    auto chroma_ac_three_bit_suffix_payload = run_events(dut, {
        {0, 1, 0, 0, 0},
        {1, 1, 0, 0, 0},
        {2, 1, 0, 0, 0},
        {3, 1, 0, 10, 0},
        {4, 0, 0, 10, 0},
    });
    expect_eq(chroma_ac_three_bit_suffix_payload, {
        {1, 0, 101},
        {1, 0, 152},
        {1, 0, 213},
        {1, 0, 266},
        {1, 0, 277},
        {1, 1, 0},
        {1, 1, 0},
        {1, 1, 0},
        {0, 1, 0},
    }, "chroma_ac_three_bit_suffix_payload");

    std::cout << "[PASS] CABAC residual4x4 bin/context events matched expected luma, 4:2:0/4:2:2 chroma-DC zero/nonzero/cbf-increment/clamped-tail, chroma-AC zero/nonzero/cbf-increment/tail-context, multi/three-bit suffix, and output backpressure category blocks\n";
    delete dut;
    return 0;
}
