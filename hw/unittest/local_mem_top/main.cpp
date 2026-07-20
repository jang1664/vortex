// Copyright © 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include "VVX_local_mem_top.h"
#include "verilated.h"

#include <array>
#include <cstdint>
#include <cstdlib>
#include <deque>
#include <iostream>
#include <sstream>
#include <string>
#include <type_traits>
#include <unordered_map>

namespace {

#ifndef TB_NUM_REQS
#define TB_NUM_REQS 32
#endif
#ifndef TB_NUM_BANKS
#define TB_NUM_BANKS 32
#endif

constexpr unsigned kNumReqs = TB_NUM_REQS;
constexpr unsigned kNumBanks = TB_NUM_BANKS;
static_assert(kNumReqs == 32 && kNumBanks == 32,
              "this focused regression requires the target 32x32 shape");
constexpr unsigned kNumWords = 512;
constexpr unsigned kAddrWidth = 9;
constexpr unsigned kWordBytes = 8;
constexpr unsigned kTagWidth = 16;
constexpr uint64_t kAllResponseReady = 0xffffffffull;
constexpr unsigned kMaxPhaseCycles = 4096;
constexpr unsigned kFabricDrainCycles = 64;

uint64_t timestamp = 0;
bool trace_enabled = false;

struct Operation {
    bool write;
    uint16_t addr;
    uint8_t byteen;
    uint64_t data;
    uint16_t tag;
};

struct ExpectedResponse {
    unsigned lane;
    uint64_t data;
};

using LaneQueues = std::array<std::deque<Operation>, kNumReqs>;

[[noreturn]] void fail(const std::string& message) {
    std::cerr << "FAILED: " << message << std::endl;
    std::abort();
}

template <typename Signal>
void set_field(Signal& signal, unsigned offset, unsigned width, uint64_t value) {
    for (unsigned bit = 0; bit < width; ++bit) {
        const unsigned absolute_bit = offset + bit;
        const uint32_t mask = uint32_t(1) << (absolute_bit % 32);
        uint32_t& word = signal[absolute_bit / 32];
        if ((value >> bit) & 1)
            word |= mask;
        else
            word &= ~mask;
    }
}

template <typename Signal>
uint64_t get_field(const Signal& signal, unsigned offset, unsigned width) {
    uint64_t value = 0;
    for (unsigned bit = 0; bit < width; ++bit) {
        const unsigned absolute_bit = offset + bit;
        value |= uint64_t((signal[absolute_bit / 32] >> (absolute_bit % 32)) & 1) << bit;
    }
    return value;
}

template <typename Signal>
void clear_signal(Signal& signal) {
    if constexpr (std::is_integral_v<Signal>) {
        signal = 0;
    } else {
        for (unsigned word = 0; word < sizeof(signal) / sizeof(uint32_t); ++word)
            signal[word] = 0;
    }
}

uint16_t make_addr(unsigned bank, unsigned row) {
    return uint16_t((row << 5) | bank);
}

uint64_t merge_bytes(uint64_t old_value, uint64_t new_value, uint8_t byteen) {
    for (unsigned byte = 0; byte < kWordBytes; ++byte) {
        if ((byteen >> byte) & 1) {
            const uint64_t mask = uint64_t(0xff) << (8 * byte);
            old_value = (old_value & ~mask) | (new_value & mask);
        }
    }
    return old_value;
}

class LocalMemTest {
public:
    LocalMemTest() {
        dut_.clk = 0;
        dut_.reset = 0;
        clear_inputs();
        memory_.fill(0);
    }

    void reset() {
        dut_.reset = 1;
        for (unsigned i = 0; i < 2; ++i) {
            clear_inputs();
            dut_.mem_rsp_ready = kAllResponseReady;
            cycle_edges();
        }
        dut_.reset = 0;
        clear_inputs();
        dut_.eval();
    }

    uint16_t next_tag() {
        if (next_tag_ == 0)
            fail("tag generator wrapped");
        return next_tag_++;
    }

    void run_phase(const char* name, LaneQueues queues, bool apply_backpressure) {
        const size_t initial_outstanding = expected_.size();
        current_phase_ = name;

        for (unsigned phase_cycle = 0; phase_cycle < kMaxPhaseCycles; ++phase_cycle) {
            current_phase_cycle_ = phase_cycle;
            drive_requests(queues);
            dut_.mem_rsp_ready = response_ready_mask(apply_backpressure, phase_cycle);
            dut_.clk = 0;
            dut_.eval();

            sample_responses();
            sample_legacy_collisions(queues);
            accept_requests(queues);
            cycle_edges_from_low();

            bool requests_done = true;
            for (const auto& queue : queues)
                requests_done &= queue.empty();

            if (requests_done && expected_.size() == initial_outstanding)
                return;
        }

        std::ostringstream oss;
        oss << name << " timed out with " << expected_.size()
            << " outstanding read responses";
        fail(oss.str());
    }

    void settle_and_check_counter() {
        // Writes have no acknowledgement. Leave enough idle cycles for the
        // deepest supported request fabric to commit every accepted write
        // before a later phase reads those addresses.
        for (unsigned i = 0; i < kFabricDrainCycles; ++i) {
            clear_inputs();
            dut_.mem_rsp_ready = kAllResponseReady;
            dut_.clk = 0;
            dut_.eval();
            sample_responses();
            cycle_edges_from_low();
        }

        if (!expected_.empty())
            fail("responses remained outstanding after drain");

#ifdef PERF_ENABLE
        const uint64_t actual = dut_.perf_bank_stalls;
        if (actual != expected_bank_stalls_) {
            std::ostringstream oss;
            oss << "bank_stalls mismatch: expected " << expected_bank_stalls_
                << ", got " << actual;
            fail(oss.str());
        }
#endif
    }

    void finish() {
        dut_.final();
    }

private:
    void clear_inputs() {
        dut_.mem_req_valid = 0;
        dut_.mem_req_rw = 0;
        clear_signal(dut_.mem_req_byteen);
        clear_signal(dut_.mem_req_addr);
        clear_signal(dut_.mem_req_flags);
        clear_signal(dut_.mem_req_data);
        clear_signal(dut_.mem_req_tag);
        dut_.mem_rsp_ready = 0;
    }

    void drive_requests(const LaneQueues& queues) {
        clear_inputs();
        for (unsigned lane = 0; lane < kNumReqs; ++lane) {
            if (queues[lane].empty())
                continue;

            const auto& op = queues[lane].front();
            dut_.mem_req_valid |= uint32_t(1) << lane;
            if (op.write)
                dut_.mem_req_rw |= uint32_t(1) << lane;
            set_field(dut_.mem_req_byteen, lane * kWordBytes, kWordBytes, op.byteen);
            set_field(dut_.mem_req_addr, lane * kAddrWidth, kAddrWidth, op.addr);
            set_field(dut_.mem_req_data, lane * 64, 64, op.data);
            set_field(dut_.mem_req_tag, lane * kTagWidth, kTagWidth, op.tag);
        }
    }

    uint32_t response_ready_mask(bool apply_backpressure, unsigned phase_cycle) const {
        if (!apply_backpressure)
            return kAllResponseReady;

        uint32_t ready = 0;
        const uint64_t cycle = timestamp / 2;
        for (unsigned lane = 0; lane < kNumReqs; ++lane) {
            // Force a long held response on a subset of ports, then continue
            // with deterministic ready bubbles while the queues drain.
            const bool prolonged_stall = phase_cycle < 24 && (lane % 3) == 0;
            if (!prolonged_stall && ((cycle + 3 * lane) % 7) != 0)
                ready |= uint32_t(1) << lane;
        }
        return ready;
    }

    void sample_responses() {
        const uint32_t accepted = dut_.mem_rsp_valid & dut_.mem_rsp_ready;
        for (unsigned lane = 0; lane < kNumReqs; ++lane) {
            if (((accepted >> lane) & 1) == 0)
                continue;

            const uint16_t tag = get_field(dut_.mem_rsp_tag, lane * kTagWidth, kTagWidth);
            const uint64_t data = get_field(dut_.mem_rsp_data, lane * 64, 64);
            auto it = expected_.find(tag);
            if (it == expected_.end()) {
                std::ostringstream oss;
                oss << "unexpected response tag 0x" << std::hex << tag
                    << " on lane " << std::dec << lane
                    << " during " << current_phase_
                    << " phase cycle " << current_phase_cycle_
                    << " (global cycle " << timestamp / 2
                    << ", rsp_valid 0x" << std::hex << uint32_t(dut_.mem_rsp_valid)
                    << ", rsp_ready 0x" << uint32_t(dut_.mem_rsp_ready)
                    << ", req_valid 0x" << uint32_t(dut_.mem_req_valid)
                    << ", req_rw 0x" << uint32_t(dut_.mem_req_rw) << ")";
                fail(oss.str());
            }
            if (it->second.lane != lane || it->second.data != data) {
                std::ostringstream oss;
                oss << "response mismatch for tag 0x" << std::hex << tag
                    << ": expected lane " << std::dec << it->second.lane
                    << " data 0x" << std::hex << it->second.data
                    << ", got lane " << std::dec << lane
                    << " data 0x" << std::hex << data;
                fail(oss.str());
            }
            expected_.erase(it);
        }
    }

    void sample_legacy_collisions(const LaneQueues& queues) {
        for (unsigned i = 0; i < kNumReqs; ++i) {
            if (queues[i].empty())
                continue;

            const unsigned bank_i = queues[i].front().addr % kNumBanks;
            bool collision = false;
            for (unsigned j = i + 1; j < kNumReqs; ++j) {
                if (queues[j].empty())
                    continue;
                const unsigned bank_j = queues[j].front().addr % kNumBanks;
                const bool either_ready = ((dut_.mem_req_ready >> i) & 1)
                                       || ((dut_.mem_req_ready >> j) & 1);
                collision |= (bank_i == bank_j) && either_ready;
            }
            expected_bank_stalls_ += collision;
        }
    }

    void accept_requests(LaneQueues& queues) {
        const uint32_t accepted = dut_.mem_req_valid & dut_.mem_req_ready;
        for (unsigned lane = 0; lane < kNumReqs; ++lane) {
            if (((accepted >> lane) & 1) == 0)
                continue;

            const Operation op = queues[lane].front();
            queues[lane].pop_front();
            if (op.addr >= kNumWords)
                fail("test generated an out-of-range address");

            if (op.write) {
                memory_[op.addr] = merge_bytes(memory_[op.addr], op.data, op.byteen);
            } else {
                const auto inserted = expected_.emplace(
                    op.tag, ExpectedResponse{lane, memory_[op.addr]});
                if (!inserted.second)
                    fail("duplicate outstanding tag");
            }
        }
    }

    void cycle_edges() {
        dut_.clk = 0;
        dut_.eval();
        cycle_edges_from_low();
    }

    void cycle_edges_from_low() {
        dut_.clk = 1;
        dut_.eval();
        ++timestamp;
        dut_.clk = 0;
        dut_.eval();
        ++timestamp;
    }

    VVX_local_mem_top dut_;
    std::array<uint64_t, kNumWords> memory_;
    std::unordered_map<uint16_t, ExpectedResponse> expected_;
    uint64_t expected_bank_stalls_ = 0;
    uint16_t next_tag_ = 1;
    const char* current_phase_ = "reset";
    unsigned current_phase_cycle_ = 0;
};

Operation write_op(uint16_t addr, uint8_t byteen, uint64_t data) {
    return Operation{true, addr, byteen, data, 0};
}

Operation read_op(LocalMemTest& test, uint16_t addr) {
    return Operation{false, addr, 0, 0, test.next_tag()};
}

} // namespace

double sc_time_stamp() {
    return timestamp;
}

bool sim_trace_enabled() {
    return trace_enabled;
}

void sim_trace_enable(bool enable) {
    trace_enabled = enable;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    LocalMemTest test;
    test.reset();

    LaneQueues init_writes;
    for (unsigned lane = 0; lane < kNumReqs; ++lane) {
        const uint64_t data = 0x1020304050607000ull ^ (uint64_t(lane) * 0x0101010101010101ull);
        init_writes[lane].push_back(write_op(make_addr(lane, 0), 0xff, data));
    }
    test.run_phase("independent full writes", init_writes, false);
    test.settle_and_check_counter();

    LaneQueues partial_writes;
    for (unsigned lane = 0; lane < kNumReqs; ++lane) {
        const uint8_t byteen = (lane & 1) ? 0xf0 : 0x0f;
        const uint64_t data = 0xa5a5000000005a5aull ^ (uint64_t(lane) << 24);
        partial_writes[lane].push_back(write_op(make_addr(lane, 0), byteen, data));
    }
    test.run_phase("independent partial writes", partial_writes, false);
    test.settle_and_check_counter();

    LaneQueues permutation_reads;
    for (unsigned lane = 0; lane < kNumReqs; ++lane)
        permutation_reads[lane].push_back(
            read_op(test, make_addr((lane + 11) % kNumBanks, 0)));
    test.run_phase("distinct-bank cyclic permutation", permutation_reads, false);

    // These phases use distinct final banks. This early checkpoint proves
    // Omega's internal blocking is not reported as a final-bank stall.
    test.settle_and_check_counter();

    LaneQueues read_after_write;
    const uint16_t hazard_addr = make_addr(5, 3);
    read_after_write[7].push_back(write_op(hazard_addr, 0xff, 0xdecafbad12345678ull));
    read_after_write[7].push_back(read_op(test, hazard_addr));
    test.run_phase("read-after-write hazard", read_after_write, false);

    LaneQueues contended_writes;
    // A bank has 16 rows in this focused configuration. Use one writer per
    // row so the contention test does not depend on the fabric's internal
    // ordering between multiple writers to the same address.
    for (unsigned lane = 0; lane < 16; ++lane) {
        const uint64_t data = 0xc000000000000000ull | (uint64_t(lane) << 32) | lane;
        contended_writes[lane].push_back(write_op(make_addr(0, lane), 0xff, data));
    }
    test.run_phase("same-bank writes", contended_writes, false);
    test.settle_and_check_counter();

    LaneQueues reads;
    for (unsigned lane = 0; lane < kNumReqs; ++lane) {
        reads[lane].push_back(read_op(test, make_addr((lane + 1) % kNumBanks, 0)));
        reads[lane].push_back(read_op(test, make_addr((lane + 7) % kNumBanks, 0)));
        reads[lane].push_back(read_op(test, make_addr((lane + 13) % kNumBanks, 0)));
        reads[lane].push_back(read_op(test, make_addr(0, (7 * lane) % 16)));
    }
    test.run_phase("routed reads with response backpressure", reads, true);

    LaneQueues mixed_writes;
    std::array<std::array<uint16_t, kNumReqs>, 4> mixed_addresses{};
    uint32_t random_state = 0x6d2b79f5u;
    for (unsigned sequence = 0; sequence < 4; ++sequence) {
        for (unsigned lane = 0; lane < kNumReqs; ++lane) {
            random_state = random_state * 1664525u + 1013904223u;
            // Each sequence is a bank permutation at a unique row, so every
            // writer owns one address regardless of internal fabric order.
            const unsigned bank = (lane + 3 + 6 * sequence) % kNumBanks;
            const unsigned row = 8 + sequence;
            const uint16_t addr = make_addr(bank, row);
            const uint8_t byteen = uint8_t((random_state & 0xff) | 1);
            const uint64_t data = (uint64_t(random_state) << 32)
                                | (random_state ^ (lane << 16) ^ sequence);
            mixed_addresses[sequence][lane] = addr;
            mixed_writes[lane].push_back(write_op(addr, byteen, data));
        }
    }
    test.run_phase("deterministic randomized writes", mixed_writes, true);
    test.settle_and_check_counter();

    LaneQueues mixed_reads;
    for (unsigned sequence = 0; sequence < 4; ++sequence) {
        for (unsigned lane = 0; lane < kNumReqs; ++lane) {
            // Permute address ownership across requesters to exercise return
            // routing without introducing read/write overlap.
            const unsigned owner = (5 * lane + 7 * sequence) % kNumReqs;
            mixed_reads[lane].push_back(
                read_op(test, mixed_addresses[sequence][owner]));
        }
    }
    test.run_phase("deterministic randomized reads", mixed_reads, true);

    test.settle_and_check_counter();
    test.finish();

    std::cout << "PASSED: 32x32 local-memory routing, data, tags, backpressure, "
                 "partial writes, and legacy bank_stalls" << std::endl;
    std::cout << "Simulation time: " << timestamp / 2 << " cycles" << std::endl;
    return 0;
}
