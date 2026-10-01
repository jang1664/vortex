// Long-window write/mixed traffic; B drain is not DRAM media persistence.
#include "hbm_model.h"
#include <cassert>
#include <iostream>
#include <vector>

static void check_bounds(const u55c::MemoryModel::ServiceCounters& first,
                         const u55c::MemoryModel::ServiceCounters& last,
                         uint64_t elapsed_ps, bool from_reset) {
    if (!U55C_PERFORMANCE_MODE) return;
    auto bound = [&](uint64_t bytes, uint64_t rate, uint64_t burst) {
        using Wide = unsigned __int128;
        assert(Wide(bytes) * 1000000000000ULL <= Wide(rate) * elapsed_ps
               + Wide(from_reset ? 0 : burst) * 1000000000000ULL);
    };
    uint64_t reads = 0, writes = 0;
    for (unsigned p = 0; p < U55C_NUM_PORTS; ++p) {
        const auto r = last[p].read - first[p].read;
        const auto w = last[p].write - first[p].write;
        bound(r, U55C_PORT_READ_BYTES_PER_SECOND, U55C_BURST_BYTES);
        bound(w, U55C_PORT_WRITE_BYTES_PER_SECOND, U55C_BURST_BYTES);
        reads += r; writes += w;
    }
    bound(reads, U55C_AGGREGATE_READ_BYTES_PER_SECOND, U55C_AGGREGATE_BURST_BYTES);
    bound(writes, U55C_AGGREGATE_WRITE_BYTES_PER_SECOND, U55C_AGGREGATE_BURST_BYTES);
    bound(reads + writes, U55C_AGGREGATE_SHARED_BYTES_PER_SECOND, U55C_AGGREGATE_BURST_BYTES);
}

static void run(unsigned ports, unsigned burst, bool mixed) {
    u55c::MemoryModel model;
    u55c::Clock logic(U55C_LOGIC_FREQ_HZ);
    std::vector<unsigned> reads(ports), writes(ports), pending_w(ports), read_beats(ports);
    std::vector<uint64_t> raddr(ports), waddr(ports), rb(ports), wb(ports), last_w(ports);
    constexpr uint64_t warmup = 20000000, end = 220000000; // 200 us measured.
    u55c::MemoryModel::Data pattern;
    pattern.fill(0x5a);
    for (unsigned p = 0; p < ports; ++p) {
        raddr[p] = uint64_t(u55c_config::first_pc[p]) << 29;
        waddr[p] = raddr[p] + (1 << 24); // No read/write alias or forwarding shortcut.
    }
    uint64_t drained_at = 0;
    u55c::MemoryModel::ServiceCounters anchor{}, warm{}, finish{};
    uint64_t anchor_time = 0;
    const uint64_t rate = U55C_PERFORMANCE_MODE ? U55C_AGGREGATE_SHARED_BYTES_PER_SECOND
                                               : 64ULL * U55C_LOGIC_FREQ_HZ;
    const uint64_t drain_limit = 100000000 + 8ULL * ports * burst * 64 * 1000000000000ULL / rate;
    while (logic.next_ps() < end + drain_limit) {
        const auto time = logic.next_ps();
        model.logic_edge(time); logic.step();
        const auto& served = model.service_counters();
        check_bounds({}, served, time, true);
        check_bounds(anchor, served, time - anchor_time, anchor_time == 0);
        // Non-clock-aligned window target avoids checking only burst boundaries.
        if (time - anchor_time >= 997003) { anchor = served; anchor_time = time; }
        if (time <= warmup) warm = served;
        if (time <= end) finish = served;
        bool pending = false;
        for (unsigned p = 0; p < ports; ++p) {
            u55c::MemoryModel::Response response;
            if (model.read_response(p, response)) {
                assert(reads[p]);
                assert(++read_beats[p] <= burst);
                assert(response.last == (read_beats[p] == burst));
                for (auto byte : response.data) assert(byte == 0);
                if (response.last) { --reads[p]; read_beats[p] = 0; }
                if (time > warmup && time <= end) rb[p] += 64;
                model.pop_read(p);
            }
            if (model.write_response(p, response)) {
                assert(writes[p]);
                --writes[p]; model.pop_write(p);
            }
            if (time < end) {
                if (mixed && reads[p] < 4 && model.ar_ready(p, burst)) {
                    model.ar(p, p, raddr[p], burst);
                    raddr[p] += 64 * burst; ++reads[p];
                }
                if (!pending_w[p] && writes[p] < 4 && model.aw_ready(p)) {
                    model.aw(p, p, waddr[p], burst);
                    last_w[p] = waddr[p] + 64 * (burst - 1);
                    waddr[p] += 64 * burst;
                    pending_w[p] = burst; ++writes[p];
                }
            }
            if (pending_w[p] && model.w_ready(p)) {
                model.w(p, pattern, ~uint64_t(0), pending_w[p] == 1);
                --pending_w[p];
                if (time > warmup && time <= end) wb[p] += 64;
            }
            pending |= reads[p] || writes[p] || pending_w[p];
        }
        if (time >= end && !pending) { drained_at = time; break; }
    }
    assert(drained_at >= end && "Read/B responses did not drain");
    uint64_t total_read = 0, total_write = 0;
    uint64_t service_read = 0, service_write = 0;
    for (unsigned p = 0; p < ports; ++p) {
        assert(wb[p] && (!mixed || rb[p])); // Every active port/direction progresses.
        u55c::MemoryModel::Data actual;
        model.host_read(last_w[p], actual.data(), actual.size());
        assert(actual == pattern);
        total_read += rb[p]; total_write += wb[p];
        service_read += finish[p].read - warm[p].read;
        service_write += finish[p].write - warm[p].write;
    }
    std::cout << "{\"mode\":\"" << (mixed ? "mixed" : "write")
              << "\",\"ports\":" << ports << ",\"burst_beats\":" << burst
              << ",\"window_ps\":" << end - warmup << ",\"read_bytes\":" << total_read
              << ",\"write_accepted_bytes\":" << total_write
              << ",\"read_service_bytes\":" << service_read
              << ",\"write_service_bytes\":" << service_write
              << ",\"read_B_drain_ps\":" << drained_at - end
              << ",\"manifest\":\"" << U55C_MANIFEST_HASH << "\"}\n";
    model.reset(drained_at);
    for (const auto& count : model.service_counters()) assert(!count.read && !count.write);
}

int main() {
    for (unsigned ports : {1U, unsigned(U55C_NUM_PORTS)})
        for (unsigned burst : {16U, 64U})
            for (bool mixed : {false, true}) run(ports, burst, mixed);
}
