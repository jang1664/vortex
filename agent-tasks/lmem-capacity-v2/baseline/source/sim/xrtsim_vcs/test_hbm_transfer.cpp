#include "hbm_model.h"
#include "hbm_transfer.h"
#include <cassert>
#include <thread>
#include <unistd.h>
#include <iostream>

static void test_transport_termination(u55c::MemoryModel& model) {
    for (unsigned scenario = 0; scenario < 7; ++scenario) {
        int control[2], memory[2];
        assert(socketpair(AF_UNIX, SOCK_STREAM, 0, control) == 0);
        assert(socketpair(AF_UNIX, SOCK_STREAM, 0, memory) == 0);
        u55c::MemoryService service;
        auto poll = [&] {
            return u55c::poll_host_command(control[1], memory[1], service,
                                           model, U55C_MANIFEST_HASH);
        };
        assert(poll() == 0);
        VcsPacket packet{};
        if (scenario == 0) { // Abrupt control EOF cannot become idle forever.
            shutdown(control[0], SHUT_WR);
            assert(poll() == -1);
        } else if (scenario == 1) {
            shutdown(memory[0], SHUT_WR);
            assert(poll() == -1);
        } else if (scenario == 2) { // Normal host destructor order.
            packet.type = CMD_SHUTDOWN;
            assert(send_all(control[0], &packet, sizeof(packet)) == 0);
            shutdown(control[0], SHUT_WR);
            shutdown(memory[0], SHUT_WR);
            assert(poll() == 1);
            VcsPacket received{};
            assert(recv_all(control[1], &received, sizeof(received)) == 0);
            assert(received.type == CMD_SHUTDOWN);
        } else if (scenario == 3) {
            assert(send_all(control[0], &packet, 3) == 0);
            shutdown(control[0], SHUT_WR);
            assert(poll() == 1);
            assert(recv_all(control[1], &packet, sizeof(packet)) == -1);
        } else {
            packet.type = MEM_HELLO;
            packet.size = scenario == 4 ? VCS_MEM_MAX_PAYLOAD + 1 : 64;
            if (scenario == 6) packet.type = 0xff;
            assert(send_all(memory[0], &packet, sizeof(packet)) == 0);
            if (scenario == 5) { // Truncated hello payload.
                assert(send_all(memory[0], "abc", 3) == 0);
                shutdown(memory[0], SHUT_WR);
            }
            assert(poll() == -1);
        }
        close(control[0]); close(control[1]);
        close(memory[0]); close(memory[1]);
    }
}

static void test_transport_deadlines() {
    int fds[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0);
    char input[24]{};
    assert(send_all(fds[0], "abc", 3) == 0);
    auto start = std::chrono::steady_clock::now();
    assert(recv_all(fds[1], input, sizeof(input), 25) == -1);
    assert(errno == ETIMEDOUT);
    assert(std::chrono::steady_clock::now() - start < std::chrono::seconds(2));
    assert(std::memcmp(input, "abc", 3) == 0);
    // A peer that never drains its receive buffer must not block send forever.
    std::vector<uint8_t> large(8 << 20);
    start = std::chrono::steady_clock::now();
    assert(send_all(fds[0], large.data(), large.size(), 25) == -1);
    assert(errno == ETIMEDOUT);
    assert(std::chrono::steady_clock::now() - start < std::chrono::seconds(2));
    assert(recv_all(fds[1], input, 1, 0) == -1 && errno == EINVAL);
    close(fds[0]); close(fds[1]);
}

int main() {
    test_transport_deadlines();
    int fds[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0);
    u55c::MemoryModel model;
    u55c::MemoryService service;
    std::thread server([&] {
        while (service.serve_one(fds[1], model, U55C_MANIFEST_HASH) == 0) {}
    });
    u55c::MemoryClient client(fds[0]);
    assert(client.hello("0000000000000000000000000000000000000000000000000000000000000000") == -1);
    assert(client.hello(U55C_MANIFEST_HASH) == 0);
    std::vector<uint8_t> input(VCS_MEM_MAX_PAYLOAD + 123), output(input.size());
    for (unsigned i = 0; i < input.size(); ++i) input[i] = i * 17;
    // Chunking crosses a PC boundary without changing the physical byte view.
    uint64_t addr = (uint64_t(1) << 29) - 4096;
    assert(client.write(addr, input.size(), input.data()) == 0);
    assert(client.read(addr, output.size(), output.data()) == 0);
    assert(input == output);
    assert(client.read((uint64_t(1) << 34) - 1, 2, output.data()) == -1);
    shutdown(fds[0], SHUT_RDWR);
    server.join();
    close(fds[0]); close(fds[1]);
    assert(service.connected());
    assert(model.now_ps() == 0); // Transport itself has no device-time authority.
    test_transport_termination(model);
    assert(model.now_ps() == 0);
    std::cout << "HBM BO transfer and manifest handshake tests passed\n";
}
