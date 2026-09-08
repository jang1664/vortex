// VCS-owned rational clocks. No dependency on wall time or host loop frequency.
#pragma once

#include <cstdint>
#include <limits>
#include <stdexcept>

namespace u55c {

class Clock {
public:
    static constexpr uint64_t ps_per_second = 1000000000000ULL;

    explicit Clock(uint64_t frequency_hz, uint64_t epoch_ps = 0)
        : frequency_(frequency_hz), epoch_(epoch_ps) {
        if (!frequency_hz || frequency_hz > ps_per_second)
            throw std::invalid_argument("Clock period must be at least 1 ps");
    }

    // Epoch is not an edge. The first edge is one complete period after reset.
    void reset(uint64_t epoch_ps) {
        epoch_ = epoch_ps;
        edges_ = 0;
    }

    uint64_t next_ps() const {
        const auto numerator = (wide(edges_) + 1) * ps_per_second;
        const auto time = wide(epoch_) + (numerator + frequency_ - 1) / frequency_;
        if (time > std::numeric_limits<uint64_t>::max())
            throw std::overflow_error("Clock timestamp overflow");
        return uint64_t(time);
    }

    // Compare exact rational times, not their rounded simulation timestamps.
    bool precedes_or_equals(const Clock& other) const {
        if (epoch_ != other.epoch_)
            throw std::logic_error("Scheduler clocks must share an epoch");
        return (wide(edges_) + 1) * other.frequency_
            <= (wide(other.edges_) + 1) * frequency_;
    }

    void step() { ++edges_; }
    uint64_t edges() const { return edges_; }
    uint64_t frequency() const { return frequency_; }

private:
    using wide = unsigned __int128;
    uint64_t frequency_;
    uint64_t epoch_;
    uint64_t edges_ = 0;
};

enum class Edge { Dram, HbmAxi };
struct DramFrequencyHz { uint64_t value; };

class Scheduler {
public:
    Scheduler(uint64_t hbm_frequency_hz, uint64_t dram_tck_ps)
        : hbm_(hbm_frequency_hz), dram_(dram_frequency(dram_tck_ps)) {}

    // Frequency form preserves non-integral periods such as 900 MHz exactly.
    // The tagged overload prevents accidentally interpreting picoseconds as Hz.
    Scheduler(uint64_t hbm_frequency_hz, DramFrequencyHz dram_frequency_hz)
        : hbm_(hbm_frequency_hz), dram_(dram_frequency_hz.value) {}

    void reset(uint64_t epoch_ps) {
        now_ = epoch_ps;
        hbm_.reset(epoch_ps);
        dram_.reset(epoch_ps);
    }

    // Inclusive upper bound. Edges rounded upward to 1 ps, with <1 ps error.
    // Exact coincident edges run DRAM then HBM AXI. Consumers must stage newly
    // produced work until a strictly later receiving edge (registered CDC).
    // Requests must be submitted before advancing beyond their acceptance time.
    template <typename Callback>
    void advance(uint64_t until_ps, Callback&& callback) {
        if (until_ps < now_)
            throw std::invalid_argument("Cannot reverse device simulation time");
        for (;;) {
            bool is_dram = dram_.precedes_or_equals(hbm_);
            auto& clock = is_dram ? dram_ : hbm_;
            const auto next = clock.next_ps();
            if (next > until_ps)
                break;
            clock.step();
            now_ = next;
            callback(is_dram ? Edge::Dram : Edge::HbmAxi, next);
        }
        now_ = until_ps;
    }

    uint64_t now_ps() const { return now_; }
    uint64_t dram_edges() const { return dram_.edges(); }
    uint64_t hbm_edges() const { return hbm_.edges(); }

private:
    static uint64_t dram_frequency(uint64_t tck_ps) {
        if (!tck_ps || Clock::ps_per_second % tck_ps)
            throw std::invalid_argument("DRAM tCK must divide one second exactly");
        return Clock::ps_per_second / tck_ps;
    }
    Clock hbm_;
    Clock dram_;
    uint64_t now_ = 0;
};

} // namespace u55c
