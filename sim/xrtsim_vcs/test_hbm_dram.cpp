#include "dram_sim.h"
#include <cassert>
#include <iostream>
#include <stdexcept>

static void complete(void* arg) { ++*static_cast<unsigned*>(arg); }

int main() {
    vortex::DramSim dram(vortex::DramSim::Profile::U55c);
    assert(dram.tck_ps() == 1000);
    assert(dram.transaction_bytes() == 32);
    unsigned completed = 0;
    for (unsigned pc = 0; pc < 32; ++pc) {
        assert(dram.try_send_raw(uint64_t(pc) << 29, false, complete, &completed));
    }
    for (unsigned cycle = 0; cycle < 10000 && completed != 32; ++cycle)
        dram.tick_raw();
    assert(completed == 32);
    unsigned accepted = 0, writes = 0;
    // No ticking: the controller must eventually exert finite backpressure.
    while (accepted < 10000 && dram.try_send_raw(accepted * 32, true, complete, &writes))
        ++accepted;
    assert(accepted > 0 && accepted < 10000);
    assert(writes == accepted);
    for (unsigned cycle = 0; cycle < 10000; ++cycle) dram.tick_raw();
    assert(dram.try_send_raw(0, true, complete, &writes));
    assert(writes == accepted + 1);
    for (uint64_t bad : {uint64_t(1), uint64_t(1) << 34}) {
        bool rejected = false;
        try { dram.try_send_raw(bad, false, nullptr, nullptr); }
        catch (const std::invalid_argument&) { rejected = true; }
        assert(rejected);
    }
    std::cout << "U55C raw DramSim tests passed\n";
}
