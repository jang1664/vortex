#include "hbm_service_budget.h"
#include <cassert>
#include <cstdint>
#include <iostream>
#include <limits>

template <typename Exception, typename Fn> void rejects(Fn fn) {
    bool rejected = false;
    try { fn(); } catch (const Exception&) { rejected = true; }
    assert(rejected);
}

int main() {
    using u55c::ServiceBudget;
    rejects<std::invalid_argument>([] { ServiceBudget b(0, 32); });
    rejects<std::invalid_argument>([] { ServiceBudget b(1, 0); });
    ServiceBudget budget(14400000000ULL, 32);
    assert(!budget.available(32));
    budget.advance(2222);
    assert(!budget.available(32));
    budget.advance(2223);
    assert(budget.available(32));
    budget.consume(32);
    rejects<std::logic_error>([&] { budget.consume(1); });
    rejects<std::invalid_argument>([&] { budget.advance(2222); });
    budget.advance(1000000000000ULL);
    assert(budget.available(32) && !budget.available(33));
    budget.consume(32);
    assert(!budget.available(1));
    budget.reset(100);
    assert(!budget.available(1));
    budget.advance(2323);
    assert(budget.available(32));

    // Exact fractional accumulation and independence from callback partitioning.
    ServiceBudget fine(6400000000ULL, 64), coarse(6400000000ULL, 64);
    for (uint64_t t = 1; t <= 10000; ++t) fine.advance(t);
    coarse.advance(10000);
    assert(fine.available(64) && coarse.available(64));
    fine.consume(64); coarse.consume(64);
    assert(!fine.available(1) && !coarse.available(1));

    // Independent port and aggregate admission: failed joint checks spend none.
    ServiceBudget port(6400000000ULL, 64), aggregate(3200000000ULL, 64);
    port.advance(10000); aggregate.advance(10000);
    assert(port.available(64) && !aggregate.available(64));
    assert(port.available(64));
    aggregate.advance(20000);
    assert(port.available(64) && aggregate.available(64));
    port.consume(64); aggregate.consume(64);

    // Long-idle multiplication and saturation do not overflow native uint64_t.
    ServiceBudget large(std::numeric_limits<uint64_t>::max(), 64);
    large.advance(std::numeric_limits<uint64_t>::max());
    assert(large.available(64) && !large.available(65));

    // Sliding-window service is bounded by rate*time plus finite burst credit.
    ServiceBudget stream(14400000000ULL, 64);
    uint64_t bytes = 0;
    for (uint64_t t = 1; t <= 100000; ++t) {
        stream.advance(t);
        if (stream.available(32)) { stream.consume(32); bytes += 32; }
        assert(static_cast<unsigned __int128>(bytes) * ServiceBudget::ps_per_second
               <= static_cast<unsigned __int128>(14400000000ULL) * t);
    }
    assert(bytes == 1440);
    std::cout << "HBM service budget tests passed\n";
}
