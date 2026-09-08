#include "hbm_clock.h"

#include <cassert>
#include <iostream>
#include <utility>
#include <vector>

using u55c::Edge;
using u55c::Scheduler;

int main() {
    // Each host call pattern sees exactly the same device edge stream.
    for (uint64_t logic_hz : {100000000ULL, 250000000ULL, 300000000ULL, 600000000ULL}) {
        Scheduler batched(300000000, 1000), stepped(300000000, 1000);
        std::vector<std::pair<Edge, uint64_t>> expected, actual;
        auto record_expected = [&](Edge e, uint64_t t) { expected.emplace_back(e, t); };
        auto record_actual = [&](Edge e, uint64_t t) { actual.emplace_back(e, t); };
        constexpr uint64_t end = 1000000;
        batched.advance(end, record_expected);
        u55c::Clock logic(logic_hz);
        while (logic.next_ps() <= end) {
            stepped.advance(logic.next_ps(), record_actual);
            logic.step();
        }
        stepped.advance(end, record_actual);
        assert(expected == actual);
        assert(stepped.dram_edges() == 1000);
        assert(stepped.hbm_edges() == 300);
        const auto count = actual.size();
        stepped.advance(end, record_actual);
        assert(actual.size() == count);
    }

    Scheduler scheduler(300000000, 1000);
    std::vector<Edge> coincident;
    scheduler.advance(10000, [&](Edge e, uint64_t t) {
        if (t == 10000) coincident.push_back(e);
    });
    assert((coincident == std::vector<Edge>{Edge::Dram, Edge::HbmAxi}));
    scheduler.reset(123);
    assert(scheduler.hbm_edges() == 0 && scheduler.dram_edges() == 0);
    scheduler.advance(1122, [](Edge, uint64_t) { assert(false); });
    scheduler.advance(1123, [](Edge e, uint64_t t) {
        assert(e == Edge::Dram && t == 1123);
    });
    bool rejected = false;
    try { scheduler.advance(1122, [](Edge, uint64_t) {}); }
    catch (const std::invalid_argument&) { rejected = true; }
    assert(rejected);
    rejected = false;
    try { Scheduler invalid(0, 1000); }
    catch (const std::invalid_argument&) { rejected = true; }
    assert(rejected);

    // Long-run exact count: no per-period 300 MHz rounding accumulation.
    Scheduler long_run(300000000, 1000);
    long_run.advance(1000000000, [](Edge, uint64_t) {});
    assert(long_run.hbm_edges() == 300000);
    assert(long_run.dram_edges() == 1000000);
    u55c::Clock clock(300000000);
    assert(clock.next_ps() == 3334);
    clock.step();
    assert(clock.next_ps() == 6667);
    clock.step();
    assert(clock.next_ps() == 10000);
    std::cout << "HBM scheduler tests passed\n";
}
