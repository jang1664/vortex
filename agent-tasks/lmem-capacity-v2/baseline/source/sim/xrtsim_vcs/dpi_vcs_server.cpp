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

// DPI-C socket server for VCS testbench.
// Two TCP sockets: ctrl_sock (register commands) and mem_sock (AXI memory events).
// Device RAM and timing live here; the memory socket carries host BO transfers.

#include "svdpi.h"
#include "vcs_protocol.h"
#include "hbm_model.h"
#include "hbm_transfer.h"

static std::unique_ptr<u55c::MemoryModel> memory_model;
static u55c::MemoryService memory_service;
static int r_room[U55C_NUM_PORTS], b_room[U55C_NUM_PORTS];

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <errno.h>

// Stubs for sim_trace functions (defined in xrt_sim.cpp for Verilator builds)
static bool g_trace_enabled = true;
bool sim_trace_enabled() { return g_trace_enabled; }
void sim_trace_enable(bool enable) { g_trace_enabled = enable; }

static int ctrl_server_fd = -1;
static int ctrl_client_fd = -1;
static int mem_server_fd  = -1;
static int mem_client_fd  = -1;

static int create_listen_socket(int port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    perror("[DPI] socket");
    return -1;
  }
  int opt = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = INADDR_ANY;
  addr.sin_port = htons(port);

  if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
    perror("[DPI] bind");
    close(fd);
    return -1;
  }
  if (listen(fd, 1) < 0) {
    perror("[DPI] listen");
    close(fd);
    return -1;
  }
  return fd;
}

static int accept_client(int server_fd) {
  struct sockaddr_in client_addr;
  socklen_t len = sizeof(client_addr);
  int fd = accept(server_fd, (struct sockaddr*)&client_addr, &len);
  if (fd < 0) {
    perror("[DPI] accept");
    return -1;
  }
  // disable Nagle for low latency
  int opt = 1;
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &opt, sizeof(opt));
  return fd;
}

// ============================================================
// DPI functions callable from SystemVerilog
// ============================================================

extern "C" {

// Initialize server sockets on ctrl_port and mem_port
int socket_server_init(int ctrl_port, int mem_port) {
  memory_service = u55c::MemoryService{};
  ctrl_server_fd = create_listen_socket(ctrl_port);
  if (ctrl_server_fd < 0)
    return -1;
  printf("[DPI] ctrl socket listening on port %d\n", ctrl_port);

  mem_server_fd = create_listen_socket(mem_port);
  if (mem_server_fd < 0) {
    close(ctrl_server_fd);
    ctrl_server_fd = -1;
    return -1;
  }
  printf("[DPI] mem socket listening on port %d\n", mem_port);
  return 0;
}

// Blocking accept on both sockets (ctrl first, then mem)
int socket_server_accept() {
  printf("[DPI] waiting for ctrl connection...\n");
  ctrl_client_fd = accept_client(ctrl_server_fd);
  if (ctrl_client_fd < 0)
    return -1;
  printf("[DPI] ctrl client connected\n");

  printf("[DPI] waiting for mem connection...\n");
  mem_client_fd = accept_client(mem_server_fd);
  if (mem_client_fd < 0)
    return -1;
  printf("[DPI] mem client connected\n");
  memory_model = std::make_unique<u55c::MemoryModel>();
  if (memory_service.serve_one(mem_client_fd, *memory_model, U55C_MANIFEST_HASH)
      || !memory_service.connected()) return -1;
  return 0;
}

// ---- ctrl_sock functions ----

// Non-blocking check if a command is available on ctrl_sock
int ctrl_has_command() {
  if (ctrl_client_fd < 0) return 0; // Directed adapter self-test has no host.
  return u55c::poll_host_command(ctrl_client_fd, mem_client_fd, memory_service,
                                *memory_model, U55C_MANIFEST_HASH);
}

// Receive a command packet from ctrl_sock
// Returns: type in *out_type, offset in *out_offset, value in *out_value
int ctrl_recv_command(int* out_type, int* out_offset, int* out_value) {
  VcsPacket pkt;
  if (recv_all(ctrl_client_fd, &pkt, sizeof(pkt)) < 0)
    return -1;
  if (pkt.type != CMD_REG_WRITE && pkt.type != CMD_REG_READ
      && pkt.type != CMD_SHUTDOWN) return -1;
  *out_type   = pkt.type;
  *out_offset = (int)pkt.id;
  *out_value  = (int)pkt.value;
  return 0;
}

// Send REG_WRITE ACK back to App
int ctrl_send_ack() {
  VcsPacket pkt;
  memset(&pkt, 0, sizeof(pkt));
  pkt.type = CMD_REG_WRITE_ACK;
  return send_all(ctrl_client_fd, &pkt, sizeof(pkt));
}

// Send REG_READ response with value
int ctrl_send_reg_value(int value) {
  VcsPacket pkt;
  memset(&pkt, 0, sizeof(pkt));
  pkt.type  = CMD_REG_READ_RESP;
  pkt.value = (uint32_t)value;
  return send_all(ctrl_client_fd, &pkt, sizeof(pkt));
}

// ---- VCS-thread-local device memory functions ----
void mem_test_init() { memory_model = std::make_unique<u55c::MemoryModel>(); }
int mem_manifest_matches(const char* hash, int ports) {
  return ports == U55C_NUM_PORTS && strcmp(hash, U55C_MANIFEST_HASH) == 0;
}
void mem_logic_edge(unsigned long long time_ps) { memory_model->logic_edge(time_ps); }
void mem_reset(unsigned long long time_ps) {
  memory_model->reset(time_ps);
  for (int p = 0; p < U55C_NUM_PORTS; ++p) {
    r_room[p] = 0;
    b_room[p] = 0;
  }
}
int mem_ar_ready(int port) { return memory_model->ar_ready(port, 64); }
int mem_aw_ready(int port) { return memory_model->aw_ready(port); }
int mem_w_ready(int port) { return memory_model->w_ready(port); }
void mem_response_room(int port, int reads, int writes) {
  r_room[port] = reads; b_room[port] = writes;
}
int mem_send_axi_ar(int port, long long addr, int id, int len) {
  memory_model->ar(port, id, addr, unsigned(len) + 1);
  return 0;
}
int mem_send_axi_aw(int port, long long addr, int id, int len) {
  memory_model->aw(port, id, addr, unsigned(len) + 1);
  return 0;
}
int mem_send_axi_w(int port, const svOpenArrayHandle data_bytes,
                   long long strb, int last, int data_size) {
  if (data_size != 64) return -1;
  u55c::MemoryModel::Data data{};
  for (int i = 0; i < data_size; ++i)
    data[i] = *static_cast<uint8_t*>(svGetArrElemPtr1(data_bytes, i));
  memory_model->w(port, data, strb, last != 0);
  return 0;
}
int mem_has_response() {
  u55c::MemoryModel::Response response;
  for (unsigned p = 0; p < U55C_NUM_PORTS; ++p)
    if ((r_room[p] > 0 && memory_model->read_response(p, response))
        || (b_room[p] > 0 && memory_model->write_response(p, response))) return 1;
  return 0;
}
int mem_recv_response(int* out_type, int* out_port, int* out_id,
                      svOpenArrayHandle data_bytes, int* out_last, int data_size) {
  if (data_size != 64) return -1;
  u55c::MemoryModel::Response response;
  for (unsigned p = 0; p < U55C_NUM_PORTS; ++p) {
    if (r_room[p] > 0 && memory_model->read_response(p, response)) {
      *out_type = RSP_AXI_R; *out_port = p; *out_id = response.id; *out_last = response.last;
      for (int i = 0; i < data_size; ++i)
        *static_cast<uint8_t*>(svGetArrElemPtr1(data_bytes, i)) = response.data[i];
      memory_model->pop_read(p);
      --r_room[p];
      return 0;
    }
    if (b_room[p] > 0 && memory_model->write_response(p, response)) {
      *out_type = RSP_AXI_B; *out_port = p; *out_id = response.id; *out_last = 1;
      memory_model->pop_write(p);
      --b_room[p];
      return 0;
    }
  }
  return -1;
}

// Close all sockets
void socket_server_close() {
  memory_model.reset();
  memory_service = u55c::MemoryService{};
  if (ctrl_client_fd >= 0) { close(ctrl_client_fd); ctrl_client_fd = -1; }
  if (mem_client_fd >= 0)  { close(mem_client_fd);  mem_client_fd = -1; }
  if (ctrl_server_fd >= 0) { close(ctrl_server_fd); ctrl_server_fd = -1; }
  if (mem_server_fd >= 0)  { close(mem_server_fd);  mem_server_fd = -1; }
  printf("[DPI] sockets closed\n");
}

} // extern "C"
