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
    // Flat RAM address from (bank_id, per-bank offset), using the HBM
    // bank-contiguous layout that RTL AXI addrs also index directly.
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
    bool is_last;  // AXI r_last: true on the final beat of the burst
  } mem_req_t;

  using mem_req_list_t = std::list<mem_req_t*>;
  using mem_req_iter_t = mem_req_list_t::iterator;

  // AW state for two-phase write handling. AXI permits multiple write
  // addresses to be accepted before their W bursts, so each port keeps these
  // states in handshake order and consumes the front state on WLAST.
  typedef struct {
    uint64_t base_addr;
    uint32_t tag;
    uint32_t beat_idx;
    uint32_t beat_count;
  } aw_state_t;

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

  // Per-port HBM address-range assertion.
  //   platforms.mk sp maps m_axi_mem_i -> HBM[4i:4i+3], so any AXI address
  //   emitted on port i must lie inside the 4-PC window
  //     [ (4*i)   * mem_bank_size_,
  //       (4*i+4) * mem_bank_size_ )
  //   which is the port's 4-PC contiguous slice after the new VX_mem_remap
  //   packing (bank_idx top PORT_BITS == port index).
  //   A violation means DMA ctrl routed a channel's transaction to the wrong
  //   HBM port (or a stray LSU access with misaligned base). Aborts so the
  //   failure is obvious.
  void assert_port_range(uint8_t port_id, uint64_t addr) {
    constexpr uint32_t BANKS_PER_PORT =
        PLATFORM_MEMORY_NUM_BANKS / NUM_DMA_CHANNELS;
    const uint64_t port_base =
        (uint64_t)port_id * BANKS_PER_PORT * mem_bank_size_;
    const uint64_t port_top =
        port_base + (uint64_t)BANKS_PER_PORT * mem_bank_size_;
    if (addr < port_base || addr >= port_top) {
      fprintf(stderr,
              "[vcs-sim] FATAL: AXI addr 0x%lx on port %u is outside its "
              "HBM window [0x%lx, 0x%lx)  (bank_size=0x%lx, banks_per_port=%u)\n",
              (unsigned long)addr, (unsigned)port_id,
              (unsigned long)port_base, (unsigned long)port_top,
              (unsigned long)mem_bank_size_, (unsigned)BANKS_PER_PORT);
      fflush(stderr);
      abort();
    }
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
          // Read request from DUT. Expand into (arlen+1) beat requests so the
          // R channel returns the full burst. AXI burst type for Vortex DMA
          // is INCR with size=LOG2(DATA_SIZE), so each beat address
          // increments by PLATFORM_MEMORY_DATA_SIZE bytes.
          uint32_t beat_count = pkt.value + 1; // pkt.value carries arlen
          for (uint32_t b = 0; b < beat_count; ++b) {
            uint64_t beat_addr = pkt.addr
                               + (uint64_t)b * PLATFORM_MEMORY_DATA_SIZE;
            // Catch mis-routed read bursts — any AR from port i must stay
            // inside that port's 4-PC HBM window (see assert_port_range).
            assert_port_range(pkt.port_id, beat_addr);
            auto mem_req = new mem_req_t();
            mem_req->tag     = pkt.id;
            mem_req->addr    = beat_addr;
            mem_req->port    = pkt.port_id;
            mem_req->write   = false;
            mem_req->ready   = false;
            mem_req->is_last = (b + 1 == beat_count);
            // AXI addr is already in the HBM bank-contiguous view that ram_
            // uses; no conversion needed. The host upload path writes via
            // mem_write -> to_software_addr into the same layout.
            ram_->read(mem_req->data.data(), beat_addr, PLATFORM_MEMORY_DATA_SIZE);
            pending_mem_reqs_[pkt.port_id].emplace_back(mem_req);
            dram_queues_[pkt.port_id].push(mem_req);
          }
          break;
        }
        case EVT_AXI_AW: {
          // Write address from DUT. pkt.value carries awlen; beats for the
          // burst are accumulated in EVT_AXI_W using beat_idx.
          // Catch mis-routed write bursts at AW (burst ≤ 4KB < 512MB bank,
          // so if the base is inside the port's window, all beats are too).
          assert_port_range(pkt.port_id, pkt.addr);
          aw_state_t state;
          state.base_addr = pkt.addr;
          state.tag       = pkt.id;
          state.beat_idx  = 0;
          state.beat_count = pkt.value + 1;
          aw_queues_[pkt.port_id].push(state);
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
          if (aw_queues_[port].empty()) {
            fprintf(stderr, "[vcs-sim] AXI W without AW: port=%u last=%u\n",
                    port, pkt.value);
            stop_ = true;
            return;
          }

          auto& aw_state = aw_queues_[port].front();
          {
            // Beat address for this W within the burst (INCR). AXI addr is
            // already in the HBM bank-contiguous view that ram_ uses.
            uint64_t axi_addr = aw_state.base_addr
                              + (uint64_t)aw_state.beat_idx
                                * PLATFORM_MEMORY_DATA_SIZE;
            uint64_t strb = pkt.addr; // strb is stored in addr field
            bool w_last = (pkt.value != 0);
            bool expected_last = (aw_state.beat_idx + 1 == aw_state.beat_count);

            if (w_last != expected_last) {
              fprintf(stderr,
                      "[vcs-sim] AXI WLAST mismatch: port=%u beat=%u beats=%u last=%u\n",
                      port, aw_state.beat_idx, aw_state.beat_count, w_last);
              stop_ = true;
              return;
            }

            // Write with byte enables
            for (int i = 0; i < PLATFORM_MEMORY_DATA_SIZE; ++i) {
              if ((strb >> i) & 0x1) {
                (*ram_)[axi_addr + i] = data_buf[i];
              }
            }

            // Issue exactly one B response per AW burst — on wlast.
            if (w_last) {
              auto mem_req = new mem_req_t();
              mem_req->tag     = aw_state.tag;
              mem_req->addr    = aw_state.base_addr;
              mem_req->port    = port;
              mem_req->write   = true;
              mem_req->ready   = false;
              mem_req->is_last = true;
              pending_mem_reqs_[port].emplace_back(mem_req);
              dram_queues_[port].push(mem_req);

              aw_queues_[port].pop();
            } else {
              aw_state.beat_idx++;
            }
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
          // Write response (B channel) — one per AW burst, so always last.
          rsp.type  = RSP_AXI_B;
          rsp.size  = 0;
          rsp.value = 1; // last
          if (send_all(mem_fd_, &rsp, sizeof(rsp)) < 0) {
            fprintf(stderr, "[vcs-sim] send B response error\n");
            stop_ = true;
            return;
          }
        } else {
          // Read response (R channel) — one per beat in the burst.
          rsp.type  = RSP_AXI_R;
          rsp.size  = PLATFORM_MEMORY_DATA_SIZE;
          rsp.value = mem_req->is_last ? 1 : 0;
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
  std::queue<aw_state_t> aw_queues_[NUM_DMA_CHANNELS];     // per AXI port (8)
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
