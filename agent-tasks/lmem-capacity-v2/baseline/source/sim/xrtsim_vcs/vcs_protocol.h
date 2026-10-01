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

#pragma once

#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <sys/socket.h>
#include <poll.h>
#include <chrono>
#include <cstdlib>
#include <climits>

// Packet types for ctrl_sock (App main thread <-> VCS)
enum VcsCtrlType : uint8_t {
  CMD_REG_WRITE     = 0x01,
  CMD_REG_WRITE_ACK = 0x02,
  CMD_REG_READ      = 0x03,
  CMD_REG_READ_RESP = 0x04,
  CMD_SHUTDOWN      = 0x05
};

// Packet types for mem_sock (App sim thread <-> VCS)
enum VcsMemType : uint8_t {
  MEM_HELLO  = 0x30,  // 64-byte manifest hash; value is protocol version
  MEM_WRITE  = 0x31,  // addr, size, payload; acknowledged after RAM visibility
  MEM_READ   = 0x32,  // addr, size; response carries payload
  MEM_ACK    = 0x33,  // id echoes request; value is status; size is payload length
  EVT_AXI_AR  = 0x10,  // DUT read request
  EVT_AXI_AW  = 0x11,  // DUT write address
  EVT_AXI_W   = 0x12,  // DUT write data+strb
  RSP_AXI_R   = 0x20,  // read response (App -> VCS)
  RSP_AXI_B   = 0x21   // write response (App -> VCS)
};

static constexpr uint32_t VCS_MEM_VERSION = 1;
static constexpr uint32_t VCS_MEM_MAX_PAYLOAD = 1 << 20;

// Common packet header (24 bytes)
struct VcsPacket {
  uint8_t  type;        // VcsCtrlType or VcsMemType
  uint8_t  port_id;     // AXI port index
  uint8_t  reserved[2];
  uint32_t id;          // AXI transaction ID or register offset
  uint64_t addr;        // memory address
  uint32_t size;        // payload size (bytes following this header)
  uint32_t value;       // register value or misc
};

static_assert(sizeof(VcsPacket) == 24, "VcsPacket must be 24 bytes");

// Reliable send: writes exactly `len` bytes to socket fd.
// Returns 0 on success, -1 on error.
// Wall-clock liveness limit only; never used to advance device simulation.
// Apply a total deadline per buffer, not a fresh timeout after every byte.
static inline int vcs_transport_timeout_ms() {
  const char* value = std::getenv("VCS_TRANSPORT_TIMEOUT_MS");
  if (!value) return 300000;
  char* end = nullptr;
  errno = 0;
  long parsed = std::strtol(value, &end, 10);
  if (errno || end == value || *end || parsed <= 0 || parsed > INT_MAX) {
    errno = EINVAL;
    return -1;
  }
  return static_cast<int>(parsed);
}

static inline int vcs_wait_socket(int fd, short events,
                                 std::chrono::steady_clock::time_point deadline) {
  for (;;) {
    auto remaining = deadline - std::chrono::steady_clock::now();
    if (remaining <= std::chrono::steady_clock::duration::zero()) {
      errno = ETIMEDOUT;
      return -1;
    }
    auto millis = std::chrono::duration_cast<std::chrono::milliseconds>(remaining).count();
    pollfd descriptor{fd, events, 0};
    int result = poll(&descriptor, 1, static_cast<int>(millis < INT_MAX ? millis + 1 : INT_MAX));
    if (result > 0) {
      if (descriptor.revents & POLLNVAL) { errno = EBADF; return -1; }
      return 0; // recv/send handles EOF and other socket errors.
    }
    if (result < 0 && errno != EINTR) return -1;
  }
}

static inline int send_all(int fd, const void* buf, size_t len,
                           int timeout_ms = vcs_transport_timeout_ms()) {
  if (timeout_ms <= 0) { errno = EINVAL; return -1; }
  auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
  const uint8_t* p = (const uint8_t*)buf;
  while (len > 0) {
    if (vcs_wait_socket(fd, POLLOUT, deadline)) return -1;
    ssize_t n = send(fd, p, len, MSG_NOSIGNAL | MSG_DONTWAIT);
    if (n <= 0) {
      if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK))
        continue;
      return -1;
    }
    p += n;
    len -= (size_t)n;
  }
  return 0;
}

// Reliable recv: reads exactly `len` bytes from socket fd.
// Returns 0 on success, -1 on error/disconnect.
static inline int recv_all(int fd, void* buf, size_t len,
                           int timeout_ms = vcs_transport_timeout_ms()) {
  if (timeout_ms <= 0) { errno = EINVAL; return -1; }
  auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
  uint8_t* p = (uint8_t*)buf;
  while (len > 0) {
    if (vcs_wait_socket(fd, POLLIN, deadline)) return -1;
    ssize_t n = recv(fd, p, len, MSG_DONTWAIT);
    if (n <= 0) {
      if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK))
        continue;
      return -1;
    }
    p += n;
    len -= (size_t)n;
  }
  return 0;
}

// Non-blocking check if data is available on socket.
// Returns 1 if data available, 0 if not, -1 on error.
static inline int sock_has_data(int fd) {
  uint8_t peek;
  ssize_t n = recv(fd, &peek, 1, MSG_PEEK | MSG_DONTWAIT);
  if (n > 0)
    return 1;
  if (n == 0)
    return -1; // peer closed
  if (errno == EAGAIN || errno == EWOULDBLOCK)
    return 0;
  return -1;
}
