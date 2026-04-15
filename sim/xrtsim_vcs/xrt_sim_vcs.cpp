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
// RAM, DramSim, and MemoryAllocator live in this App process.

#include "xrt_sim.h"
#include "vcs_protocol.h"

#include <iostream>
#include <mem.h>
#include <dram_sim.h>
#include <VX_config.h>
#include <mem_alloc.h>

#include <future>
#include <list>
#include <queue>
#include <array>
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

#ifndef MEM_CLOCK_RATIO
#define MEM_CLOCK_RATIO 1
#endif

#define RAM_PAGE_SIZE 4096
#define CACHE_BLOCK_SIZE 64

using namespace vortex;

///////////////////////////////////////////////////////////////////////////////

class xrt_sim::Impl {
public:
  Impl()
    : ram_(nullptr)
    , dram_sim_(NUM_DMA_CHANNELS, PLATFORM_MEMORY_DATA_SIZE, MEM_CLOCK_RATIO)
    , stop_(false)
    , ctrl_fd_(-1)
    , mem_fd_(-1)
  {}

  ~Impl() {
    stop_ = true;
    if (future_.valid()) {
      future_.wait();
    }
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
    if (ram_) {
      delete ram_;
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

    // Allocate RAM
    ram_ = new RAM(0, RAM_PAGE_SIZE);

    // Initialize memory allocators (one per HBM bank)
    for (int b = 0; b < PLATFORM_MEMORY_NUM_BANKS; ++b) {
      mem_alloc_[b] = new MemoryAllocator(0, mem_bank_size_, 4096, 64);
    }

    // Launch sim thread for AXI memory event processing
    future_ = std::async(std::launch::async, [&]{
      while (!stop_) {
        std::lock_guard<std::mutex> guard(mutex_);
        this->process_axi_events();
      }
    });

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
    // Reconstruct flat software address from (bank_id, per-bank offset).
    // This matches how the RTL's AXI addresses map to RAM.
    uint64_t flat_addr = to_software_addr(bank_id, addr);
    ram_->write(data, flat_addr, size);
    return 0;
  }

  int mem_read(uint32_t bank_id, uint64_t addr, uint64_t size, void* data) {
    std::lock_guard<std::mutex> guard(mutex_);

    if (bank_id >= PLATFORM_MEMORY_NUM_BANKS)
      return -1;
    uint64_t flat_addr = to_software_addr(bank_id, addr);
    ram_->read(data, flat_addr, size);
    return 0;
  }

  int register_write(uint32_t offset, uint32_t value) {
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

  typedef struct {
    std::array<uint8_t, PLATFORM_MEMORY_DATA_SIZE> data;
    uint32_t tag;
    uint64_t addr;
    uint8_t  port;
    bool write;
    bool ready;
  } mem_req_t;

  using mem_req_list_t = std::list<mem_req_t*>;
  using mem_req_iter_t = mem_req_list_t::iterator;

  // AW state for two-phase write handling (per bank)
  typedef struct {
    uint64_t addr;
    uint32_t tag;
    bool     valid;
  } aw_state_t;

  // Reconstruct flat software address from (bank_id, per-bank offset).
  // Runtime's get_bank_info (BANK_INTERLEAVE ON) decomposes:
  //   bank   = (addr / CACHE_BLOCK_SIZE) % num_banks
  //   offset = (addr / CACHE_BLOCK_SIZE / num_banks) * CACHE_BLOCK_SIZE
  // Reverse: addr = (offset / CBS * num_banks + bank) * CBS
  uint64_t to_software_addr(uint32_t bank_id, uint64_t offset) {
    uint64_t block_in_bank = offset / CACHE_BLOCK_SIZE;
    return (block_in_bank * PLATFORM_MEMORY_NUM_BANKS + bank_id) * CACHE_BLOCK_SIZE;
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

  mem_req_iter_t find_ready_mem_rsp(int port) {
    auto& pending_reqs = pending_mem_reqs_[port];
    for (auto it = pending_reqs.begin(); it != pending_reqs.end(); ++it) {
      auto req = *it;
      if (!req->ready) {
        continue;
      }

      // AXI allows out-of-order completion across IDs, but responses with the
      // same ID must remain ordered.
      bool blocked_by_same_id = false;
      for (auto prev = pending_reqs.begin(); prev != it; ++prev) {
        if ((*prev)->tag == req->tag) {
          blocked_by_same_id = true;
          break;
        }
      }
      if (!blocked_by_same_id) {
        return it;
      }
    }
    return pending_reqs.end();
  }

  void process_axi_events() {
    // 1. Receive AXI events from VCS via mem_sock (non-blocking)
    while (sock_has_data(mem_fd_) > 0) {
      VcsPacket pkt;
      if (recv_all(mem_fd_, &pkt, sizeof(pkt)) < 0) {
        fprintf(stderr, "[vcs-sim] mem recv error\n");
        stop_ = true;
        return;
      }

      switch (pkt.type) {
        case EVT_AXI_AR: {
          // Read request from DUT
          auto mem_req = new mem_req_t();
          mem_req->tag   = pkt.id;
          mem_req->addr  = pkt.addr;
          mem_req->port  = pkt.port_id;
          mem_req->write = false;
          mem_req->ready = false;
          // Read data from local RAM using AXI address directly
          // (AXI addr == software addr, see docs/port-scale/CAUTION.md #1)
          ram_->read(mem_req->data.data(), pkt.addr, PLATFORM_MEMORY_DATA_SIZE);
          pending_mem_reqs_[pkt.port_id].emplace_back(mem_req);
          dram_queues_[pkt.port_id].push(mem_req);
          break;
        }
        case EVT_AXI_AW: {
          // Write address from DUT (AXI addr == software addr)
          aw_state_[pkt.port_id].addr  = pkt.addr;
          aw_state_[pkt.port_id].tag   = pkt.id;
          aw_state_[pkt.port_id].valid = true;
          break;
        }
        case EVT_AXI_W: {
          // Write data from DUT
          uint8_t data_buf[PLATFORM_MEMORY_DATA_SIZE];
          if (pkt.size > 0) {
            if (recv_all(mem_fd_, data_buf, pkt.size) < 0) {
              fprintf(stderr, "[vcs-sim] mem recv W data error\n");
              stop_ = true;
              return;
            }
          }

          uint8_t port = pkt.port_id;
          if (aw_state_[port].valid) {
            uint64_t byte_addr = aw_state_[port].addr;
            uint64_t strb = pkt.addr; // strb is stored in addr field

            // Write with byte enables
            for (int i = 0; i < PLATFORM_MEMORY_DATA_SIZE; ++i) {
              if ((strb >> i) & 0x1) {
                (*ram_)[byte_addr + i] = data_buf[i];
              }
            }

            auto mem_req = new mem_req_t();
            mem_req->tag   = aw_state_[port].tag;
            mem_req->addr  = byte_addr;
            mem_req->port  = port;
            mem_req->write = true;
            mem_req->ready = false;
            pending_mem_reqs_[port].emplace_back(mem_req);
            dram_queues_[port].push(mem_req);

            aw_state_[port].valid = false;
          }
          break;
        }
        default:
          fprintf(stderr, "[vcs-sim] unexpected mem event type 0x%02x\n", pkt.type);
          break;
      }
    }

    // 2. DramSim tick + drain DRAM queues
    dram_sim_.tick();

    for (int b = 0; b < NUM_DMA_CHANNELS; ++b) {
      if (!dram_queues_[b].empty()) {
        auto mem_req = dram_queues_[b].front();
        dram_sim_.send_request(mem_req->addr, mem_req->write, [](void* arg) {
          auto orig_req = reinterpret_cast<mem_req_t*>(arg);
          if (orig_req->ready) {
            delete orig_req;
          } else {
            orig_req->ready = true;
          }
        }, mem_req);
        dram_queues_[b].pop();
      }
    }

    // 3. Send ready responses back to VCS via mem_sock
    for (int b = 0; b < NUM_DMA_CHANNELS; ++b) {
      while (true) {
        auto it = find_ready_mem_rsp(b);
        if (it == pending_mem_reqs_[b].end()) {
          break;
        }

        auto mem_req = *it;

        VcsPacket rsp;
        memset(&rsp, 0, sizeof(rsp));
        rsp.port_id = (uint8_t)b;
        rsp.id      = mem_req->tag;

        if (mem_req->write) {
          // Write response (B channel)
          rsp.type  = RSP_AXI_B;
          rsp.size  = 0;
          rsp.value = 1; // last
          if (send_all(mem_fd_, &rsp, sizeof(rsp)) < 0) {
            fprintf(stderr, "[vcs-sim] send B response error\n");
            stop_ = true;
            return;
          }
        } else {
          // Read response (R channel)
          rsp.type  = RSP_AXI_R;
          rsp.size  = PLATFORM_MEMORY_DATA_SIZE;
          rsp.value = 1; // last
          if (send_all(mem_fd_, &rsp, sizeof(rsp)) < 0) {
            fprintf(stderr, "[vcs-sim] send R response header error\n");
            stop_ = true;
            return;
          }
          if (send_all(mem_fd_, mem_req->data.data(), PLATFORM_MEMORY_DATA_SIZE) < 0) {
            fprintf(stderr, "[vcs-sim] send R response data error\n");
            stop_ = true;
            return;
          }
        }

        it = pending_mem_reqs_[b].erase(it);
        delete mem_req;
      }
    }
  }

  RAM* ram_;
  DramSim dram_sim_;
  uint64_t mem_bank_size_;

  std::future<void> future_;
  bool stop_;
  std::mutex mutex_;

  int ctrl_fd_;
  int mem_fd_;

  MemoryAllocator* mem_alloc_[PLATFORM_MEMORY_NUM_BANKS];  // per HBM bank (32)
  mem_req_list_t pending_mem_reqs_[NUM_DMA_CHANNELS];      // per AXI port (8)
  std::queue<mem_req_t*> dram_queues_[NUM_DMA_CHANNELS];   // per AXI port (8)
  aw_state_t aw_state_[NUM_DMA_CHANNELS];                  // per AXI port (8)
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
