#include "hbm_model.h"
#include <algorithm>
#include <stdexcept>

namespace u55c {

MemoryModel::MemoryModel()
    : ram_(0, 4096), scheduler_(U55C_HBM_AXI_FREQ_HZ, U55C_DRAM_TCK_PS) {
    reset(0);
}
MemoryModel::~MemoryModel() = default;

void MemoryModel::reset(uint64_t epoch) {
    dram_.reset();
    ports_ = {};
    dram_ = std::make_unique<vortex::DramSim>(vortex::DramSim::Profile::U55c);
    if (dram_->tck_ps() != U55C_DRAM_TCK_PS || dram_->transaction_bytes() != 32)
        throw std::runtime_error("Manifest disagrees with Ramulator timing/width");
    scheduler_.reset(epoch);
    request_rr_ = return_rr_ = 0;
    last_logic_ = epoch;
    has_logic_ = false;
}

void MemoryModel::aperture(uint64_t addr, uint64_t size) {
    constexpr uint64_t limit = uint64_t(1) << 34;
    if (addr > limit || size > limit - addr)
        throw std::out_of_range("HBM access outside 16 GiB aperture");
}
void MemoryModel::host_read(uint64_t addr, void* data, uint64_t size) {
    aperture(addr, size);
    ram_.read(data, addr, size);
}
void MemoryModel::host_write(uint64_t addr, const void* data, uint64_t size) {
    aperture(addr, size);
    ram_.write(data, addr, size);
}

void MemoryModel::validate(unsigned port, uint64_t addr, unsigned beats) const {
    ports_.at(port);
    if (!beats || beats > 64 || addr % data_bytes)
        throw std::invalid_argument("Only aligned full-width INCR bursts supported");
    uint64_t size = uint64_t(beats) * data_bytes;
    aperture(addr, size);
    if ((addr >> 12) != ((addr + size - 1) >> 12))
        throw std::invalid_argument("AXI burst crosses 4 KiB boundary");
    if ((addr >> 29) < u55c_config::first_pc[port]
        || ((addr + size - 1) >> 29) > u55c_config::last_pc[port])
        throw std::invalid_argument("AXI burst is outside manifest port reachability");
}
bool MemoryModel::ar_ready(unsigned p, unsigned beats) const {
    return beats && beats <= 64 && ports_.at(p).reads.size() + beats <= read_capacity;
}
bool MemoryModel::aw_ready(unsigned p) const { return ports_.at(p).writes.size() < write_capacity; }
bool MemoryModel::w_ready(unsigned p) const { return ports_.at(p).data.size() < w_capacity; }

void MemoryModel::ar(unsigned p, uint32_t id, uint64_t addr, unsigned beats) {
    validate(p, addr, beats);
    if (!ar_ready(p, beats)) throw std::logic_error("AR without reserved capacity");
    for (unsigned i = 0; i < beats; ++i) {
        auto beat = std::make_shared<Beat>();
        beat->owner = this; beat->port = p; beat->id = id;
        beat->addr = addr + i * data_bytes;
        beat->eligible_hbm = scheduler_.hbm_edges() + 2;
        beat->write = false; beat->last = i + 1 == beats;
        // Functional visibility is at accepted AR / associated W. Timing
        // requests do not mutate RAM, so buffered writes are consistently forwarded.
        ram_.read(beat->data.data(), beat->addr, data_bytes);
        ports_[p].reads.push_back(beat);
        ports_[p].requests.push_back(beat);
    }
}
void MemoryModel::aw(unsigned p, uint32_t id, uint64_t addr, unsigned beats) {
    validate(p, addr, beats);
    if (!aw_ready(p)) throw std::logic_error("AW without reserved capacity");
    auto burst = std::make_shared<Burst>();
    burst->id = id; burst->addr = addr; burst->beats = beats;
    ports_[p].addresses.push_back(burst);
    ports_[p].writes.push_back(burst);
    assemble(p);
}
void MemoryModel::w(unsigned p, const Data& data, uint64_t strobes, bool last) {
    if (!w_ready(p)) throw std::logic_error("W without reserved capacity");
    ports_[p].data.push_back({data, strobes, last});
    assemble(p);
}
void MemoryModel::assemble(unsigned p) {
    auto& port = ports_[p];
    while (!port.addresses.empty() && !port.data.empty()) {
        auto burst = port.addresses.front();
        auto data = port.data.front();
        bool last = burst->assembled + 1 == burst->beats;
        if (last != data.last) throw std::invalid_argument("AXI WLAST mismatch");
        auto beat = std::make_shared<Beat>();
        beat->owner = this; beat->port = p; beat->id = burst->id;
        beat->addr = burst->addr + data_bytes * burst->assembled;
        beat->eligible_hbm = scheduler_.hbm_edges() + 2;
        beat->write = true; beat->last = last; beat->burst = burst;
        for (unsigned byte = 0; byte < data_bytes; ++byte)
            if ((data.strobes >> byte) & 1)
                ram_.write(&data.data[byte], beat->addr + byte, 1);
        port.requests.push_back(beat);
        port.data.pop_front();
        ++burst->assembled;
        if (last) port.addresses.pop_front();
    }
}

void MemoryModel::complete(void* arg) {
    auto& beat = *static_cast<Beat*>(arg);
    ++beat.completed;
    beat.completion_time = beat.owner->now_ps();
}
void MemoryModel::hbm_edge(uint64_t time) {
    // Abstract paired-PC shared links, independent request/return directions.
    // Each port and physical-channel link services at most 32 bytes per edge.
    // This deliberately makes no claim about proprietary HMSS ingress wiring.
    std::array<bool, 16> request_link{}, return_link{};
    for (unsigned i = 0; i < ports_.size(); ++i) {
        unsigned p = (return_rr_ + i) % ports_.size();
        auto& q = ports_[p].returns;
        if (q.empty()) continue;
        auto beat = q.front();
        unsigned channel = beat->addr >> 30;
        if (beat->completed != 2 || beat->completion_time >= time) continue;
        if (beat->write) {
            // Each beat is timed at DRAM admission, but writes do not return
            // their data. Only the final beat reserves a B notification slot
            // on the return link (one slot per burst, not two per data beat).
            if (beat->last && return_link[channel]) continue;
            if (beat->last) return_link[channel] = true;
            ++beat->burst->returned;
            beat->burst->return_time = time;
            q.pop_front();
            continue;
        }
        if (return_link[channel]) continue;
        return_link[channel] = true;
        if (++beat->returned == 2) {
            beat->return_time = time;
            q.pop_front();
        }
    }
    for (unsigned i = 0; i < ports_.size(); ++i) {
        unsigned p = (request_rr_ + i) % ports_.size();
        auto& port = ports_[p];
        if (port.requests.empty()) continue;
        auto beat = port.requests.front();
        unsigned channel = beat->addr >> 30;
        if (beat->eligible_hbm > scheduler_.hbm_edges() || request_link[channel]) continue;
        if (!dram_->try_send_raw(beat->addr + 32 * beat->submitted, beat->write, complete, beat.get())) continue;
        request_link[channel] = true;
        if (++beat->submitted == 2) {
            port.returns.push_back(beat);
            port.requests.pop_front();
        }
    }
    request_rr_ = (request_rr_ + 1) % ports_.size();
    return_rr_ = (return_rr_ + 1) % ports_.size();
}

void MemoryModel::advance(uint64_t time) {
    scheduler_.advance(time, [&](Edge edge, uint64_t at) {
        if (edge == Edge::Dram) dram_->tick_raw();
        else hbm_edge(at);
    });
}
void MemoryModel::logic_edge(uint64_t time) {
    if (has_logic_ && time <= last_logic_) throw std::logic_error("Repeated/reversed logic edge");
    advance(time);
    last_logic_ = time;
    has_logic_ = true;
    for (auto& port : ports_) {
        for (auto& beat : port.reads)
            if (beat->returned == 2 && beat->return_time < time && beat->cdc < 2) ++beat->cdc;
        for (auto& burst : port.writes)
            if (burst->returned == burst->beats && burst->return_time < time && burst->cdc < 2) ++burst->cdc;
    }
}
bool MemoryModel::read_response(unsigned p, Response& response) const {
    auto& q = ports_.at(p).reads;
    if (q.empty() || q.front()->cdc != 2) return false;
    auto& beat = *q.front();
    response = {beat.id, beat.last, beat.data};
    return true;
}
bool MemoryModel::write_response(unsigned p, Response& response) const {
    auto& q = ports_.at(p).writes;
    if (q.empty() || q.front()->cdc != 2) return false;
    response = {q.front()->id, true, {}};
    return true;
}
void MemoryModel::pop_read(unsigned p) {
    Response response;
    if (!read_response(p, response)) throw std::logic_error("R consumed before ready");
    ports_[p].reads.pop_front();
}
void MemoryModel::pop_write(unsigned p) {
    Response response;
    if (!write_response(p, response)) throw std::logic_error("B consumed before ready");
    ports_[p].writes.pop_front();
}
} // namespace u55c
