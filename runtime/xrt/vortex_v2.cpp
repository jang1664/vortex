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

#include <common.h>

#ifdef SCOPE
#include "scope.h"
#endif

// XRT includes
#ifdef XRTSIM
#include <xrt_c.h>
#else
#include "experimental/xrt_bo.h"
#include "experimental/xrt_device.h"
#include "experimental/xrt_error.h"
#include "experimental/xrt_ip.h"
#include "experimental/xrt_kernel.h"
#include "experimental/xrt_xclbin.h"
#endif

#include <cctype>
#include <limits>
#include <stdarg.h>
#include <string>
#include <unistd.h>
#include <unordered_map>
#include <util.h>
#include <vector>

// vortex-smi shared memory support
#include <vx_shm_helper.h>

using namespace vortex;

#ifndef XRTSIM
#define CPP_API
#endif

#define BANK_INTERLEAVE

// Debug print macro: enabled only when compiled with -DDEBUG_XRT
// Usage: DEBUG_XRT=1 make -C runtime/xrt
#ifdef DEBUG_XRT
#define DBG_PRINT(...) printf(__VA_ARGS__)
#else
#define DBG_PRINT(...) ((void)0)
#endif

#define MMIO_CTL_ADDR 0x00
#define MMIO_DEV_ADDR 0x10
#define MMIO_ISA_ADDR 0x18
#define MMIO_DCR_ADDR 0x20
#define MMIO_SCP_ADDR 0x28
#define MMIO_MEM_ADDR 0x30

#define CTL_AP_START (1 << 0)
#define CTL_AP_DONE (1 << 1)
#define CTL_AP_IDLE (1 << 2)
#define CTL_AP_READY (1 << 3)
#define CTL_AP_RESET (1 << 4)
#define CTL_AP_RESTART (1 << 7)

#ifdef CPP_API

typedef xrt::device xrt_device_t;
typedef xrt::ip xrt_kernel_t;
typedef xrt::bo xrt_buffer_t;

#else

typedef xrtDeviceHandle xrt_device_t;
typedef xrtKernelHandle xrt_kernel_t;
typedef xrtBufferHandle xrt_buffer_t;

#endif

#define DEFAULT_DEVICE_INDEX 0

#define DEFAULT_XCLBIN_PATH "vortex_afu.xclbin"

#define KERNEL_NAME "vortex_afu"

#define CHECK_HANDLE(handle, _expr, _cleanup)                                  \
  auto handle = _expr;                                                         \
  if (handle == nullptr) {                                                     \
    DBG_PRINT("[VXDRV] Error: '%s' returned NULL!\n", #_expr);                    \
    _cleanup                                                                   \
  }

#ifndef CPP_API
static void dump_xrt_error(xrtDeviceHandle xrtDevice, xrtErrorCode err) {
  size_t len = 0;
  xrtErrorGetString(xrtDevice, err, nullptr, 0, &len);
  std::vector<char> buf(len);
  xrtErrorGetString(xrtDevice, err, buf.data(), buf.size(), nullptr);
  DBG_PRINT("[VXDRV] detail: %s!\n", buf.data());
}
#endif

static std::string sanitize_shm_tag(const std::string& value) {
  std::string out;
  out.reserve(value.size());
  for (char c : value) {
    if (std::isalnum(static_cast<unsigned char>(c)) || c == '_' || c == '-') {
      out.push_back(c);
    } else {
      out.push_back('_');
    }
  }
  return out;
}

static bool is_xrt_emulation() {
#ifdef XRTSIM
  return true;
#else
  const char* emu_mode = getenv("XCL_EMULATION_MODE");
  return emu_mode != nullptr && emu_mode[0] != '\0';
#endif
}

static void get_xrt_shm_path_policy(
  int device_index,
  const std::string& device_bdf,
  std::string* shm_path,
  bool* unlink_on_close) {
  const bool emulation = is_xrt_emulation();
  const char* forced_shm_path = getenv("VORTEX_SHM_PATH");
  if (forced_shm_path != nullptr && forced_shm_path[0] != '\0') {
    *shm_path = forced_shm_path;
    *unlink_on_close = emulation;
    return;
  }

  if (emulation) {
    *shm_path = "/dev/shm/vortex_status_xrt_emu_uid_" + std::to_string(getuid());
    *unlink_on_close = true;
    return;
  }

  // Real HW: use a single well-known path (like nvidia-smi) so any user
  // can read the status with vortex-smi.
  *shm_path = VX_SHM_PATH;
  *unlink_on_close = false;
}

///////////////////////////////////////////////////////////////////////////////

class vx_device {
public:
  vx_device()
    : global_mem_(ALLOC_BASE_ADDR,
                  GLOBAL_MEM_SIZE - ALLOC_BASE_ADDR,
                  RAM_PAGE_SIZE,
                  CACHE_BLOCK_SIZE)
  #ifndef CPP_API
    , xrtDevice_(nullptr)
    , xrtKernel_(nullptr)
  #endif
    , kernel_timeout_ms_(0)
    , max_retries_(0)
    , inter_kernel_delay_us_(0)
    , kernel_history_avg_ms_(0)
    , kernel_history_count_(0)
    , total_kernel_launches_(0)
    , total_kernel_hangs_(0)
    , last_krnl_addr_(0)
    , last_args_addr_(0)
  {}

  ~vx_device() {
    // Send AP_RESET to leave FPGA in clean state for next user
    this->write_register(MMIO_CTL_ADDR, CTL_AP_RESET);
    DBG_PRINT("[VXDRV-DIAG] ~vx_device: sent AP_RESET to FPGA\n");
    shm_.close();
  #ifdef SCOPE
    vx_scope_stop(this);
  #endif
  #ifndef CPP_API
    for (auto &entry : xrtBuffers_) {
    #ifdef BANK_INTERLEAVE
      xrtBOFree(entry);
    #else
      xrtBOFree(entry.second.xrtBuffer);
    #endif
    }
    if (xrtKernel_) {
      xrtKernelClose(xrtKernel_);
    }
    if (xrtDevice_) {
      xrtDeviceClose(xrtDevice_);
    }
  #endif
  }

  int init() {
    // Disable stdout buffering so all diagnostic output is visible even on hang
    setbuf(stdout, NULL);

    // --- Hang-prevention configuration via environment variables ---
    // VXDRV_KERNEL_TIMEOUT_MS: Hard timeout per kernel (0 = adaptive, default=10000)
    //   - If 0: uses adaptive timeout based on kernel execution history
    //   - If >0: fixed timeout in ms
    // VXDRV_MAX_RETRIES: How many times to retry a hung kernel (default=3)
    // VXDRV_INTER_KERNEL_DELAY_US: Microseconds to wait between kernels (default=0)
    {
      const char *s;
      s = getenv("VXDRV_KERNEL_TIMEOUT_MS");
      kernel_timeout_ms_ = s ? (uint64_t)atoll(s) : 10000;  // default 10s
      s = getenv("VXDRV_MAX_RETRIES");
      max_retries_ = s ? (uint32_t)atoi(s) : 3;
      s = getenv("VXDRV_INTER_KERNEL_DELAY_US");
      inter_kernel_delay_us_ = s ? (uint64_t)atoll(s) : 0;
      DBG_PRINT("[VXDRV] Hang-prevention config: timeout=%lu ms (0=adaptive), "
             "max_retries=%u, inter_kernel_delay=%lu us\n",
             kernel_timeout_ms_, max_retries_, inter_kernel_delay_us_);
    }

    int device_index = DEFAULT_DEVICE_INDEX;
    const char *device_index_s = getenv("XRT_DEVICE_INDEX");
    if (device_index_s != nullptr) {
      device_index = atoi(device_index_s);
    }

    const char *xlbin_path_s = getenv("XRT_XCLBIN_PATH");
    if (xlbin_path_s == nullptr) {
      xlbin_path_s = DEFAULT_XCLBIN_PATH;
    }

    std::string device_bdf;

  #ifdef CPP_API

    auto xrtDevice = xrt::device(device_index);
    auto uuid = xrtDevice.load_xclbin(xlbin_path_s);
    auto xrtKernel = xrt::ip(xrtDevice, uuid, KERNEL_NAME);
    auto xclbin = xrt::xclbin(xlbin_path_s);
    auto device_name = xrtDevice.get_info<xrt::info::device::name>();
    device_bdf = xrtDevice.get_info<xrt::info::device::bdf>();

  #else

    CHECK_HANDLE(xrtDevice, xrtDeviceOpen(device_index), {
      return -1;
    });

  #ifndef XRTSIM
    CHECK_ERR(xrtDeviceLoadXclbinFile(xrtDevice, xlbin_path_s), {
      dump_xrt_error(xrtDevice, err);
      xrtDeviceClose(xrtDevice);
      return err;
    });

    xuid_t uuid;
    CHECK_ERR(xrtDeviceGetXclbinUUID(xrtDevice, uuid), {
      dump_xrt_error(xrtDevice, err);
      xrtDeviceClose(xrtDevice);
      return err;
    });

    CHECK_HANDLE(xrtKernel, xrtPLKernelOpenExclusive(xrtDevice, uuid, KERNEL_NAME), {
      xrtDeviceClose(xrtDevice);
      return -1;
    });
  #else
    xrtKernelHandle xrtKernel = xrtDevice;
  #endif

    // get device name
    int device_name_size;
    xrtXclbinGetXSAName(xrtDevice, nullptr, 0, &device_name_size);
    std::vector<char> sz_device_name(device_name_size);
    xrtXclbinGetXSAName(xrtDevice, sz_device_name.data(), device_name_size, nullptr);
    std::string device_name(sz_device_name.data(), device_name_size);
    device_bdf = "idx_" + std::to_string(device_index);

  #endif

    xrtDevice_ = xrtDevice;
    xrtKernel_ = xrtKernel;

    CHECK_ERR(this->write_register(MMIO_CTL_ADDR, CTL_AP_RESET), {
      return err;
    });

    CHECK_ERR(this->read_register(MMIO_DEV_ADDR, (uint32_t *)&dev_caps_), {
      return err;
    });

    CHECK_ERR(this->read_register(MMIO_DEV_ADDR + 4, (uint32_t *)&dev_caps_ + 1), {
      return err;
    });

    CHECK_ERR(this->read_register(MMIO_ISA_ADDR, (uint32_t *)&isa_caps_), {
      return err;
    });

    CHECK_ERR(this->read_register(MMIO_ISA_ADDR + 4, (uint32_t *)&isa_caps_ + 1), {
      return err;
    });

    uint64_t num_banks;
    this->get_caps(VX_CAPS_NUM_MEM_BANKS, &num_banks);
    lg2_num_banks_ = log2ceil(num_banks);

    uint64_t bank_size;
    this->get_caps(VX_CAPS_MEM_BANK_SIZE, &bank_size);
    lg2_bank_size_ = log2ceil(bank_size);

    global_mem_size_ = num_banks * bank_size;

    DBG_PRINT("info: device name=%s, memory_capacity=0x%lx bytes, memory_banks=%ld.\n", device_name.c_str(), global_mem_size_, num_banks);

    // [DIAG] Memory size comparison: HW reported vs SW allocator
    DBG_PRINT("[VXDRV-DIAG] HW global_mem_size=0x%lx (%lu MiB), GLOBAL_MEM_SIZE=0x%lx (%lu MiB), allocator_capacity=0x%lx (%lu MiB)\n",
           global_mem_size_, global_mem_size_ >> 20,
           (uint64_t)GLOBAL_MEM_SIZE, (uint64_t)GLOBAL_MEM_SIZE >> 20,
           (uint64_t)(GLOBAL_MEM_SIZE - ALLOC_BASE_ADDR), (uint64_t)(GLOBAL_MEM_SIZE - ALLOC_BASE_ADDR) >> 20);
    if (global_mem_size_ > GLOBAL_MEM_SIZE) {
      DBG_PRINT("[VXDRV-DIAG] *** WARNING: HW reports more memory (0x%lx) than SW allocator limit (0x%lx). %lu MiB inaccessible! ***\n",
             global_mem_size_, (uint64_t)GLOBAL_MEM_SIZE, (global_mem_size_ - GLOBAL_MEM_SIZE) >> 20);
    }
    DBG_PRINT("[VXDRV-DIAG] bank_size=0x%lx (%lu MiB), num_banks=%lu, lg2_bank_size=%u, lg2_num_banks=%u\n",
           bank_size, bank_size >> 20, num_banks, lg2_bank_size_, lg2_num_banks_);
  #ifdef BANK_INTERLEAVE
    DBG_PRINT("[VXDRV-DIAG] Mode: BANK_INTERLEAVE (cache-line striping across banks)\n");
  #else
    DBG_PRINT("[VXDRV-DIAG] Mode: NON-INTERLEAVE (contiguous per-bank). Check HW PLATFORM_MEMORY_INTERLEAVE!\n");
  #endif

  #ifdef BANK_INTERLEAVE
    xrtBuffers_.reserve(num_banks);
    for (uint32_t i = 0; i < num_banks; ++i) {
    #ifdef CPP_API
      xrtBuffers_.emplace_back(xrtDevice_, bank_size, xrt::bo::flags::normal, i);
    #else
      CHECK_HANDLE(xrtBuffer, xrtBOAlloc(xrtDevice_, bank_size, XRT_BO_FLAGS_NONE, i), {
         return -1;
      });
      xrtBuffers_.push_back(xrtBuffer);
    #endif
      DBG_PRINT("*** allocated bank%u/%u, size=%lu\n", i, num_banks, bank_size);
    }
  #endif

  #ifdef SCOPE
    {
      scope_callback_t callback;
      callback.registerWrite = [](vx_device_h hdevice, uint64_t value) -> int {
        auto device = (vx_device *)hdevice;
        uint32_t value_lo = (uint32_t)(value);
        uint32_t value_hi = (uint32_t)(value >> 32);
        CHECK_ERR(device->write_register(MMIO_SCP_ADDR, value_lo), {
          return err;
        });
        CHECK_ERR(device->write_register(MMIO_SCP_ADDR + 4, value_hi), {
          return err;
        });
        return 0;
      };
      callback.registerRead = [](vx_device_h hdevice, uint64_t *value) -> int {
        auto device = (vx_device *)hdevice;
        uint32_t value_lo, value_hi;
        CHECK_ERR(device->read_register(MMIO_SCP_ADDR, &value_lo), {
          return err;
        });
        CHECK_ERR(device->read_register(MMIO_SCP_ADDR + 4, &value_hi), {
          return err;
        });
        *value = (((uint64_t)value_hi) << 32) | value_lo;
        return 0;
      };
      CHECK_ERR(vx_scope_start(&callback, this, -1, -1), {
        return err;
      });
    }
  #endif

  #ifdef CHIPSCOPE
    std::cout << "\nPress ENTER to continue after setting up ILA trigger..." << std::endl;
    std::cin.ignore(std::numeric_limits<std::streamsize>::max(), '\n');
  #endif

    // --- vortex-smi: initialize shared memory status ---
    std::string shm_path;
    bool shm_unlink_on_close;
    get_xrt_shm_path_policy(device_index, device_bdf, &shm_path, &shm_unlink_on_close);
    DBG_PRINT("[VXDRV] status shm: path=%s, unlink_on_close=%d\n",
              shm_path.c_str(), shm_unlink_on_close ? 1 : 0);
    if (shm_.open(shm_path, shm_unlink_on_close)) {
      uint64_t ncores, nwarps, nthreads;
      this->get_caps(VX_CAPS_NUM_CORES, &ncores);
      this->get_caps(VX_CAPS_NUM_WARPS, &nwarps);
      this->get_caps(VX_CAPS_NUM_THREADS, &nthreads);
      shm_.set_device_info(device_name.c_str(), ncores, nwarps, nthreads,
                           num_banks, global_mem_size_);
      shm_.set_state(VX_STATE_IDLE);
      shm_.update_mem(global_mem_.allocated(), global_mem_.free());
    }

    return 0;
  }

  int get_caps(uint32_t caps_id, uint64_t *value) {
    uint64_t _value;

    switch (caps_id) {
    case VX_CAPS_VERSION:
      _value = (dev_caps_ >> 0) & 0xff;
      break;
    case VX_CAPS_NUM_THREADS:
      _value = (dev_caps_ >> 8) & 0xff;
      break;
    case VX_CAPS_NUM_WARPS:
      _value = (dev_caps_ >> 16) & 0xff;
      break;
    case VX_CAPS_NUM_CORES:
      _value = (dev_caps_ >> 24) & 0xffff;
      break;
    case VX_CAPS_CACHE_LINE_SIZE:
      _value = CACHE_BLOCK_SIZE;
      break;
    case VX_CAPS_GLOBAL_MEM_SIZE:
      _value = global_mem_size_;
      break;
    case VX_CAPS_LOCAL_MEM_SIZE:
      _value = 1ull << ((dev_caps_ >> 40) & 0xff);
      break;
    case VX_CAPS_ISA_FLAGS:
      _value = isa_caps_;
      break;
    case VX_CAPS_NUM_MEM_BANKS:
      _value = 1 << ((dev_caps_ >> 48) & 0x7);
      break;
    case VX_CAPS_MEM_BANK_SIZE:
      _value = 1ull << (20 + ((dev_caps_ >> 51) & 0x1f));
      break;
    default:
      fprintf(stderr, "[VXDRV] Error: invalid caps id: %d\n", caps_id);
      std::abort();
      return -1;
    }

    *value = _value;

    return 0;
  }

  int mem_alloc(uint64_t size, int flags, uint64_t *dev_addr) {
    uint64_t asize = aligned_size(size, CACHE_BLOCK_SIZE);
    uint64_t addr;
    CHECK_ERR(global_mem_.allocate(asize, &addr), {
      return err;
    });

#ifdef DEBUG_XRT
    // [DIAG] Check if allocation crosses a bank boundary
    {
      uint64_t bank_size = 1ull << lg2_bank_size_;
      uint32_t start_bank = (uint32_t)(addr >> lg2_bank_size_);
      uint32_t end_bank   = (uint32_t)((addr + asize - 1) >> lg2_bank_size_);
      DBG_PRINT("[VXDRV-DIAG] mem_alloc: addr=0x%lx, size=0x%lx, asize=0x%lx, bank=%u, offset_in_bank=0x%lx\n",
             addr, size, asize, start_bank, addr & (bank_size - 1));
      if (start_bank != end_bank) {
        DBG_PRINT("[VXDRV-DIAG] *** CROSS-BANK ALLOC: addr=0x%lx..0x%lx spans bank %u to %u! (bank_size=0x%lx) ***\n",
               addr, addr + asize - 1, start_bank, end_bank, bank_size);
      }
    }
#endif
  #ifndef BANK_INTERLEAVE
    uint32_t bank_id;
    CHECK_ERR(this->get_bank_info(addr, &bank_id, nullptr), {
      global_mem_.release(addr);
      return err;
    });
    CHECK_ERR(get_buffer(bank_id, nullptr), {
      global_mem_.release(addr);
      return err;
    });
  #endif
    CHECK_ERR(this->mem_access(addr, size, flags), {
      global_mem_.release(addr);
      return err;
    });
    *dev_addr = addr;
    shm_.update_mem(global_mem_.allocated(), global_mem_.free());
    return 0;
  }

  int mem_reserve(uint64_t dev_addr, uint64_t size, int flags) {
    CHECK_ERR(global_mem_.reserve(dev_addr, size), {
      return err;
    });
  #ifndef BANK_INTERLEAVE
    uint32_t bank_id;
    CHECK_ERR(this->get_bank_info(dev_addr, &bank_id, nullptr), {
      global_mem_.release(dev_addr);
      return err;
    });
    CHECK_ERR(get_buffer(bank_id, nullptr), {
      global_mem_.release(dev_addr);
      return err;
    });
  #endif
    CHECK_ERR(this->mem_access(dev_addr, size, flags), {
      global_mem_.release(dev_addr);
      return err;
    });
    return 0;
  }

  int mem_free(uint64_t dev_addr) {
    CHECK_ERR(global_mem_.release(dev_addr), {
      return err;
    });
  #ifdef BANK_INTERLEAVE
    if (0 == global_mem_.allocated()) {
    #ifndef CPP_API
      for (auto &entry : xrtBuffers_) {
        xrtBOFree(entry);
      }
    #endif
      xrtBuffers_.clear();
    }
  #else
    uint32_t bank_id;
    CHECK_ERR(this->get_bank_info(dev_addr, &bank_id, nullptr), {
      return err;
    });
    auto it = xrtBuffers_.find(bank_id);
    if (it != xrtBuffers_.end()) {
      auto count = --it->second.count;
      if (0 == count) {
        // Keep the BO cached instead of freeing it.
        // Repeated alloc/free of 512MB DMA buffers causes XRT/kernel
        // memory fragmentation and eventual allocation failures that
        // manifest as GPU hangs after many kernel launches.
        DBG_PRINT("bank%d: refcount=0, keeping BO cached\n", bank_id);
      }
    } else {
      fprintf(stderr, "[VXDRV] Error: invalid device memory address: 0x%lx\n",
              dev_addr);
      return -1;
    }
  #endif
    shm_.update_mem(global_mem_.allocated(), global_mem_.free());
    return 0;
  }

  int mem_access(uint64_t /*dev_addr*/, uint64_t /*size*/, int /*flags*/) {
    return 0;
  }

  int mem_info(uint64_t *mem_free, uint64_t *mem_used) const {
    if (mem_free)
      *mem_free = global_mem_.free();
    if (mem_used)
      *mem_used = global_mem_.allocated();
    return 0;
  }

  int write_register(uint32_t addr, uint32_t value) {
  #ifdef CPP_API
    xrtKernel_.write_register(addr, value);
  #else
    CHECK_ERR(xrtKernelWriteRegister(xrtKernel_, addr, value), {
      dump_xrt_error(xrtDevice_, err);
      return err;
    });
  #endif
    return 0;
  }

  int read_register(uint32_t addr, uint32_t *value) {
  #ifdef CPP_API
    *value = xrtKernel_.read_register(addr);
  #else
    CHECK_ERR(xrtKernelReadRegister(xrtKernel_, addr, value), {
      dump_xrt_error(xrtDevice_, err);
      return err;
    });
  #endif
    return 0;
  }

  int upload(uint64_t dev_addr, const void *src, uint64_t size) {
    shm_.set_state(VX_STATE_UPLOADING);
    auto host_ptr = (const uint8_t *)src;

    // check alignment
    if (!is_aligned(dev_addr, CACHE_BLOCK_SIZE))
      return -1;

    auto asize = aligned_size(size, CACHE_BLOCK_SIZE);

    // bound checking
    if (dev_addr + asize > global_mem_size_)
      return -1;

    // [DIAG] Upload entry
    DBG_PRINT("[VXDRV-DIAG] upload: dev_addr=0x%lx, size=0x%lx (%lu), asize=0x%lx\n",
           dev_addr, size, size, asize);

    uint64_t remaining = size;
    while (remaining != 0) {
      uint32_t bo_index;
      uint64_t bo_offset;
      xrt_buffer_t xrtBuffer;
      CHECK_ERR(this->get_bank_info(dev_addr, &bo_index, &bo_offset), {
        return err;
      });
      CHECK_ERR(this->get_buffer(bo_index, &xrtBuffer), {
        return err;
      });

      // [DIAG] Check for bank overflow
      uint64_t bank_size = 1ull << lg2_bank_size_;
      uint64_t xfer_size;
#ifdef BANK_INTERLEAVE
      xfer_size = (remaining > CACHE_BLOCK_SIZE) ? CACHE_BLOCK_SIZE : remaining;
#else
      uint64_t bank_headroom = bank_size - bo_offset;
      xfer_size = (remaining > bank_headroom) ? bank_headroom : remaining;
#endif
      if (xfer_size == 0) {
        fprintf(stderr, "[VXDRV] Error: zero-size upload chunk (addr=0x%lx, bank=%u, off=0x%lx)\n",
                dev_addr, bo_index, bo_offset);
        return -1;
      }
      if (bo_offset + xfer_size > bank_size) {
        DBG_PRINT("[VXDRV-DIAG] *** UPLOAD BANK OVERFLOW: bank=%u, bo_offset=0x%lx, xfer_size=0x%lx, bank_size=0x%lx, overflow=0x%lx ***\n",
               bo_index, bo_offset, xfer_size, bank_size, (bo_offset + xfer_size) - bank_size);
      } else {
        DBG_PRINT("[VXDRV-DIAG] upload chunk: bank=%u, bo_offset=0x%lx, xfer_size=0x%lx, headroom=0x%lx\n",
               bo_index, bo_offset, xfer_size, bank_size - (bo_offset + xfer_size));
      }

    #ifdef CPP_API
      fflush(stdout);  // flush before DMA that could hang
      xrtBuffer.write(host_ptr, xfer_size, bo_offset);
      xrtBuffer.sync(XCL_BO_SYNC_BO_TO_DEVICE, xfer_size, bo_offset);
    #else
      CHECK_ERR(xrtBOWrite(xrtBuffer, host_ptr, xfer_size, bo_offset), {
        dump_xrt_error(xrtDevice_, err);
        return err;
      });
      CHECK_ERR(xrtBOSync(xrtBuffer, XCL_BO_SYNC_BO_TO_DEVICE, xfer_size, bo_offset), {
        dump_xrt_error(xrtDevice_, err);
        return err;
      });
#endif
      dev_addr += xfer_size;
      host_ptr += xfer_size;
      remaining -= xfer_size;
    }
    shm_.record_upload(size);
    shm_.set_state(VX_STATE_IDLE);
    return 0;
  }

  int download(void *dest, uint64_t dev_addr, uint64_t size) {
    shm_.set_state(VX_STATE_DOWNLOADING);
    auto host_ptr = (uint8_t *)dest;

    // check alignment
    if (!is_aligned(dev_addr, CACHE_BLOCK_SIZE))
      return -1;

    auto asize = aligned_size(size, CACHE_BLOCK_SIZE);

    // bound checking
    if (dev_addr + asize > global_mem_size_)
      return -1;

    // [DIAG] Download entry
    DBG_PRINT("[VXDRV-DIAG] download: dev_addr=0x%lx, size=0x%lx (%lu), asize=0x%lx\n",
           dev_addr, size, size, asize);

    uint64_t remaining = size;
    while (remaining != 0) {
      uint32_t bo_index;
      uint64_t bo_offset;
      xrt_buffer_t xrtBuffer;
      CHECK_ERR(this->get_bank_info(dev_addr, &bo_index, &bo_offset), {
        return err;
      });
      CHECK_ERR(this->get_buffer(bo_index, &xrtBuffer), {
        return err;
      });

      // [DIAG] Check for bank overflow
      uint64_t bank_size = 1ull << lg2_bank_size_;
      uint64_t xfer_size;
#ifdef BANK_INTERLEAVE
      xfer_size = (remaining > CACHE_BLOCK_SIZE) ? CACHE_BLOCK_SIZE : remaining;
#else
      uint64_t bank_headroom = bank_size - bo_offset;
      xfer_size = (remaining > bank_headroom) ? bank_headroom : remaining;
#endif
      if (xfer_size == 0) {
        fprintf(stderr, "[VXDRV] Error: zero-size download chunk (addr=0x%lx, bank=%u, off=0x%lx)\n",
                dev_addr, bo_index, bo_offset);
        return -1;
      }
      if (bo_offset + xfer_size > bank_size) {
        DBG_PRINT("[VXDRV-DIAG] *** DOWNLOAD BANK OVERFLOW: bank=%u, bo_offset=0x%lx, xfer_size=0x%lx, bank_size=0x%lx, overflow=0x%lx ***\n",
               bo_index, bo_offset, xfer_size, bank_size, (bo_offset + xfer_size) - bank_size);
      }

    #ifdef CPP_API
      xrtBuffer.sync(XCL_BO_SYNC_BO_FROM_DEVICE, xfer_size, bo_offset);
      xrtBuffer.read(host_ptr, xfer_size, bo_offset);
    #else
      CHECK_ERR(xrtBOSync(xrtBuffer, XCL_BO_SYNC_BO_FROM_DEVICE, xfer_size, bo_offset), {
        dump_xrt_error(xrtDevice_, err);
        return err;
      });
      CHECK_ERR(xrtBORead(xrtBuffer, host_ptr, xfer_size, bo_offset), {
        dump_xrt_error(xrtDevice_, err);
        return err;
      });
    #endif
      dev_addr += xfer_size;
      host_ptr += xfer_size;
      remaining -= xfer_size;
    }
    shm_.record_download(size);
    shm_.set_state(VX_STATE_IDLE);
    return 0;
  }

  // =========================================================================
  // MMIO Read Validation: detect PCIe link errors and transient glitches
  // =========================================================================
  int read_register_validated(uint32_t addr, uint32_t *value) {
    uint32_t val1 = 0, val2 = 0;
    CHECK_ERR(this->read_register(addr, &val1), { return err; });

    // Check 1: 0xFFFFFFFF typically means PCIe link is dead
    if (val1 == 0xFFFFFFFF) {
      // Retry once after short delay before declaring dead
      struct timespec tiny = {0, 1000000}; // 1ms
      nanosleep(&tiny, nullptr);
      CHECK_ERR(this->read_register(addr, &val2), { return err; });
      if (val2 == 0xFFFFFFFF) {
        DBG_PRINT("[VXDRV] *** FATAL: MMIO read returns 0xFFFFFFFF — PCIe link may be dead! ***\n");
        fflush(stdout);
        *value = val2;
        return -1;  // Signal unrecoverable error
      }
      DBG_PRINT("[VXDRV] WARNING: transient 0xFFFFFFFF on MMIO read, retry got 0x%x\n", val2);
      *value = val2;
      return 0;
    }

    // Check 2: Double-read for consistency on AP_CTRL (bits should be stable)
    // Only do this occasionally to avoid performance impact
    // (every 1000th read or when status looks suspicious)
    bool suspicious = (val1 & 0xFFFFFF00) != 0;  // upper bits should be 0
    if (suspicious) {
      CHECK_ERR(this->read_register(addr, &val2), { return err; });
      if (val1 != val2) {
        DBG_PRINT("[VXDRV] WARNING: MMIO read inconsistency! first=0x%x, second=0x%x (using second)\n", val1, val2);
        *value = val2;
        return 0;
      }
    }

    *value = val1;
    return 0;
  }

  // =========================================================================
  // AP_RESET + IDLE verification helper
  // =========================================================================
  int force_hw_reset() {
    DBG_PRINT("[VXDRV] Forcing AP_RESET...\n");
    fflush(stdout);
    CHECK_ERR(this->write_register(MMIO_CTL_ADDR, CTL_AP_RESET), { return err; });
    struct timespec rst_wait = {0, 50000000}; // 50ms
    nanosleep(&rst_wait, nullptr);

    uint32_t post = 0;
    CHECK_ERR(this->read_register(MMIO_CTL_ADDR, &post), { return err; });
    DBG_PRINT("[VXDRV] After AP_RESET: status=0x%x [idle=%d]\n", post, (post & CTL_AP_IDLE) != 0);
    fflush(stdout);

    if (!(post & CTL_AP_IDLE)) {
      // Escalated reset: wait longer
      DBG_PRINT("[VXDRV] WARNING: not IDLE after 50ms, waiting 500ms...\n");
      struct timespec long_wait = {0, 500000000}; // 500ms
      nanosleep(&long_wait, nullptr);
      CHECK_ERR(this->read_register(MMIO_CTL_ADDR, &post), { return err; });
      if (!(post & CTL_AP_IDLE)) {
        DBG_PRINT("[VXDRV] *** CRITICAL: HW refuses to IDLE after escalated reset! status=0x%x ***\n", post);
        return -1;
      }
    }
    return 0;
  }

  // =========================================================================
  // Compute effective timeout for this kernel launch
  // =========================================================================
  uint64_t compute_effective_timeout() {
    if (kernel_timeout_ms_ > 0) {
      return kernel_timeout_ms_;  // User-specified fixed timeout
    }
    // Adaptive: 200x average latency, minimum 5000ms, maximum 60000ms
    if (kernel_history_count_ > 0) {
      uint64_t adaptive = (uint64_t)(kernel_history_avg_ms_ * 200.0);
      if (adaptive < 5000) adaptive = 5000;
      if (adaptive > 60000) adaptive = 60000;
      return adaptive;
    }
    return 10000;  // First kernel: default 10s
  }

  // =========================================================================
  // Update kernel latency history (exponential moving average)
  // =========================================================================
  void record_kernel_latency(uint64_t latency_ms) {
    if (kernel_history_count_ == 0) {
      kernel_history_avg_ms_ = (double)latency_ms;
    } else {
      // EMA with alpha=0.1: gives weight to recent but smooths transients
      double alpha = 0.1;
      kernel_history_avg_ms_ = alpha * latency_ms + (1.0 - alpha) * kernel_history_avg_ms_;
    }
    kernel_history_count_++;
  }

  // =========================================================================
  // Internal: single launch attempt (no retry)
  // =========================================================================
  int start_once(uint64_t krnl_addr, uint64_t args_addr) {
    // Pre-flight: verify HW is IDLE
    {
      uint32_t pre_status = 0;
      CHECK_ERR(this->read_register_validated(MMIO_CTL_ADDR, &pre_status), {
        return err;
      });
      DBG_PRINT("[VXDRV-DIAG] start: pre-flight status=0x%x [start=%d done=%d idle=%d ready=%d]\n",
             pre_status,
             (pre_status & CTL_AP_START) != 0,
             (pre_status & CTL_AP_DONE) != 0,
             (pre_status & CTL_AP_IDLE) != 0,
             (pre_status & CTL_AP_READY) != 0);
      if (!(pre_status & CTL_AP_IDLE)) {
        DBG_PRINT("[VXDRV-DIAG] *** WARNING: HW not IDLE before start()! ***\n");
        CHECK_ERR(this->force_hw_reset(), { return err; });
      }
    }

    // [DIAG] Kernel launch info
    DBG_PRINT("[VXDRV-DIAG] start: krnl_addr=0x%lx, args_addr=0x%lx\n", krnl_addr, args_addr);

#ifdef DEBUG_XRT
    // [DIAG] Verify addresses are in valid range
    {
      uint64_t bank_size = 1ull << lg2_bank_size_;
      uint32_t krnl_bank = (uint32_t)(krnl_addr >> lg2_bank_size_);
      uint32_t args_bank = (uint32_t)(args_addr >> lg2_bank_size_);
      uint32_t num_banks = 1 << lg2_num_banks_;
      DBG_PRINT("[VXDRV-DIAG]   krnl maps to bank=%u offset=0x%lx (non-interleave view)\n",
             krnl_bank, krnl_addr & (bank_size - 1));
      DBG_PRINT("[VXDRV-DIAG]   args maps to bank=%u offset=0x%lx (non-interleave view)\n",
             args_bank, args_addr & (bank_size - 1));
      if (krnl_bank >= num_banks) {
        DBG_PRINT("[VXDRV-DIAG] *** WARNING: krnl_addr bank index %u >= num_banks %u ***\n", krnl_bank, num_banks);
      }
      if (args_bank >= num_banks) {
        DBG_PRINT("[VXDRV-DIAG] *** WARNING: args_addr bank index %u >= num_banks %u ***\n", args_bank, num_banks);
      }
    }
#endif

    // set kernel info (DCR writes)
    CHECK_ERR(this->dcr_write(VX_DCR_BASE_STARTUP_ADDR0, krnl_addr & 0xffffffff), { return err; });
    CHECK_ERR(this->dcr_write(VX_DCR_BASE_STARTUP_ADDR1, krnl_addr >> 32), { return err; });
    CHECK_ERR(this->dcr_write(VX_DCR_BASE_STARTUP_ARG0, args_addr & 0xffffffff), { return err; });
    CHECK_ERR(this->dcr_write(VX_DCR_BASE_STARTUP_ARG1, args_addr >> 32), { return err; });

    // Ordering barrier: read back to ensure DCR writes committed before AP_START
    {
      uint32_t barrier_status = 0;
      CHECK_ERR(this->read_register(MMIO_CTL_ADDR, &barrier_status), { return err; });
      (void)barrier_status;
    }

    // start execution
    DBG_PRINT("[VXDRV-DIAG] start: sending AP_START...\n");
    fflush(stdout);
    CHECK_ERR(this->write_register(MMIO_CTL_ADDR, CTL_AP_START), { return err; });
    DBG_PRINT("[VXDRV-DIAG] start: AP_START sent, GPU now running\n");
    fflush(stdout);

    // clear mpm cache
    mpm_cache_.clear();

    shm_.record_kernel(krnl_addr);
    shm_.set_state(VX_STATE_RUNNING);
    return 0;
  }

  // =========================================================================
  // start(): launch kernel, saving addresses for potential retry in ready_wait
  // =========================================================================
  int start(uint64_t krnl_addr, uint64_t args_addr) {
    total_kernel_launches_++;

    // Inter-kernel cooldown: let HW settle between rapid-fire launches
    if (inter_kernel_delay_us_ > 0 && total_kernel_launches_ > 1) {
      usleep(inter_kernel_delay_us_);
    }

    // Save for retry in ready_wait
    last_krnl_addr_ = krnl_addr;
    last_args_addr_ = args_addr;

    return this->start_once(krnl_addr, args_addr);
  }

  // =========================================================================
  // ready_wait(): poll for completion with validated reads, timeout, and
  //               automatic hang detection + retry.
  //  Returns: 0 = success, -1 = unrecoverable failure
  // =========================================================================
  int ready_wait(uint64_t timeout) {
    // Override timeout with our smart timeout
    uint64_t eff_timeout = this->compute_effective_timeout();
    // But if caller passed a shorter timeout, respect it
    if (timeout > 0 && timeout < eff_timeout) {
      eff_timeout = timeout;
    }

    uint32_t attempts = 0;
    while (attempts <= max_retries_) {
      DBG_PRINT("[VXDRV-DIAG] ready_wait: effective_timeout=%lu ms (attempt %u/%u, history_avg=%.1f ms)\n",
             eff_timeout, attempts + 1, max_retries_ + 1, kernel_history_avg_ms_);

      int rc = this->ready_wait_once(eff_timeout);
      if (rc == 0) {
        return 0;  // Success
      }

      if (rc == -2) {
        // Unrecoverable PCIe error — no point retrying
        DBG_PRINT("[VXDRV] *** UNRECOVERABLE ERROR in ready_wait, aborting ***\n");
        return -1;
      }

      // rc == -1: timeout/hang. Try to recover.
      total_kernel_hangs_++;
      DBG_PRINT("[VXDRV] *** KERNEL HANG DETECTED *** (attempt %u/%u, total_hangs=%u/%lu)\n",
             attempts + 1, max_retries_ + 1, total_kernel_hangs_, total_kernel_launches_);
      fflush(stdout);

      if (attempts < max_retries_) {
        DBG_PRINT("[VXDRV] Recovery: AP_RESET + re-launch kernel...\n");
        int reset_rc = this->force_hw_reset();
        if (reset_rc != 0) {
          DBG_PRINT("[VXDRV] *** FATAL: AP_RESET failed during recovery! ***\n");
          return -1;
        }

        // Progressive cooldown between retries: 1ms, 2ms, 3ms...
        usleep(1000 * (attempts + 1));

        // Re-launch the same kernel
        int start_rc = this->start_once(last_krnl_addr_, last_args_addr_);
        if (start_rc != 0) {
          DBG_PRINT("[VXDRV] *** Re-launch failed (rc=%d). Aborting. ***\n", start_rc);
          return -1;
        }
        DBG_PRINT("[VXDRV] Kernel re-launched, waiting again...\n");
      }
      attempts++;
    }

    DBG_PRINT("[VXDRV] *** GIVING UP after %u attempts. Kernel at 0x%lx is unhealable. ***\n",
           max_retries_ + 1, last_krnl_addr_);
    return -1;
  }

  // =========================================================================
  // ready_wait_once(): single attempt to poll for completion
  //  Returns: 0 = success, -1 = timeout, -2 = unrecoverable error
  // =========================================================================
  int ready_wait_once(uint64_t timeout) {
    struct timespec sleep_time;
  #ifndef NDEBUG
    sleep_time.tv_sec = 1;
    sleep_time.tv_nsec = 0;
  #else
    sleep_time.tv_sec = 0;
    sleep_time.tv_nsec = 1000000;
  #endif

    uint64_t sleep_time_ms = (sleep_time.tv_sec * 1000) + (sleep_time.tv_nsec / 1000000);

    DBG_PRINT("[VXDRV-DIAG] ready_wait: timeout=%lu ms, poll_interval=%lu ms\n", timeout, sleep_time_ms);
    uint64_t elapsed_ms = 0;
    uint32_t poll_count = 0;
#ifdef DEBUG_XRT
    uint64_t last_report_ms = 0;
    uint32_t last_status = 0xDEAD;  // track status changes
    uint64_t status_unchanged_since_ms = 0;
#endif

    for (;;) {
      uint32_t status = 0;
      // Use validated read to detect PCIe errors
      int rrc = this->read_register_validated(MMIO_CTL_ADDR, &status);
      if (rrc != 0) {
        DBG_PRINT("[VXDRV] *** MMIO read failed in ready_wait (rc=%d). Unrecoverable. ***\n", rrc);
        fflush(stdout);
        return -2;  // Unrecoverable PCIe error
      }
      ++poll_count;

      bool ap_done  = (status & CTL_AP_DONE)  != 0;
      bool ap_idle  = (status & CTL_AP_IDLE)  != 0;

      if (ap_done)
        break;

      // Track if status is changing (progress detection)
#ifdef DEBUG_XRT
      if (status != last_status) {
        last_status = status;
        status_unchanged_since_ms = elapsed_ms;
      }
#endif

      // [DIAG] Periodic status report (every 2s when things look stuck)
#ifdef DEBUG_XRT
      uint64_t report_interval = (elapsed_ms > 3000) ? 2000 : 5000;
      if (elapsed_ms > 0 && elapsed_ms - last_report_ms >= report_interval) {
        bool ap_start = (status & CTL_AP_START) != 0;
        bool ap_ready = (status & CTL_AP_READY) != 0;
        uint64_t stuck_ms = elapsed_ms - status_unchanged_since_ms;
        DBG_PRINT("[VXDRV-DIAG] ready_wait: STILL WAITING after %lu ms (%u polls). "
               "status=0x%x [start=%d done=%d idle=%d ready=%d], "
               "status_unchanged=%lu ms, remaining=%lu ms\n",
               elapsed_ms, poll_count, status,
               ap_start, ap_done, ap_idle, ap_ready,
               stuck_ms, timeout);
        fflush(stdout);
        last_report_ms = elapsed_ms;
      }
#endif

      // [DIAG] Detect suspicious states
      bool ap_start = (status & CTL_AP_START) != 0;
      if (elapsed_ms > 200 && !ap_start && !ap_done && ap_idle) {
        // GPU went IDLE without setting DONE — HW may have missed the start
        DBG_PRINT("[VXDRV-DIAG] *** SUSPICIOUS: AP_IDLE=1 but AP_DONE=0 — "
               "HW in IDLE without completion. Possibly missed AP_START. (status=0x%x) ***\n", status);
        fflush(stdout);
        // This is recoverable by the retry mechanism
        return -1;
      }

      // Check timeout
      if (timeout <= sleep_time_ms) {
        DBG_PRINT("[VXDRV-DIAG] ready_wait: TIMEOUT after %lu ms (%u polls). "
               "Last status=0x%x\n",
               elapsed_ms, poll_count, status);
        fflush(stdout);
        return -1;  // Timeout — caller will handle retry
      }

      nanosleep(&sleep_time, nullptr);
      timeout -= sleep_time_ms;
      elapsed_ms += sleep_time_ms;
    };

    DBG_PRINT("[VXDRV-DIAG] ready_wait: AP_DONE after %lu ms (%u polls)\n", elapsed_ms, poll_count);
    fflush(stdout);

    // Record latency for adaptive timeout
    this->record_kernel_latency(elapsed_ms);

    // Verify HW reached IDLE after AP_DONE
    for (int ack_retry = 0; ack_retry < 100; ++ack_retry) {
      uint32_t post_status = 0;
      CHECK_ERR(this->read_register(MMIO_CTL_ADDR, &post_status), {
        return err;
      });
      if (post_status & CTL_AP_IDLE) {
        DBG_PRINT("[VXDRV-DIAG] ready_wait: HW confirmed IDLE (status=0x%x) after %d extra reads\n",
               post_status, ack_retry + 1);
        break;
      }
      if (ack_retry == 99) {
        DBG_PRINT("[VXDRV-DIAG] *** WARNING: HW did NOT reach IDLE after AP_DONE! status=0x%x. Forcing AP_RESET. ***\n", post_status);
        this->force_hw_reset();
      }
      struct timespec ack_wait = {0, 100000}; // 0.1ms
      nanosleep(&ack_wait, nullptr);
    }

    shm_.set_state(VX_STATE_IDLE);
    return 0;
  }

  int dcr_write(uint32_t addr, uint32_t value) {
    CHECK_ERR(this->write_register(MMIO_DCR_ADDR, addr), {
      return err;
    });
    CHECK_ERR(this->write_register(MMIO_DCR_ADDR + 4, value), {
      return err;
    });
    dcrs_.write(addr, value);
    return 0;
  }

  int dcr_read(uint32_t addr, uint32_t *value) const {
    return dcrs_.read(addr, value);
  }

  int mpm_query(uint32_t addr, uint32_t core_id, uint64_t *value) {
    uint32_t offset = addr - VX_CSR_MPM_BASE;
    if (offset > 31)
      return -1;
    if (mpm_cache_.count(core_id) == 0) {
      uint64_t mpm_mem_addr = IO_MPM_ADDR + core_id * 32 * sizeof(uint64_t);
      CHECK_ERR(this->download(mpm_cache_[core_id].data(), mpm_mem_addr, 32 * sizeof(uint64_t)), {
        return err;
      });
    }
    *value = mpm_cache_.at(core_id).at(offset);
    return 0;
  }

  void smi_set_kernel_name(const char *name) {
    shm_.set_kernel_name(name);
  }

private:

  MemoryAllocator global_mem_;
  xrt_device_t xrtDevice_;
  xrt_kernel_t xrtKernel_;
  uint64_t dev_caps_;
  uint64_t isa_caps_;
  uint64_t global_mem_size_;
  DeviceConfig dcrs_;
  std::unordered_map<uint32_t, std::array<uint64_t, 32>> mpm_cache_;
  uint32_t lg2_num_banks_;
  uint32_t lg2_bank_size_;
  ShmStatus shm_;

  // Hang-prevention state
  uint64_t kernel_timeout_ms_;     // 0 = adaptive, >0 = fixed ms
  uint32_t max_retries_;           // max retry count on hang
  uint64_t inter_kernel_delay_us_; // us delay between kernels
  double   kernel_history_avg_ms_; // EMA of kernel latencies
  uint64_t kernel_history_count_;  // number of recorded latencies
  uint64_t total_kernel_launches_; // lifetime launch count
  uint32_t total_kernel_hangs_;    // lifetime hang count
  uint64_t last_krnl_addr_;        // saved for retry
  uint64_t last_args_addr_;        // saved for retry

#ifdef BANK_INTERLEAVE

  std::vector<xrt_buffer_t> xrtBuffers_;

  int get_bank_info(uint64_t addr, uint32_t *pIdx, uint64_t *pOff) {
    uint32_t num_banks = 1 << lg2_num_banks_;
    uint64_t block_addr = addr / CACHE_BLOCK_SIZE;
    uint32_t index = block_addr & (num_banks - 1);
    uint64_t offset = (block_addr >> lg2_num_banks_) * CACHE_BLOCK_SIZE;
    if (pIdx) {
      *pIdx = index;
    }
    if (pOff) {
      *pOff = offset;
    }
    //DBG_PRINT("get_bank_info(addr=0x%lx, bank=%d, offset=0x%lx\n", addr, index, offset);
    return 0;
  }

  int get_buffer(uint32_t bank_id, xrt_buffer_t *pBuf) {
    if (pBuf) {
      *pBuf = xrtBuffers_.at(bank_id);
    }
    return 0;
  }

#else

  struct buf_cnt_t {
    xrt_buffer_t xrtBuffer;
    uint32_t count;
  };

  std::unordered_map<uint32_t, buf_cnt_t> xrtBuffers_;

  int get_bank_info(uint64_t addr, uint32_t *pIdx, uint64_t *pOff) {
    uint32_t num_banks = 1 << lg2_num_banks_;
    uint64_t bank_size = 1ull << lg2_bank_size_;
    uint32_t index = addr >> lg2_bank_size_;
    uint64_t offset = addr & (bank_size - 1);
    if (index >= num_banks) {
      fprintf(stderr, "[VXDRV] Error: address out of range: 0x%lx (bank=%u >= num_banks=%u)\n", addr, index, num_banks);
      return -1;
    }
    if (pIdx) {
      *pIdx = index;
    }
    if (pOff) {
      *pOff = offset;
    }
    //DBG_PRINT("get_bank_info(addr=0x%lx, bank=%d, offset=0x%lx\n", addr, index, offset);
    return 0;
  }

  int get_buffer(uint32_t bank_id, xrt_buffer_t *pBuf) {
    auto it = xrtBuffers_.find(bank_id);
    if (it != xrtBuffers_.end()) {
      if (pBuf) {
        *pBuf = it->second.xrtBuffer;
      } else {
        // Increment refcount (new allocation referencing this bank)
        if (it->second.count == 0) {
          DBG_PRINT("reactivating cached bank%d...\n", bank_id);
        } else {
          DBG_PRINT("reusing bank%d...\n", bank_id);
        }
        ++it->second.count;
      }
    } else {
      DBG_PRINT("allocating bank%d...\n", bank_id);
      uint64_t bank_size = 1ull << lg2_bank_size_;
    #ifdef CPP_API
      xrt::bo xrtBuffer(xrtDevice_, bank_size, xrt::bo::flags::normal, bank_id);
    #else
      CHECK_HANDLE(xrtBuffer, xrtBOAlloc(xrtDevice_, bank_size, XRT_BO_FLAGS_NONE, bank_id), {
        return -1;
      });
    #endif
      // pBuf!=nullptr path can be reached by upload/download on a secondary
      // bank of a cross-bank transfer. Keep refcount at 0 in that case to
      // avoid leaking logical references.
      uint32_t init_count = (pBuf != nullptr) ? 0 : 1;
      xrtBuffers_.insert({bank_id, {xrtBuffer, init_count}});
      if (pBuf) {
        *pBuf = xrtBuffer;
      }
    }
    return 0;
  }

#endif
};

#include <callbacks.inc>
