// Copyright © 2024
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

/// Shared-memory status helper class for vortex-smi.
/// Include this from any backend runtime (xrt, simx, rtlsim, etc.)
/// to export live status to /dev/shm/vortex_status.

#ifndef __VX_SHM_HELPER_H__
#define __VX_SHM_HELPER_H__

#include <vx_shm_status.h>

#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <cstring>
#include <chrono>

class ShmStatus {
public:
  ShmStatus() : shm_(nullptr), fd_(-1) {}

  ~ShmStatus() { close(); }

  bool open() {
    fd_ = ::open(VX_SHM_PATH, O_CREAT | O_RDWR, 0666);
    if (fd_ < 0) {
      fprintf(stderr, "[VXDRV] Warning: cannot create shm %s\n", VX_SHM_PATH);
      return false;
    }
    if (ftruncate(fd_, sizeof(vx_shm_status_t)) < 0) {
      fprintf(stderr, "[VXDRV] Warning: ftruncate shm failed\n");
      ::close(fd_); fd_ = -1;
      return false;
    }
    void *p = mmap(nullptr, sizeof(vx_shm_status_t),
                   PROT_READ | PROT_WRITE, MAP_SHARED, fd_, 0);
    if (p == MAP_FAILED) {
      fprintf(stderr, "[VXDRV] Warning: mmap shm failed\n");
      ::close(fd_); fd_ = -1;
      return false;
    }
    shm_ = reinterpret_cast<vx_shm_status_t *>(p);
    memset(shm_, 0, sizeof(*shm_));
    shm_->magic   = VX_SHM_MAGIC;
    shm_->version = VX_SHM_VERSION;
    shm_->pid     = getpid();
    shm_->init_timestamp = now_ms();
    shm_->last_activity  = shm_->init_timestamp;
    return true;
  }

  void close() {
    if (shm_) {
      shm_->state = VX_STATE_OFFLINE;
      munmap(shm_, sizeof(vx_shm_status_t));
      shm_ = nullptr;
    }
    if (fd_ >= 0) {
      unlink(VX_SHM_PATH);
      ::close(fd_);
      fd_ = -1;
    }
  }

  // convenience setters
  void set_state(vx_device_state_t s)  { if (shm_) { shm_->state = s; touch(); } }
  void set_device_info(const char *name, uint32_t cores, uint32_t warps,
                       uint32_t threads, uint32_t banks, uint64_t mem_size) {
    if (!shm_) return;
    strncpy(shm_->device_name, name, sizeof(shm_->device_name) - 1);
    shm_->num_cores  = cores;
    shm_->num_warps  = warps;
    shm_->num_threads = threads;
    shm_->num_banks  = banks;
    shm_->global_mem_size = mem_size;
  }
  void update_mem(uint64_t used, uint64_t free_) {
    if (!shm_) return;
    shm_->mem_used = used;
    shm_->mem_free = free_;
  }
  void record_upload(uint64_t bytes) {
    if (!shm_) return;
    shm_->total_uploaded += bytes;
    shm_->upload_count++;
    touch();
  }
  void record_download(uint64_t bytes) {
    if (!shm_) return;
    shm_->total_downloaded += bytes;
    shm_->download_count++;
    touch();
  }
  void record_kernel(uint64_t addr) {
    if (!shm_) return;
    shm_->kernel_launches++;
    shm_->last_kernel_addr = addr;
    touch();
  }
  void set_kernel_name(const char *name) {
    if (!shm_) return;
    strncpy(shm_->last_kernel_name, name, sizeof(shm_->last_kernel_name) - 1);
    shm_->last_kernel_name[sizeof(shm_->last_kernel_name) - 1] = '\0';
  }
  void set_bank(uint32_t id, bool alloc, uint32_t refcnt, uint64_t size) {
    if (!shm_ || id >= VX_SHM_MAX_BANKS) return;
    shm_->banks[id].allocated = alloc ? 1 : 0;
    shm_->banks[id].ref_count = refcnt;
    shm_->banks[id].bank_size = size;
  }

private:
  void touch() { if (shm_) shm_->last_activity = now_ms(); }
  static uint64_t now_ms() {
    using namespace std::chrono;
    return duration_cast<milliseconds>(system_clock::now().time_since_epoch()).count();
  }
  vx_shm_status_t *shm_;
  int fd_;
};

#endif // __VX_SHM_HELPER_H__
