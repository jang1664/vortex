// Single-threaded transaction-level U55C model, owned by the VCS DPI process.
#pragma once
#include "dram_sim.h"
#include "hbm_clock.h"
#include "mem.h"
#include "u55c_model_config.h"
#include <array>
#include <deque>
#include <memory>
#include <vector>

namespace u55c {

class MemoryModel {
public:
    static constexpr unsigned data_bytes = 64;
    static constexpr unsigned read_capacity = 256;
    static constexpr unsigned write_capacity = 16;
    static constexpr unsigned w_capacity = 64;
    using Data = std::array<uint8_t, data_bytes>;
    struct Response { uint32_t id; bool last; Data data; };

    MemoryModel();
    ~MemoryModel();
    void reset(uint64_t epoch_ps); // Cancels timing work, preserves host-visible RAM.
    void advance(uint64_t time_ps);
    void logic_edge(uint64_t time_ps);
    bool ar_ready(unsigned port, unsigned beats) const;
    bool aw_ready(unsigned port) const;
    bool w_ready(unsigned port) const;
    void ar(unsigned port, uint32_t id, uint64_t addr, unsigned beats);
    void aw(unsigned port, uint32_t id, uint64_t addr, unsigned beats);
    void w(unsigned port, const Data& data, uint64_t strobes, bool last);
    bool read_response(unsigned port, Response& response) const;
    bool write_response(unsigned port, Response& response) const;
    void pop_read(unsigned port);
    void pop_write(unsigned port);
    void host_read(uint64_t addr, void* data, uint64_t size);
    void host_write(uint64_t addr, const void* data, uint64_t size);
    uint64_t now_ps() const { return scheduler_.now_ps(); }
    uint64_t dram_edges() const { return scheduler_.dram_edges(); }

private:
    struct Burst {
        uint32_t id;
        uint64_t addr;
        unsigned beats, assembled = 0, returned = 0, cdc = 0;
        uint64_t return_time = 0;
    };
    struct Beat {
        MemoryModel* owner;
        unsigned port;
        uint32_t id;
        uint64_t addr, eligible_hbm;
        bool write, last;
        Data data{};
        unsigned submitted = 0, completed = 0, returned = 0, cdc = 0;
        uint64_t completion_time = 0, return_time = 0;
        std::shared_ptr<Burst> burst;
    };
    struct W { Data data; uint64_t strobes; bool last; };
    struct Port {
        std::deque<std::shared_ptr<Beat>> requests, returns, reads;
        std::deque<std::shared_ptr<Burst>> addresses, writes;
        std::deque<W> data;
    };
    static void aperture(uint64_t addr, uint64_t size);
    void validate(unsigned port, uint64_t addr, unsigned beats) const;
    void assemble(unsigned port);
    void hbm_edge(uint64_t time);
    static void complete(void* arg);
    std::array<Port, U55C_NUM_PORTS> ports_{};
    vortex::RAM ram_;
    Scheduler scheduler_;
    // Destroy Ramulator before request storage, so callbacks never outlive it.
    std::unique_ptr<vortex::DramSim> dram_;
    unsigned request_rr_ = 0, return_rr_ = 0;
    uint64_t last_logic_ = 0;
    bool has_logic_ = false;
};

} // namespace u55c
