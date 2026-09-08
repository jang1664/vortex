#include "hbm_model.h"
#include <cassert>
#include <atomic>
#include <iostream>
#include <thread>
#include <tuple>
#include <vector>

using Sample = std::tuple<unsigned, uint32_t, bool, uint64_t>;

static std::vector<Sample> replay(bool split_calls) {
    u55c::MemoryModel model;
    u55c::MemoryModel::Data data{};
    for (unsigned i = 0; i < data.size(); ++i) data[i] = i + 1;
    for (unsigned p = 0; p < U55C_NUM_PORTS; ++p) {
        uint64_t base = uint64_t(u55c_config::first_pc[p]) << 29;
        for (unsigned i = 0; i < 64; ++i) model.host_write(base + i * 64, data.data(), 64);
    }
    std::vector<Sample> trace;
    uint64_t time = 0;
    for (unsigned cycle = 0; cycle < 10000; ++cycle) {
        time += 4000; // 250 MHz logic versus 300 MHz HBM AXI.
        if (split_calls) {
            model.advance(time - 3000);
            model.advance(time - 1000);
        }
        model.logic_edge(time);
        if (cycle == 4) {
            for (unsigned p = 0; p < U55C_NUM_PORTS; ++p)
                model.ar(p, 100 + p, uint64_t(u55c_config::first_pc[p]) << 29, 64);
        }
        for (unsigned p = 0; p < U55C_NUM_PORTS; ++p) {
            u55c::MemoryModel::Response response;
            // Deterministic output backpressure; wall-time batching is independent.
            if (cycle % 7 && model.read_response(p, response)) {
                assert(response.data == data);
                trace.emplace_back(p, response.id, response.last, time);
                model.pop_read(p);
            }
        }
        if (trace.size() == 64 * U55C_NUM_PORTS) break;
    }
    assert(trace.size() == 64 * U55C_NUM_PORTS);
    // Each 64-byte response consumes two 32-byte return-link service edges.
    uint64_t minimum_service_ps = (128ULL * 1000000000000ULL) / U55C_HBM_AXI_FREQ_HZ;
    assert(std::get<3>(trace.back()) >= minimum_service_ps);
    return trace;
}

int main() {
    auto first = replay(false);
    auto second = replay(true);
    assert(first == second);
    std::atomic<bool> stop{false};
    std::atomic<unsigned> started{0};
    std::vector<std::thread> workers;
    for (unsigned i = 0; i < 4; ++i) {
        workers.emplace_back([&] {
            std::vector<uint64_t> working_set(8192, 1);
            started.fetch_add(1);
            while (!stop.load(std::memory_order_relaxed)) {
                for (auto& value : working_set) value = value * 6364136223846793005ULL + 1;
                std::atomic_signal_fence(std::memory_order_seq_cst);
            }
        });
    }
    while (started.load() != 4) std::this_thread::yield();
    auto loaded = replay(true);
    stop.store(true);
    for (auto& worker : workers) worker.join();
    assert(first == loaded);
    std::cout << "HBM timestamp replay passed: " << first.size() << " responses\n";
}
