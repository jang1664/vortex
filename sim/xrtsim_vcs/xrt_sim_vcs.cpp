// Copyright © 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// VCS co-simulation backend for xrt_sim.
// Communicates with VCS testbench via two TCP sockets (ctrl + mem).
// Only BO allocation bookkeeping lives here; VCS owns device RAM and time.

#include "xrt_sim.h"
#include "vcs_protocol.h"
#include "hbm_transfer.h"
#include "u55c_model_config.h"

#include <iostream>
#include <VX_config.h>
#include <mem_alloc.h>

#include <mutex>
#include <cstdlib>
#include <cstring>
#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <errno.h>


using namespace vortex;

///////////////////////////////////////////////////////////////////////////////

class xrt_sim::Impl {
public:
  Impl() : ctrl_fd_(-1), mem_fd_(-1) {}

  ~Impl() {
    // Send shutdown to VCS
    if (ctrl_fd_ >= 0) {
      VcsPacket pkt;
      memset(&pkt, 0, sizeof(pkt));
      pkt.type = CMD_SHUTDOWN;
      send_all(ctrl_fd_, &pkt, sizeof(pkt));
      close(ctrl_fd_);
      ctrl_fd_ = -1;
    }
    if (mem_fd_ >= 0) {
      close(mem_fd_);
      mem_fd_ = -1;
    }
    for (int b = 0; b < PLATFORM_MEMORY_NUM_BANKS; ++b) {
      delete mem_alloc_[b];
    }
  }

  int init() {
    // Read socket port from environment
    int port = 9999;
    if (auto env = std::getenv("VCS_SOCKET_PORT")) {
      port = std::atoi(env);
    }

    printf("[vcs-sim] connecting to VCS at port %d/%d...\n", port, port + 1);

    // Connect ctrl socket
    ctrl_fd_ = connect_with_retry("127.0.0.1", port, 30);
    if (ctrl_fd_ < 0) {
      fprintf(stderr, "[vcs-sim] failed to connect ctrl socket\n");
      return -1;
    }
    printf("[vcs-sim] ctrl socket connected\n");

    // Connect mem socket
    mem_fd_ = connect_with_retry("127.0.0.1", port + 1, 30);
    if (mem_fd_ < 0) {
      fprintf(stderr, "[vcs-sim] failed to connect mem socket\n");
      return -1;
    }
    printf("[vcs-sim] mem socket connected\n");

    // Calculate memory bank size (32 HBM banks, not 8 AXI ports)
    mem_bank_size_ = (1ull << PLATFORM_MEMORY_ADDR_WIDTH) / PLATFORM_MEMORY_NUM_BANKS;

    u55c::MemoryClient client(mem_fd_);
    if (client.hello(U55C_MANIFEST_HASH)) {
      fprintf(stderr, "[vcs-sim] incompatible memory protocol or manifest\n");
      return -1;
    }

    // Initialize memory allocators (one per HBM bank)
    for (int b = 0; b < PLATFORM_MEMORY_NUM_BANKS; ++b) {
      mem_alloc_[b] = new MemoryAllocator(0, mem_bank_size_, 4096, 64);
    }

    return 0;
  }

  int mem_alloc(uint64_t size, uint32_t bank_id, uint64_t* addr) {
    if (bank_id >= PLATFORM_MEMORY_NUM_BANKS)
      return -1;
    return mem_alloc_[bank_id]->allocate(size, addr);
  }

  int mem_free(uint32_t bank_id, uint64_t addr) {
    if (bank_id >= PLATFORM_MEMORY_NUM_BANKS)
      return -1;
    return mem_alloc_[bank_id]->release(addr);
  }

  int mem_write(uint32_t bank_id, uint64_t addr, uint64_t size, const void* data) {
    std::lock_guard<std::mutex> guard(mutex_);

    if (bank_id >= PLATFORM_MEMORY_NUM_BANKS)
      return -1;
    // Flat RAM address from (bank_id, per-bank offset), using the HBM
    // bank-contiguous layout that RTL AXI addrs also index directly.
    uint64_t flat_addr = to_software_addr(bank_id, addr);
    if (addr > mem_bank_size_ || size > mem_bank_size_ - addr) return -1;
    u55c::MemoryClient client(mem_fd_);
    return client.write(flat_addr, size, data);
  }

  int mem_read(uint32_t bank_id, uint64_t addr, uint64_t size, void* data) {
    std::lock_guard<std::mutex> guard(mutex_);

    if (bank_id >= PLATFORM_MEMORY_NUM_BANKS)
      return -1;
    uint64_t flat_addr = to_software_addr(bank_id, addr);
    if (addr > mem_bank_size_ || size > mem_bank_size_ - addr) return -1;
    u55c::MemoryClient client(mem_fd_);
    return client.read(flat_addr, size, data);
  }

  int register_write(uint32_t offset, uint32_t value) {
    std::lock_guard<std::mutex> guard(mutex_);
    // Send CMD_REG_WRITE via ctrl_sock (no mutex needed, separate socket)
    VcsPacket pkt;
    memset(&pkt, 0, sizeof(pkt));
    pkt.type  = CMD_REG_WRITE;
    pkt.id    = offset;
    pkt.value = value;

    if (send_all(ctrl_fd_, &pkt, sizeof(pkt)) < 0) {
      fprintf(stderr, "[vcs-sim] register_write: send failed\n");
      return -1;
    }

    // Wait for ACK
    VcsPacket ack;
    if (recv_all(ctrl_fd_, &ack, sizeof(ack)) < 0) {
      fprintf(stderr, "[vcs-sim] register_write: recv ACK failed\n");
      return -1;
    }
    if (ack.type != CMD_REG_WRITE_ACK) {
      fprintf(stderr, "[vcs-sim] register_write: unexpected response type 0x%02x\n", ack.type);
      return -1;
    }

    return 0;
  }

  int register_read(uint32_t offset, uint32_t* value) {
    std::lock_guard<std::mutex> guard(mutex_);
    // Send CMD_REG_READ via ctrl_sock
    VcsPacket pkt;
    memset(&pkt, 0, sizeof(pkt));
    pkt.type = CMD_REG_READ;
    pkt.id   = offset;

    if (send_all(ctrl_fd_, &pkt, sizeof(pkt)) < 0) {
      fprintf(stderr, "[vcs-sim] register_read: send failed\n");
      return -1;
    }

    // Wait for response
    VcsPacket rsp;
    if (recv_all(ctrl_fd_, &rsp, sizeof(rsp)) < 0) {
      fprintf(stderr, "[vcs-sim] register_read: recv failed\n");
      return -1;
    }
    if (rsp.type != CMD_REG_READ_RESP) {
      fprintf(stderr, "[vcs-sim] register_read: unexpected response type 0x%02x\n", rsp.type);
      return -1;
    }

    *value = rsp.value;
    return 0;
  }

private:

  // Flat RAM address from (bank_id, per-bank offset). HBM layout is fixed
  // bank-contiguous from the PC's view: bank i occupies a slice of size
  // mem_bank_size_ starting at i*mem_bank_size_. Whatever decomposition
  // the runtime uses (INTERLEAVE on/off) only affects how it splits a
  // device address into (bank_id, offset) — the backend always stores
  // data in this bank-contiguous layout, and RTL AXI addrs index ram_
  // directly with the same view.
  uint64_t to_software_addr(uint32_t bank_id, uint64_t offset) {
    return (uint64_t)bank_id * mem_bank_size_ + offset;
  }

  static int connect_with_retry(const char* host, int port, int timeout_sec) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
      perror("[vcs-sim] socket");
      return -1;
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    inet_pton(AF_INET, host, &addr.sin_addr);

    for (int i = 0; i < timeout_sec; ++i) {
      if (connect(fd, (struct sockaddr*)&addr, sizeof(addr)) == 0) {
        // Disable Nagle
        int opt = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &opt, sizeof(opt));
        return fd;
      }
      if (errno != ECONNREFUSED) {
        perror("[vcs-sim] connect");
        close(fd);
        return -1;
      }
      sleep(1);
    }
    fprintf(stderr, "[vcs-sim] connect timeout after %d seconds\n", timeout_sec);
    close(fd);
    return -1;
  }

  uint64_t mem_bank_size_;

  std::mutex mutex_;

  int ctrl_fd_;
  int mem_fd_;

  MemoryAllocator* mem_alloc_[PLATFORM_MEMORY_NUM_BANKS]{};
};

///////////////////////////////////////////////////////////////////////////////

xrt_sim::xrt_sim()
  : impl_(new Impl())
{}

xrt_sim::~xrt_sim() {
  delete impl_;
}

int xrt_sim::init() {
  return impl_->init();
}

int xrt_sim::mem_alloc(uint64_t size, uint32_t bank_id, uint64_t* addr) {
  return impl_->mem_alloc(size, bank_id, addr);
}

int xrt_sim::mem_free(uint32_t bank_id, uint64_t addr) {
  return impl_->mem_free(bank_id, addr);
}

int xrt_sim::mem_write(uint32_t bank_id, uint64_t addr, uint64_t size, const void* data) {
  return impl_->mem_write(bank_id, addr, size, data);
}

int xrt_sim::mem_read(uint32_t bank_id, uint64_t addr, uint64_t size, void* data) {
  return impl_->mem_read(bank_id, addr, size, data);
}

int xrt_sim::register_write(uint32_t offset, uint32_t value) {
  return impl_->register_write(offset, value);
}

int xrt_sim::register_read(uint32_t offset, uint32_t* value) {
  return impl_->register_read(offset, value);
}
