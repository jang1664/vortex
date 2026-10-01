// Ordered host BO service. Only the VCS simulation thread calls serve_one().
#pragma once
#include "vcs_protocol.h"
#include <algorithm>
#include <array>
#include <cstring>
#include <exception>
#include <vector>

namespace u55c {

class MemoryClient {
public:
    explicit MemoryClient(int fd) : fd_(fd) {}
    int hello(const char* hash) {
        VcsPacket request{};
        request.type = MEM_HELLO;
        request.value = VCS_MEM_VERSION;
        request.size = 64;
        if (std::strlen(hash) != 64) return -1;
        return exchange(request, hash, nullptr);
    }
    int write(uint64_t addr, uint64_t size, const void* data) {
        return transfer(addr, size, const_cast<void*>(data), true);
    }
    int read(uint64_t addr, uint64_t size, void* data) {
        return transfer(addr, size, data, false);
    }
private:
    int transfer(uint64_t addr, uint64_t size, void* data, bool write) {
        constexpr uint64_t aperture = uint64_t(1) << 34;
        if (addr > aperture || size > aperture - addr) return -1;
        auto bytes = static_cast<uint8_t*>(data);
        while (size) {
            VcsPacket request{};
            request.type = write ? MEM_WRITE : MEM_READ;
            request.addr = addr;
            request.size = std::min<uint64_t>(size, VCS_MEM_MAX_PAYLOAD);
            if (exchange(request, write ? bytes : nullptr, write ? nullptr : bytes)) return -1;
            addr += request.size; size -= request.size; bytes += request.size;
        }
        return 0;
    }
    int exchange(VcsPacket request, const void* out, void* in) {
        request.id = ++sequence_;
        if (send_all(fd_, &request, sizeof(request))) return -1;
        if (out && send_all(fd_, out, request.size)) return -1;
        VcsPacket ack{};
        if (recv_all(fd_, &ack, sizeof(ack)) || ack.type != MEM_ACK
            || ack.id != request.id || ack.value || ack.size != (in ? request.size : 0)) return -1;
        return in ? recv_all(fd_, in, ack.size) : 0;
    }
    int fd_;
    uint32_t sequence_ = 0;
};

class MemoryService {
public:
    // Transport may block wall time for a partial frame, but never advances
    // simulated time. Payload allocation is bounded before reading any bytes.
    template <typename Model>
    int serve_one(int fd, Model& model, const char* hash) {
        VcsPacket request{}, ack{};
        if (recv_all(fd, &request, sizeof(request))) return -1;
        ack.type = MEM_ACK;
        ack.id = request.id;
        if (request.size > VCS_MEM_MAX_PAYLOAD) return -1;
        if (request.type == MEM_HELLO) {
            if (request.size != 64) return -1;
            std::array<char, 64> received{};
            if (recv_all(fd, received.data(), received.size())) return -1;
            hello_ = request.value == VCS_MEM_VERSION && std::strlen(hash) == 64
                && std::memcmp(hash, received.data(), 64) == 0;
            ack.value = hello_ ? 0 : 1;
            return send_all(fd, &ack, sizeof(ack));
        }
        if (!hello_ || (request.type != MEM_READ && request.type != MEM_WRITE)) return -1;
        std::vector<uint8_t> data(request.size);
        if (request.type == MEM_WRITE && recv_all(fd, data.data(), data.size())) return -1;
        try {
            if (request.type == MEM_WRITE) model.host_write(request.addr, data.data(), data.size());
            else model.host_read(request.addr, data.data(), data.size());
        } catch (const std::exception&) { ack.value = 2; }
        if (request.type == MEM_READ && !ack.value) ack.size = request.size;
        if (send_all(fd, &ack, sizeof(ack))) return -1;
        return ack.size ? send_all(fd, data.data(), data.size()) : 0;
    }
    bool connected() const { return hello_; }
private:
    bool hello_ = false;
};

// Return 1 for a control command, 0 for idle, -1 for a transport failure.
// A queued SHUTDOWN must win over memory EOF: the host closes both sockets
// immediately after sending it. Normal BO operations are synchronous and ACKed
// before the host sends their dependent control command.
template <typename Model>
int poll_host_command(int ctrl_fd, int mem_fd, MemoryService& service,
                      Model& model, const char* hash) {
    int control = sock_has_data(ctrl_fd);
    if (control != 0) return control;
    int memory = sock_has_data(mem_fd);
    if (memory < 0) return -1;
    if (memory > 0 && service.serve_one(mem_fd, model, hash)) return -1;
    return sock_has_data(ctrl_fd);
}

} // namespace u55c
