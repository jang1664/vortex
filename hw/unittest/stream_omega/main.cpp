// Copyright (c) 2026
// SPDX-License-Identifier: Apache-2.0

#include "VVX_stream_omega_top.h"
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

constexpr unsigned kDataWidth = 32;
constexpr unsigned kMaxInputs = 32;
constexpr unsigned kMaxCycles = 20000;

uint64_t timestamp = 0;
bool trace_enabled = false;

struct Transfer {
    uint32_t payload;
    unsigned destination;
};

struct ExpectedTransfer {
    unsigned source;
    unsigned destination;
};

using InputQueues = std::array<std::deque<Transfer>, kMaxInputs>;

[[noreturn]] void fail(const std::string& message) {
    std::cerr << "FAILED: " << message << std::endl;
    std::abort();
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

uint32_t make_payload(unsigned fabric, unsigned source,
                      unsigned destination, unsigned sequence) {
    return 0xa0000000u | ((fabric & 1) << 27) | ((source & 0x1f) << 16)
         | ((destination & 0x1f) << 8) | (sequence & 0xff);
}

InputQueues make_traffic(unsigned fabric, unsigned num_inputs,
                         unsigned num_outputs) {
    InputQueues queues;
    for (unsigned source = 0; source < num_inputs; ++source) {
        // Keep all inputs valid against one output long enough to exercise
        // arbitration and backpressure propagation through every stage.
        for (unsigned sequence = 0; sequence < 4; ++sequence) {
            queues[source].push_back({
                make_payload(fabric, source, 0, sequence), 0});
        }
        // Follow with sustained traffic spanning the entire output range.
        for (unsigned sequence = 4; sequence < 20; ++sequence) {
            const unsigned destination =
                (source * 5 + sequence * 3) % num_outputs;
            queues[source].push_back({
                make_payload(fabric, source, destination, sequence),
                destination});
        }
    }
    return queues;
}

class OmegaTest {
public:
    OmegaTest() {
        dut_.clk = 0;
        dut_.reset = 0;
        clear_inputs();
    }

    void reset() {
        dut_.reset = 1;
        for (unsigned cycle = 0; cycle < 4; ++cycle) {
            clear_inputs();
            dut_.req_ready_out = 0xffffu;
            dut_.rsp_ready_out = 0xffffffffu;
            clock_cycle();
        }
        dut_.reset = 0;
        clear_inputs();
        dut_.eval();
    }

    void run_request_fabric() {
        constexpr unsigned kInputs = 32;
        constexpr unsigned kOutputs = 16;
        InputQueues queues = make_traffic(0, kInputs, kOutputs);
        const unsigned total = count_queued(queues, kInputs);
        std::unordered_map<uint32_t, ExpectedTransfer> expected;
        unsigned accepted_count = 0;
        unsigned delivered_count = 0;

        for (unsigned cycle = 0; cycle < kMaxCycles; ++cycle) {
            clear_inputs();
            drive_request_inputs(queues);
            dut_.req_ready_out = ready_mask(kOutputs, cycle, random_state_req_);
            dut_.rsp_ready_out = 0xffffffffu;
            dut_.clk = 0;
            dut_.eval();

            sample_request_outputs(expected, delivered_count, cycle);
            accept_request_inputs(queues, expected, accepted_count);
            clock_from_low();

            if (queues_empty(queues, kInputs) && expected.empty()
                && dut_.req_valid_out == 0) {
                check_counts("32-to-16 request fabric", total,
                             accepted_count, delivered_count);
                return;
            }
        }
        timeout("32-to-16 request fabric", expected.size());
    }

    void run_sparse_request_fabric() {
        constexpr unsigned kInputs = 32;
        constexpr unsigned kOutputs = 16;
        for (unsigned destination = 0; destination < kOutputs; ++destination) {
            InputQueues queues;
            const unsigned source = (7 * destination + 3) % kInputs;
            queues[source].push_back({
                make_payload(0, source, destination, 0x80 + destination),
                destination});
            std::unordered_map<uint32_t, ExpectedTransfer> expected;
            unsigned accepted_count = 0;
            unsigned delivered_count = 0;

            for (unsigned cycle = 0; cycle < 256; ++cycle) {
                clear_inputs();
                drive_request_inputs(queues);
                dut_.req_ready_out = sparse_ready_mask(
                    kOutputs, destination, cycle);
                dut_.rsp_ready_out = 0xffffffffu;
                dut_.clk = 0;
                dut_.eval();

                sample_request_outputs(expected, delivered_count, cycle);
                accept_request_inputs(queues, expected, accepted_count);
                clock_from_low();

                if (queues_empty(queues, kInputs) && expected.empty()
                    && dut_.req_valid_out == 0) {
                    check_counts("sparse 32-to-16 request transfer", 1,
                                 accepted_count, delivered_count);
                    break;
                }
                if (cycle == 255)
                    timeout("sparse 32-to-16 request transfer",
                            expected.size());
            }
        }
    }

    void run_response_fabric() {
        constexpr unsigned kInputs = 16;
        constexpr unsigned kOutputs = 32;
        InputQueues queues = make_traffic(1, kInputs, kOutputs);
        const unsigned total = count_queued(queues, kInputs);
        std::unordered_map<uint32_t, ExpectedTransfer> expected;
        unsigned accepted_count = 0;
        unsigned delivered_count = 0;

        for (unsigned cycle = 0; cycle < kMaxCycles; ++cycle) {
            clear_inputs();
            drive_response_inputs(queues);
            dut_.req_ready_out = 0xffffu;
            dut_.rsp_ready_out = ready_mask(kOutputs, cycle, random_state_rsp_);
            dut_.clk = 0;
            dut_.eval();

            sample_response_outputs(expected, delivered_count, cycle);
            accept_response_inputs(queues, expected, accepted_count);
            clock_from_low();

            if (queues_empty(queues, kInputs) && expected.empty()
                && dut_.rsp_valid_out == 0) {
                check_counts("16-to-32 response fabric", total,
                             accepted_count, delivered_count);
                return;
            }
        }
        timeout("16-to-32 response fabric", expected.size());
    }

    void run_sparse_response_fabric() {
        constexpr unsigned kInputs = 16;
        constexpr unsigned kOutputs = 32;
        for (unsigned destination = 0; destination < kOutputs; ++destination) {
            InputQueues queues;
            const unsigned source = (5 * destination + 1) % kInputs;
            queues[source].push_back({
                make_payload(1, source, destination, 0x80 + destination),
                destination});
            std::unordered_map<uint32_t, ExpectedTransfer> expected;
            unsigned accepted_count = 0;
            unsigned delivered_count = 0;

            for (unsigned cycle = 0; cycle < 256; ++cycle) {
                clear_inputs();
                drive_response_inputs(queues);
                dut_.req_ready_out = 0xffffu;
                dut_.rsp_ready_out = sparse_ready_mask(
                    kOutputs, destination, cycle);
                dut_.clk = 0;
                dut_.eval();

                sample_response_outputs(expected, delivered_count, cycle);
                accept_response_inputs(queues, expected, accepted_count);
                clock_from_low();

                if (queues_empty(queues, kInputs) && expected.empty()
                    && dut_.rsp_valid_out == 0) {
                    check_counts("sparse 16-to-32 response transfer", 1,
                                 accepted_count, delivered_count);
                    break;
                }
                if (cycle == 255)
                    timeout("sparse 16-to-32 response transfer",
                            expected.size());
            }
        }
    }

    void finish() {
        dut_.final();
    }

private:
    void clear_inputs() {
        dut_.req_valid_in = 0;
        clear_signal(dut_.req_data_in);
        clear_signal(dut_.req_sel_in);
        dut_.req_ready_out = 0;
        dut_.rsp_valid_in = 0;
        clear_signal(dut_.rsp_data_in);
        clear_signal(dut_.rsp_sel_in);
        dut_.rsp_ready_out = 0;
    }

    void drive_request_inputs(const InputQueues& queues) {
        for (unsigned source = 0; source < 32; ++source) {
            if (queues[source].empty())
                continue;
            const Transfer& transfer = queues[source].front();
            dut_.req_valid_in |= uint32_t(1) << source;
            set_field(dut_.req_data_in, source * kDataWidth,
                      kDataWidth, transfer.payload);
            set_field(dut_.req_sel_in, source * 4, 4,
                      transfer.destination);
        }
    }

    void drive_response_inputs(const InputQueues& queues) {
        for (unsigned source = 0; source < 16; ++source) {
            if (queues[source].empty())
                continue;
            const Transfer& transfer = queues[source].front();
            dut_.rsp_valid_in |= uint32_t(1) << source;
            set_field(dut_.rsp_data_in, source * kDataWidth,
                      kDataWidth, transfer.payload);
            set_field(dut_.rsp_sel_in, source * 5, 5,
                      transfer.destination);
        }
    }

    void accept_request_inputs(
        InputQueues& queues,
        std::unordered_map<uint32_t, ExpectedTransfer>& expected,
        unsigned& accepted_count) {
        const uint32_t accepted = dut_.req_valid_in & dut_.req_ready_in;
        accept_inputs(queues, expected, accepted_count, accepted, 32);
    }

    void accept_response_inputs(
        InputQueues& queues,
        std::unordered_map<uint32_t, ExpectedTransfer>& expected,
        unsigned& accepted_count) {
        const uint32_t accepted = dut_.rsp_valid_in & dut_.rsp_ready_in;
        accept_inputs(queues, expected, accepted_count, accepted, 16);
    }

    static void accept_inputs(
        InputQueues& queues,
        std::unordered_map<uint32_t, ExpectedTransfer>& expected,
        unsigned& accepted_count, uint32_t accepted, unsigned num_inputs) {
        for (unsigned source = 0; source < num_inputs; ++source) {
            if (((accepted >> source) & 1) == 0)
                continue;
            if (queues[source].empty())
                fail("fabric accepted an input without a queued transfer");
            const Transfer transfer = queues[source].front();
            queues[source].pop_front();
            const auto inserted = expected.emplace(
                transfer.payload,
                ExpectedTransfer{source, transfer.destination});
            if (!inserted.second)
                fail("duplicate accepted payload");
            ++accepted_count;
        }
    }

    void sample_request_outputs(
        std::unordered_map<uint32_t, ExpectedTransfer>& expected,
        unsigned& delivered_count, unsigned cycle) {
        const uint32_t accepted = dut_.req_valid_out & dut_.req_ready_out;
        for (unsigned destination = 0; destination < 16; ++destination) {
            if (((accepted >> destination) & 1) == 0)
                continue;
            const uint32_t payload = get_field(
                dut_.req_data_out, destination * kDataWidth, kDataWidth);
            const unsigned source = get_field(
                dut_.req_sel_out, destination * 5, 5);
            check_output(expected, payload, source, destination,
                         delivered_count, "32-to-16", cycle);
        }
    }

    void sample_response_outputs(
        std::unordered_map<uint32_t, ExpectedTransfer>& expected,
        unsigned& delivered_count, unsigned cycle) {
        const uint32_t accepted = dut_.rsp_valid_out & dut_.rsp_ready_out;
        for (unsigned destination = 0; destination < 32; ++destination) {
            if (((accepted >> destination) & 1) == 0)
                continue;
            const uint32_t payload = get_field(
                dut_.rsp_data_out, destination * kDataWidth, kDataWidth);
            const unsigned source = get_field(
                dut_.rsp_sel_out, destination * 4, 4);
            check_output(expected, payload, source, destination,
                         delivered_count, "16-to-32", cycle);
        }
    }

    static void check_output(
        std::unordered_map<uint32_t, ExpectedTransfer>& expected,
        uint32_t payload, unsigned source, unsigned destination,
        unsigned& delivered_count, const char* fabric, unsigned cycle) {
        const auto it = expected.find(payload);
        if (it == expected.end()) {
            std::ostringstream oss;
            oss << fabric << " unexpected or duplicate payload 0x"
                << std::hex << payload << " at output " << std::dec
                << destination << " in cycle " << cycle;
            fail(oss.str());
        }
        if (it->second.source != source
            || it->second.destination != destination) {
            std::ostringstream oss;
            oss << fabric << " metadata mismatch for payload 0x" << std::hex
                << payload << ": expected source " << std::dec
                << it->second.source << " output " << it->second.destination
                << ", got source " << source << " output " << destination;
            fail(oss.str());
        }
        expected.erase(it);
        ++delivered_count;
    }

    static uint32_t ready_mask(unsigned outputs, unsigned cycle,
                               uint32_t& state) {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        const uint32_t width_mask = outputs == 32
                                  ? 0xffffffffu
                                  : ((uint32_t(1) << outputs) - 1);
        uint32_t ready = state & width_mask;
        // Hold the hot many-to-one output stalled long enough to fill the
        // registered stages, while allowing unrelated outputs to progress.
        if (cycle < 24)
            ready &= ~uint32_t(1);
        if ((cycle % 17) == 16)
            ready = width_mask;
        if (ready == 0 && cycle >= 24)
            ready = uint32_t(1) << (cycle % outputs);
        return ready;
    }

    static uint32_t sparse_ready_mask(unsigned outputs,
                                      unsigned destination,
                                      unsigned cycle) {
        const uint32_t width_mask = outputs == 32
                                  ? 0xffffffffu
                                  : ((uint32_t(1) << outputs) - 1);
        if (cycle < 12)
            return width_mask & ~(uint32_t(1) << destination);
        return width_mask;
    }

    static unsigned count_queued(const InputQueues& queues,
                                 unsigned num_inputs) {
        unsigned count = 0;
        for (unsigned input = 0; input < num_inputs; ++input)
            count += queues[input].size();
        return count;
    }

    static bool queues_empty(const InputQueues& queues,
                             unsigned num_inputs) {
        for (unsigned input = 0; input < num_inputs; ++input) {
            if (!queues[input].empty())
                return false;
        }
        return true;
    }

    static void check_counts(const char* name, unsigned total,
                             unsigned accepted, unsigned delivered) {
        if (accepted != total || delivered != total) {
            std::ostringstream oss;
            oss << name << " count mismatch: generated " << total
                << ", accepted " << accepted << ", delivered " << delivered;
            fail(oss.str());
        }
    }

    [[noreturn]] static void timeout(const char* name, size_t outstanding) {
        std::ostringstream oss;
        oss << name << " timed out with " << outstanding
            << " accepted transfers still outstanding";
        fail(oss.str());
    }

    void clock_cycle() {
        dut_.clk = 0;
        dut_.eval();
        clock_from_low();
    }

    void clock_from_low() {
        dut_.clk = 1;
        dut_.eval();
        ++timestamp;
        dut_.clk = 0;
        dut_.eval();
        ++timestamp;
    }

    VVX_stream_omega_top dut_;
    uint32_t random_state_req_ = 0x4d595df4u;
    uint32_t random_state_rsp_ = 0x9e3779b9u;
};

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

    OmegaTest test;
    test.reset();
    test.run_sparse_request_fabric();
    test.run_sparse_response_fabric();
    test.run_request_fabric();
    test.run_response_fabric();
    test.finish();

    std::cout << "PASSED: Omega 32-to-16 and 16-to-32 routing, exactly-once "
                 "delivery, source metadata, sustained valid, many-to-one "
                 "arbitration, and randomized output backpressure"
              << std::endl;
    std::cout << "Simulation time: " << timestamp / 2 << " cycles" << std::endl;
    return 0;
}
