#include "hbm_model.h"
#include <cassert>
#include <iostream>

int main() {
    u55c::MemoryModel model;
    using Data = u55c::MemoryModel::Data;
    using Response = u55c::MemoryModel::Response;
    uint64_t time = 0;
    auto tick = [&] { time += 4000; model.logic_edge(time); };
    auto wait_read = [&](unsigned p, Response& r) {
        for (unsigned i = 0; i < 10000; ++i) {
            if (model.read_response(p, r)) return;
            tick();
        }
        assert(false && "read timeout");
    };
    Data initial{}, written{};
    std::array<Data, 32> pc_values{};
    for (unsigned i = 0; i < 64; ++i) { initial[i] = i; written[i] = 255 - i; }
    // Round trip every manifest PC, including its final aligned beat.
    for (unsigned p = 0; p < U55C_NUM_PORTS; ++p) {
        for (unsigned pc = u55c_config::first_pc[p]; pc <= u55c_config::last_pc[p]; ++pc) {
            uint64_t addr = (uint64_t(pc + 1) << 29) - 64;
            Data pc_initial{};
            for (unsigned byte = 0; byte < 64; ++byte) {
                pc_initial[byte] = pc * 7 + byte;
                pc_values[pc][byte] = pc * 11 + 255 - byte;
            }
            model.host_write(addr, pc_initial.data(), pc_initial.size());
            model.ar(p, pc, addr, 1);
            Response r;
            wait_read(p, r);
            assert(r.id == pc && r.last && r.data == pc_initial);
            model.pop_read(p);
            // Exercise the DUT-side write timing and address path on every PC,
            // not only a host initialization followed by an AXI read.
            model.aw(p, 100 + pc, addr, 1);
            model.w(p, pc_values[pc], ~uint64_t(0), true);
            for (unsigned i = 0; i < 10000 && !model.write_response(p, r); ++i) tick();
            assert(model.write_response(p, r) && r.id == 100 + pc);
            model.pop_write(p);
            model.ar(p, 200 + pc, addr, 1);
            wait_read(p, r);
            assert(r.id == 200 + pc && r.last && r.data == pc_values[pc]);
            model.pop_read(p);
        }
    }
    // Distinct per-PC patterns must survive writes to all later PCs, catching
    // aliasing that identical initialization data on every PC would conceal.
    for (unsigned pc = 0; pc < 32; ++pc) {
        Data value{};
        model.host_read((uint64_t(pc + 1) << 29) - 64, value.data(), value.size());
        assert(value == pc_values[pc]);
    }
    // W may precede AW. Strobes and both beats become visible on association.
    model.host_write(0, initial.data(), 64);
    model.host_write(64, initial.data(), 64);
    model.w(0, written, 0x5555555555555555ULL, false);
    model.w(0, written, ~uint64_t(0), true);
    model.aw(0, 7, 0, 2);
    model.ar(0, 7, 0, 2);
    Response r;
    wait_read(0, r);
    assert(!r.last && r.id == 7);
    for (unsigned i = 0; i < 64; ++i) assert(r.data[i] == (i % 2 ? initial[i] : written[i]));
    // Held R must remain stable while the rest of the model progresses.
    auto held = r;
    for (unsigned i = 0; i < 10; ++i) tick();
    assert(model.read_response(0, r) && r.data == held.data && r.id == held.id);
    model.pop_read(0);
    wait_read(0, r);
    assert(r.last && r.data == written);
    model.pop_read(0);
    for (unsigned i = 0; i < 10000 && !model.write_response(0, r); ++i) tick();
    assert(model.write_response(0, r) && r.id == 7);
    model.pop_write(0);
    assert(!model.write_response(0, r));

    // Admission reserves all read responses, even before timing completes.
    for (unsigned i = 0; i < 4; ++i) model.ar(0, i, 0, 64);
    assert(!model.ar_ready(0, 1));
    for (unsigned i = 0; i < 256; ++i) {
        wait_read(0, r);
        assert(r.id == i / 64 && r.last == (i % 64 == 63));
        model.pop_read(0);
    }
    assert(model.ar_ready(0, 64));
    for (unsigned i = 0; i < model.write_capacity; ++i) model.aw(0, i, 0, 1);
    assert(!model.aw_ready(0));
    // Reset cancels outstanding work and recreates Ramulator; RAM survives.
    model.reset(time);
    assert(model.aw_ready(0) && model.ar_ready(0, 64));
    Data after{};
    model.host_read(64, after.data(), 64);
    assert(after == written);
    for (unsigned i = 0; i < model.w_capacity; ++i) model.w(0, initial, 0, true);
    assert(!model.w_ready(0));
    model.reset(time);
    bool rejected = false;
    try { model.ar(0, 1, 4096 - 64, 2); }
    catch (const std::invalid_argument&) { rejected = true; }
    assert(rejected);
    rejected = false;
    try { model.ar(0, 1, uint64_t(u55c_config::last_pc[0] + 1) << 29, 1); }
    catch (const std::invalid_argument&) { rejected = true; }
    assert(rejected);
    auto edges = model.dram_edges();
    for (unsigned i = 0; i < 1000; ++i) tick();
    assert(model.dram_edges() == edges + 4000000ULL * U55C_DRAM_FREQ_HZ / 1000000000000ULL);
    // Idle refresh still advances at the configured physical frequency.
    std::cout << "HBM memory model tests passed\n";
}
