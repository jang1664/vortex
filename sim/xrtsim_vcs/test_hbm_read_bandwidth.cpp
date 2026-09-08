// Steady-state reads at the actual configured kernel interface frequency.
#include "hbm_model.h"
#include <cassert>
#include <iostream>
#include <vector>

static void run(unsigned ports, unsigned burst, unsigned outstanding_limit) {
    u55c::MemoryModel model;
    u55c::Clock logic(U55C_LOGIC_FREQ_HZ);
    std::vector<unsigned> outstanding(ports), beats_in_response(ports);
    std::vector<uint64_t> next_address(ports), measured(ports);
    constexpr uint64_t warmup_ps = 10000000;
    constexpr uint64_t end_ps = 50000000; // 40 us steady interval, >10 refresh periods.
    for (unsigned p = 0; p < ports; ++p) next_address[p] = uint64_t(u55c_config::first_pc[p]) << 29;
    while (logic.next_ps() <= end_ps) {
        const auto time = logic.next_ps();
        model.logic_edge(time);
        logic.step();
        for (unsigned p = 0; p < ports; ++p) {
            u55c::MemoryModel::Response response;
            if (model.read_response(p, response)) {
                assert(outstanding[p]);
                assert(++beats_in_response[p] <= burst);
                assert(response.last == (beats_in_response[p] == burst));
                if (response.last) { --outstanding[p]; beats_in_response[p] = 0; }
                if (time > warmup_ps) measured[p] += 64;
                model.pop_read(p);
            }
            if (outstanding[p] < outstanding_limit && model.ar_ready(p, burst)) {
                model.ar(p, p, next_address[p], burst);
                ++outstanding[p];
                next_address[p] += 64 * burst;
            }
        }
    }
    uint64_t total = 0;
    for (unsigned p = 0; p < ports; ++p) {
        assert(measured[p] > 0);
        // Physical kernel interface ceiling; no host-time measurement involved.
        assert(static_cast<unsigned __int128>(measured[p]) * 1000000000000ULL
               <= static_cast<unsigned __int128>(64) * U55C_LOGIC_FREQ_HZ * (end_ps - warmup_ps));
        total += measured[p];
    }
    std::cout << "{\"ports\":" << ports << ",\"burst_beats\":" << burst
              << ",\"outstanding_limit\":" << outstanding_limit
              << ",\"window_ps\":" << end_ps - warmup_ps
              << ",\"total_bytes\":" << total << ",\"port_bytes\":[";
    for (unsigned p = 0; p < ports; ++p) std::cout << (p ? "," : "") << measured[p];
    std::cout << "],\"manifest\":\"" << U55C_MANIFEST_HASH << "\"}\n";
}

int main() {
    for (unsigned ports : {1U, unsigned(U55C_NUM_PORTS)})
        for (unsigned burst : {1U, 16U, 64U})
            for (unsigned outstanding : {1U, 4U}) run(ports, burst, outstanding);
}
