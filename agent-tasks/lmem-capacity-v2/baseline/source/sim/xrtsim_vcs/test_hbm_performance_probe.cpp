// Simulation-only directed characterization, not measurement hardware RTL.
#include "hbm_model.h"
#include <cassert>
#include <iostream>

int main() {
    u55c::MemoryModel memory;
    u55c::Clock logic(U55C_LOGIC_FREQ_HZ);
    auto step = [&] {
        memory.logic_edge(logic.next_ps());
        logic.step();
    };
    auto read = [&](const char* label, uint64_t address) {
        step();
        const auto start = memory.now_ps();
        memory.ar(0, 1, address, 1);
        u55c::MemoryModel::Response response;
        unsigned count = 0;
        while (!memory.read_response(0, response)) {
            step();
            assert(++count < 10000);
        }
        assert(response.id == 1 && response.last);
        u55c::MemoryModel::ReadTiming timing;
        assert(memory.read_timing(0, timing));
        std::cout << "{\"case\":\"" << label << "\",\"latency_ps\":"
                  << memory.now_ps() - start
                  << ",\"hbm_first_return_ps\":" << timing.first_return_ps - timing.dram_admission_ps
                  << ",\"dram_completion_ps\":" << timing.dram_completion_ps - timing.dram_admission_ps
                  << ",\"request_cdc_ps\":" << timing.dram_admission_ps - start
                  << ",\"return_serialization_ps\":" << timing.last_return_ps - timing.first_return_ps
                  << ",\"response_cdc_ps\":" << memory.now_ps() - timing.last_return_ps
                  << ",\"manifest\":\""
                  << U55C_MANIFEST_HASH << "\"}\n";
        memory.pop_read(0);
    };
    const uint64_t base = uint64_t(u55c_config::first_pc[0]) << 29;
    read("initial-closed-page", base);
    for (unsigned i = 0; i < 20; ++i) step();
    read("same-open-page", base + 64);
    for (unsigned i = 0; i < 20; ++i) step();
    read("row-conflict", base + (U55C_DRAM_FREQ_HZ == 900000000 ? 16384 : 1024));
    memory.reset(memory.now_ps());
    read("reset-closed-page", base);
}
