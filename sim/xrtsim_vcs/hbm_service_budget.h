// Deterministic byte service budget in device picoseconds, not host time.
#pragma once
#include <cstdint>
#include <stdexcept>

namespace u55c {

class ServiceBudget {
public:
    static constexpr uint64_t ps_per_second = 1000000000000ULL;

    ServiceBudget(uint64_t bytes_per_second, uint64_t burst_bytes,
                  uint64_t epoch_ps = 0)
        : rate_(bytes_per_second), capacity_(wide(burst_bytes) * ps_per_second),
          last_(epoch_ps) {
        if (!bytes_per_second || !burst_bytes)
            throw std::invalid_argument("Service rate and burst capacity must be positive");
    }

    // Reset discards all idle credit. Credit never exceeds the configured burst.
    void reset(uint64_t epoch_ps) { last_ = epoch_ps; credit_ = 0; }

    void advance(uint64_t time_ps) {
        if (time_ps < last_)
            throw std::invalid_argument("Cannot reverse service budget time");
        const wide earned = wide(time_ps - last_) * rate_;
        const wide room = capacity_ - credit_;
        credit_ += earned < room ? earned : room;
        last_ = time_ps;
    }

    // Inspect all applicable port/aggregate budgets before consuming any of them.
    // This prevents a failed aggregate reservation from spending port credit.
    bool available(uint64_t bytes) const {
        return wide(bytes) * ps_per_second <= credit_;
    }

    void consume(uint64_t bytes) {
        if (!available(bytes))
            throw std::logic_error("Service budget consumed without credit");
        credit_ -= wide(bytes) * ps_per_second;
    }

private:
    using wide = unsigned __int128;
    uint64_t rate_;
    wide capacity_, credit_ = 0;
    uint64_t last_;
};

} // namespace u55c
