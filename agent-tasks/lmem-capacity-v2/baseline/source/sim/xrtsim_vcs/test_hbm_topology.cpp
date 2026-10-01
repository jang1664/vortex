#include "hbm_model.h"
#include <cassert>
#include <iostream>
#include <vector>

// Isolate the configured abstract ingress bottleneck from DUT application
// stalls. Same-port streams necessarily share that ingress even when their
// destination PCs belong to different physical channels.
struct Stream { unsigned port, pc; };
static uint64_t run(const std::vector<Stream>& streams) {
    u55c::MemoryModel model;
    std::vector<unsigned> received(streams.size());
    std::vector<unsigned> port_beats(U55C_NUM_PORTS);
    for (unsigned i = 0; i < streams.size(); ++i) {
        const auto& stream = streams[i];
        u55c::MemoryModel::Data pattern{};
        pattern.fill(17 + i);
        uint64_t address = uint64_t(stream.pc) << 29;
        for (unsigned beat = 0; beat < 64; ++beat)
            model.host_write(address + beat * 64, pattern.data(), pattern.size());
        model.ar(stream.port, i, address, 64);
    }
    unsigned remaining = streams.size() * 64;
    // Fast receiving clock prevents logic response bandwidth from dominating
    // the 300 MHz, 32-byte HBM ingress/return links in this directed test.
    for (uint64_t time = 1000; time < 10000000; time += 1000) {
        model.logic_edge(time);
        for (unsigned port = 0; port < U55C_NUM_PORTS; ++port) {
            u55c::MemoryModel::Response response;
            if (!model.read_response(port, response)) continue;
            assert(response.id < streams.size());
            unsigned id = response.id;
            assert(streams[id].port == port);
            assert(++received[id] <= 64);
            assert(response.last == (received[id] == 64));
            for (auto byte : response.data) assert(byte == 17 + id);
            ++port_beats[port];
            uint64_t elapsed_hbm_edges = time * U55C_HBM_AXI_FREQ_HZ / 1000000000000ULL;
            // Check every prefix, not just the final drain time, against both
            // per-port and aggregate return service capacity.
            assert(uint64_t(port_beats[port]) * 64 <= elapsed_hbm_edges * 32);
            unsigned total_beats = 0;
            for (auto beats : port_beats) total_beats += beats;
            assert(uint64_t(total_beats) * 64 <= elapsed_hbm_edges * 32 * U55C_NUM_PORTS);
            // Each consecutive 64-byte response consumes two return edges.
            model.pop_read(port);
            if (--remaining == 0) {
                unsigned busiest_port = 0;
                for (unsigned p = 0; p < U55C_NUM_PORTS; ++p) {
                    unsigned count = 0;
                    for (auto stream : streams) count += stream.port == p;
                    if (count > busiest_port) busiest_port = count;
                }
                uint64_t service_edges = 128ULL * busiest_port;
                assert(time >= service_edges * 1000000000000ULL / U55C_HBM_AXI_FREQ_HZ);
                return time;
            }
        }
    }
    assert(false && "Topology traffic did not drain");
    return 0;
}

int main() {
    const unsigned first = u55c_config::first_pc[0];
    const unsigned independent_pc = u55c_config::first_pc[1];
    assert(first + 2 <= u55c_config::last_pc[0]);
    uint64_t single = run({{0, first}});
    uint64_t paired = run({{0, first}, {0, first + 1}});
    uint64_t ingress = run({{0, first}, {0, first + 2}});
    uint64_t independent = run({{0, first}, {1, independent_pc}});
    std::vector<Stream> all_ports;
    for (unsigned port = 0; port < U55C_NUM_PORTS; ++port)
        all_ports.push_back({port, u55c_config::first_pc[port]});
    uint64_t aggregate = run(all_ports);
    assert(independent < paired);
    assert(independent < ingress);
    assert(single < paired && single < ingress);
    assert(aggregate < ingress); // All independent ingresses make parallel progress.
    std::cout << "HBM topology service bounds passed (ps): single=" << single
              << " paired_pc=" << paired << " shared_ingress=" << ingress
              << " independent=" << independent << " all_ports=" << aggregate << '\n';
}
