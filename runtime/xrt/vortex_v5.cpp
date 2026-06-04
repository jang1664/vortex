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

#include <limits>
#include <stdarg.h>
#include <string>
#include <unistd.h>
#include <unordered_map>
#include <util.h>
#include <vector>

#ifdef ENABLE_HW_DEBUG_MODULE
#include "vx_hw_debug.h"
#endif

// vortex-smi shared memory support
#include <vx_shm_helper.h>

using namespace vortex;

#ifndef XRTSIM
#define CPP_API
#endif

#define MMIO_CTL_ADDR 0x00
#define MMIO_DEV_ADDR 0x10
#define MMIO_ISA_ADDR 0x18
#define MMIO_DCR_ADDR 0x20
#define MMIO_SCP_ADDR 0x28
#define MMIO_MEM_ADDR 0x30

#ifdef ENABLE_HW_DEBUG_MODULE
#ifndef HW_DEBUG_PC_RING_DEPTH
#define HW_DEBUG_PC_RING_DEPTH VX_HW_DEBUG_DEFAULT_PC_RING_DEPTH
#endif
#endif

#if defined(ENABLE_HW_DEBUG_MODULE) && defined(NDEBUG)
#define VX_HW_DEBUG_READY_WAIT_POLL 1
#endif

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
    printf("[VXDRV] Error: '%s' returned NULL!\n", #_expr);                    \
    _cleanup                                                                   \
  }

#ifndef CPP_API
static void dump_xrt_error(xrtDeviceHandle xrtDevice, xrtErrorCode err) {
  size_t len = 0;
  xrtErrorGetString(xrtDevice, err, nullptr, 0, &len);
  std::vector<char> buf(len);
  xrtErrorGetString(xrtDevice, err, buf.data(), buf.size(), nullptr);
  printf("[VXDRV] detail: %s!\n", buf.data());
}
#endif

static bool is_xrt_emulation() {
#ifdef XRTSIM
  return true;
#else
  const char* emu_mode = getenv("XCL_EMULATION_MODE");
  return emu_mode != nullptr && emu_mode[0] != '\0';
#endif
}

static void get_xrt_shm_path_policy(
  int /*device_index*/,
  const std::string& /*device_bdf*/,
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

enum class XrtMemMapMode {
  Legacy,
  Remap,
};

#ifdef PLATFORM_MEMORY_REMAP
#define VX_USE_PLATFORM_MEMORY_REMAP
#endif

#if defined(PLATFORM_MEMORY_REMAP) || defined(BANK_INTERLEAVE)
#define VX_USE_BANKED_XRT_BO
#endif

#ifdef VX_USE_PLATFORM_MEMORY_REMAP
static constexpr XrtMemMapMode kXrtMemMapMode = XrtMemMapMode::Remap;
#else
static constexpr XrtMemMapMode kXrtMemMapMode = XrtMemMapMode::Legacy;
#endif

static const char* xrt_mem_map_mode_name(XrtMemMapMode mode) {
  switch (mode) {
  case XrtMemMapMode::Legacy:
    return "legacy";
  case XrtMemMapMode::Remap:
    return "remap";
  }
  return "unknown";
}

///////////////////////////////////////////////////////////////////////////////

class vx_device {
public:
  vx_device()
    : global_mem_(ALLOC_BASE_ADDR,
                  GLOBAL_MEM_SIZE - ALLOC_BASE_ADDR,
                  RAM_PAGE_SIZE,
                  CACHE_BLOCK_SIZE)
  #ifdef VX_USE_BANKED_XRT_BO
    , bo_size_(0)
  #endif
  #ifndef CPP_API
    , xrtDevice_(nullptr)
    , xrtKernel_(nullptr)
  #endif
    , pending_ap_done_(false)
  {}

  ~vx_device() {
    shm_.close();
  #ifdef SCOPE
    vx_scope_stop(this);
  #endif
  #ifndef CPP_API
    for (auto &entry : xrtBuffers_) {
    #ifdef VX_USE_BANKED_XRT_BO
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
    auto uuid = xrtDevice.load_xclbin(std::string(xlbin_path_s));
    auto xrtKernel = xrt::ip(xrtDevice, uuid, KERNEL_NAME);
    auto xclbin = xrt::xclbin(std::string(xlbin_path_s));
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

    printf("info: device name=%s, memory_capacity=0x%lx bytes, memory_banks=%ld, xrt_mem_map=%s.\n",
           device_name.c_str(), global_mem_size_, num_banks,
           xrt_mem_map_mode_name(kXrtMemMapMode));

  #ifdef VX_USE_BANKED_XRT_BO
    // hw_emu sim_qdma has an off-by-one in its PC-region bookkeeping when
    // BO size exactly equals bank_size: allocating BO[0]=bank_size also
    // registers a stale region for the next PC, and BO[1]'s later alloc
    // then hits a duplicate and eventually FATAL. Subtracting one page
    // keeps the BO one cache page below the PC boundary and avoids the
    // trigger entirely. Real HW does not exhibit this and uses bank_size.
    bo_size_ = bank_size;
    if (is_xrt_emulation() && bo_size_ > RAM_PAGE_SIZE) {
      bo_size_ -= RAM_PAGE_SIZE;
      printf("info: hw_emu detected, BO size reduced to 0x%lx (bank_size-1page) "
             "to avoid sim_qdma region conflict.\n", bo_size_);
    }

    xrtBuffers_.reserve(num_banks);
    for (uint32_t i = 0; i < num_banks; ++i) {
    #ifdef CPP_API
      xrtBuffers_.emplace_back(xrtDevice_, bo_size_, xrt::bo::flags::normal, i);
    #else
      CHECK_HANDLE(xrtBuffer, xrtBOAlloc(xrtDevice_, bo_size_, XRT_BO_FLAGS_NONE, i), {
         return -1;
      });
      xrtBuffers_.push_back(xrtBuffer);
    #endif
    }
    printf("info: allocated %lu banks, size=0x%lx each.\n", num_banks, bo_size_);
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
    printf("[VXDRV] status shm: path=%s, unlink_on_close=%d\n",
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
  #ifndef VX_USE_BANKED_XRT_BO
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
  #ifndef VX_USE_BANKED_XRT_BO
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
    shm_.update_mem(global_mem_.allocated(), global_mem_.free());
    return 0;
  }

  int mem_free(uint64_t dev_addr) {
    CHECK_ERR(global_mem_.release(dev_addr), {
      return err;
    });
  #ifdef VX_USE_BANKED_XRT_BO
    // Banked XRT BOs are pre-allocated in init and released in dtor.
    // Individual mem_free calls do not touch xrtBuffers_ (the device may
    // still need them, e.g. vx_dump_perf -> mpm_query -> download).
  #else
    uint32_t bank_id;
    CHECK_ERR(this->get_bank_info(dev_addr, &bank_id, nullptr), {
      return err;
    });
    auto it = xrtBuffers_.find(bank_id);
    if (it != xrtBuffers_.end()) {
      auto count = --it->second.count;
      if (0 == count) {
        printf("freeing bank%d...\n", bank_id);
      #ifndef CPP_API
        xrtBOFree(it->second.xrtBuffer);
      #endif
        xrtBuffers_.erase(it);
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
    auto host_ptr = (const uint8_t *)src;

    if (!is_aligned(dev_addr, CACHE_BLOCK_SIZE))
      return -1;

    auto asize = aligned_size(size, CACHE_BLOCK_SIZE);
    if (dev_addr + asize > global_mem_size_)
      return -1;

    shm_.set_state(VX_STATE_UPLOADING);
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

      uint64_t xfer_size;
#ifdef VX_USE_BANKED_XRT_BO
      xfer_size = (remaining > CACHE_BLOCK_SIZE) ? CACHE_BLOCK_SIZE : remaining;
      // In hw_emu the last page of each bank is not backed (bo_size_ =
      // bank_size - 1 page). Flag accesses that would fall outside before
      // XRT throws.
      if (bo_offset + xfer_size > bo_size_) {
        fprintf(stderr, "[VXDRV] upload oob: dev_addr=0x%lx bank=%u off=0x%lx "
                        "xfer=0x%lx bo_size=0x%lx\n",
                dev_addr, bo_index, bo_offset, xfer_size, bo_size_);
        return -1;
      }
#else
      uint64_t bank_size = 1ull << lg2_bank_size_;
      uint64_t bank_headroom = bank_size - bo_offset;
      xfer_size = (remaining > bank_headroom) ? bank_headroom : remaining;
#endif
      if (xfer_size == 0)
        return -1;

    #ifdef CPP_API
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
    auto host_ptr = (uint8_t *)dest;

    if (!is_aligned(dev_addr, CACHE_BLOCK_SIZE))
      return -1;

    auto asize = aligned_size(size, CACHE_BLOCK_SIZE);
    if (dev_addr + asize > global_mem_size_)
      return -1;

    shm_.set_state(VX_STATE_DOWNLOADING);
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

      uint64_t xfer_size;
#ifdef VX_USE_BANKED_XRT_BO
      xfer_size = (remaining > CACHE_BLOCK_SIZE) ? CACHE_BLOCK_SIZE : remaining;
      if (bo_offset + xfer_size > bo_size_) {
        fprintf(stderr, "[VXDRV] download oob: dev_addr=0x%lx bank=%u off=0x%lx "
                        "xfer=0x%lx bo_size=0x%lx\n",
                dev_addr, bo_index, bo_offset, xfer_size, bo_size_);
        return -1;
      }
#else
      uint64_t bank_size = 1ull << lg2_bank_size_;
      uint64_t bank_headroom = bank_size - bo_offset;
      xfer_size = (remaining > bank_headroom) ? bank_headroom : remaining;
#endif
      if (xfer_size == 0)
        return -1;

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

  int start(uint64_t krnl_addr, uint64_t args_addr) {
    // Pre-flight status read
    uint32_t status = 0;
    CHECK_ERR(this->read_register(MMIO_CTL_ADDR, &status), {
      return err;
    });

    CHECK_ERR(this->dcr_write(VX_DCR_BASE_STARTUP_ADDR0, krnl_addr & 0xffffffff), {
      return err;
    });
    CHECK_ERR(this->dcr_write(VX_DCR_BASE_STARTUP_ADDR1, krnl_addr >> 32), {
      return err;
    });
    CHECK_ERR(this->dcr_write(VX_DCR_BASE_STARTUP_ARG0, args_addr & 0xffffffff), {
      return err;
    });
    CHECK_ERR(this->dcr_write(VX_DCR_BASE_STARTUP_ARG1, args_addr >> 32), {
      return err;
    });

    // Ordering barrier: ensure DCR writes commit before AP_START.
    CHECK_ERR(this->read_register(MMIO_CTL_ADDR, &status), {
      return err;
    });

    CHECK_ERR(this->write_register(MMIO_CTL_ADDR, CTL_AP_START), {
      return err;
    });

    // Barrier after AP_START to avoid posted-write timing surprises.
    // AP_DONE is read-clear on ap_ctrl_hs.  Tiny kernels can complete before
    // this barrier read, so latch that completion for ready_wait().
    CHECK_ERR(this->read_register(MMIO_CTL_ADDR, &status), {
      return err;
    });
    pending_ap_done_ = (status & CTL_AP_DONE) != 0;

    mpm_cache_.clear();
    shm_.record_kernel(krnl_addr);
    shm_.set_state(VX_STATE_RUNNING);

    return 0;
  }

#ifdef ENABLE_HW_DEBUG_MODULE
  static int hw_debug_read32(void *opaque, uint32_t addr, uint32_t *value) {
    return static_cast<vx_device *>(opaque)->read_register(addr, value);
  }

  static int hw_debug_write32(void *opaque, uint32_t addr, uint32_t value) {
    return static_cast<vx_device *>(opaque)->write_register(addr, value);
  }

  void dump_hw_debug() {
    vx_hw_debug_io_t io = {
      this,
      &vx_device::hw_debug_read32,
      &vx_device::hw_debug_write32
    };
    (void)vx_hw_debug_dump(stderr, &io, NUM_DMA_CHANNELS, HW_DEBUG_PC_RING_DEPTH, "[VXDRV-HWDBG]");
  }

  void poll_hw_debug_flags(vx_hw_debug_flag_snapshot_t *previous) {
    vx_hw_debug_io_t io = {
      this,
      &vx_device::hw_debug_read32,
      &vx_device::hw_debug_write32
    };
    int err = vx_hw_debug_poll_flags(stderr, &io, NUM_DMA_CHANNELS, previous, "[VXDRV-HWDBG]");
    if (err != 0) {
      fprintf(stderr, "[VXDRV-HWDBG] flag poll failed: %d\n", err);
    }
  }
#endif

  int ready_wait(uint64_t timeout) {
    struct timespec sleep_time;
  #ifndef NDEBUG
    // If you want slow polling for easier debugging, set VORTEX_READY_WAIT_SLOW=1 MACRO
  #ifdef VORTEX_READY_WAIT_SLOW
    sleep_time.tv_sec = 1;
    sleep_time.tv_nsec = 0;
  #else
    sleep_time.tv_sec = 0;
    sleep_time.tv_nsec = 1000000;
  #endif
  #else
    sleep_time.tv_sec = 0;
    sleep_time.tv_nsec = 1000000;
  #endif

    uint64_t sleep_time_ms = (sleep_time.tv_sec * 1000) + (sleep_time.tv_nsec / 1000000);

  #ifdef VX_HW_DEBUG_READY_WAIT_POLL
    vx_hw_debug_flag_snapshot_t hw_debug_previous = {};
    uint64_t hw_debug_poll_elapsed_ms = 0;
    const uint64_t hw_debug_poll_period_ms = 1000;
  #endif

    for (;;) {
      if (pending_ap_done_) {
        pending_ap_done_ = false;
        break;
      }

      uint32_t status = 0;
      CHECK_ERR(this->read_register(MMIO_CTL_ADDR, &status), {
        return err;
      });
      bool is_done = (status & CTL_AP_DONE) == CTL_AP_DONE;
      if (is_done)
        break;
    #ifdef VX_HW_DEBUG_READY_WAIT_POLL
      if (hw_debug_poll_elapsed_ms == 0 || hw_debug_poll_elapsed_ms >= hw_debug_poll_period_ms) {
        this->poll_hw_debug_flags(&hw_debug_previous);
        hw_debug_poll_elapsed_ms = 0;
      }
    #endif
      if (0 == timeout) {
      #ifdef ENABLE_HW_DEBUG_MODULE
        this->dump_hw_debug();
      #endif
        return -1;
      }
      nanosleep(&sleep_time, nullptr);
    #ifdef VX_HW_DEBUG_READY_WAIT_POLL
      hw_debug_poll_elapsed_ms += sleep_time_ms;
    #endif
      timeout -= sleep_time_ms;
    };

    // Wait briefly for AP_IDLE and allow outstanding write path to settle
    // before host-side download starts.
    {
      const struct timespec idle_poll = {0, 100000};
      const struct timespec settle_wait = {0, 500000};
      const uint32_t idle_retries = 200;
      for (uint32_t i = 0; i < idle_retries; ++i) {
        uint32_t status = 0;
        CHECK_ERR(this->read_register(MMIO_CTL_ADDR, &status), {
          return err;
        });
        bool is_idle = (status & CTL_AP_IDLE) == CTL_AP_IDLE;
        if (is_idle)
          break;
        nanosleep(&idle_poll, nullptr);
      }
      nanosleep(&settle_wait, nullptr);
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

  void smi_set_kernel_name(const char* name) {
    shm_.set_kernel_name(name);
  }

private:

  MemoryAllocator global_mem_;
#ifdef VX_USE_BANKED_XRT_BO
  uint64_t bo_size_;  // per-bank BO size (bank_size, or bank_size-1page in hw_emu)
#endif
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
  bool pending_ap_done_;

#ifdef VX_USE_BANKED_XRT_BO

  std::vector<xrt_buffer_t> xrtBuffers_;

  int get_bank_info_legacy(uint64_t addr, uint32_t *pIdx, uint64_t *pOff) const {
    uint32_t num_banks = 1 << lg2_num_banks_;
    uint64_t block_addr = addr / CACHE_BLOCK_SIZE;
    uint64_t byte_off = addr & (CACHE_BLOCK_SIZE - 1);
    uint32_t index = (uint32_t)(block_addr & (num_banks - 1));
    uint64_t offset = (block_addr >> lg2_num_banks_) * CACHE_BLOCK_SIZE + byte_off;
    if (pIdx) {
      *pIdx = index;
    }
    if (pOff) {
      *pOff = offset;
    }
    return 0;
  }

  int get_bank_info_remap(uint64_t addr, uint32_t *pIdx, uint64_t *pOff) const {
    // Mirror of hw/rtl/core/VX_mem_remap.sv. Parameter names kept in sync:
    //   NUM_BANKS      = total HBM banks
    //   NUM_PORTS      = AXI / HBM ports (= NUM_DMA_CHANNELS)
    //   BANKS_PER_PORT = NUM_BANKS / NUM_PORTS
    // Decompose block_idx = q*NUM_PORTS + r, then
    //   bank   = BANKS_PER_PORT*r + (q % BANKS_PER_PORT)
    //   offset = (q / BANKS_PER_PORT) * BLOCK + byte_off
    constexpr uint32_t NUM_BANKS      = PLATFORM_MEMORY_NUM_BANKS;
    constexpr uint32_t NUM_PORTS      = NUM_DMA_CHANNELS;
    constexpr uint32_t BANKS_PER_PORT = NUM_BANKS / NUM_PORTS;
    static_assert(NUM_BANKS % NUM_PORTS == 0,
                  "NUM_BANKS must be a multiple of NUM_PORTS");
    static_assert(ispow2(NUM_PORTS),      "NUM_PORTS must be a power of 2");
    static_assert(ispow2(BANKS_PER_PORT), "BANKS_PER_PORT must be a power of 2");
    constexpr uint32_t PORT_BITS  = log2ceil(NUM_PORTS);
    constexpr uint32_t LOCAL_BITS = log2ceil(BANKS_PER_PORT);

    uint64_t block_addr = addr / CACHE_BLOCK_SIZE;
    uint64_t byte_off   = addr & (CACHE_BLOCK_SIZE - 1);
    uint64_t q          = block_addr >> PORT_BITS;
    uint32_t r          = (uint32_t)(block_addr & (NUM_PORTS - 1));
    uint32_t index      = (r << LOCAL_BITS)
                        | (uint32_t)(q & (BANKS_PER_PORT - 1));
    uint64_t offset     = (q >> LOCAL_BITS) * CACHE_BLOCK_SIZE + byte_off;
    if (pIdx) {
      *pIdx = index;
    }
    if (pOff) {
      *pOff = offset;
    }
    return 0;
  }

  int get_bank_info(uint64_t addr, uint32_t *pIdx, uint64_t *pOff) const {
    if constexpr (kXrtMemMapMode == XrtMemMapMode::Legacy) {
      return get_bank_info_legacy(addr, pIdx, pOff);
    }
    return get_bank_info_remap(addr, pIdx, pOff);
  }

  int get_buffer(uint32_t bank_id, xrt_buffer_t *pBuf) {
    if (bank_id >= xrtBuffers_.size()) {
      fprintf(stderr, "[VXDRV] Error: invalid bank id: %u (num_banks=%zu)\n",
              bank_id, xrtBuffers_.size());
      return -1;
    }
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
    if (index > num_banks) {
      fprintf(stderr, "[VXDRV] Error: address out of range: 0x%lx\n", addr);
      return -1;
    }
    if (pIdx) {
      *pIdx = index;
    }
    if (pOff) {
      *pOff = offset;
    }
    return 0;
  }

  int get_buffer(uint32_t bank_id, xrt_buffer_t *pBuf) {
    auto it = xrtBuffers_.find(bank_id);
    if (it != xrtBuffers_.end()) {
      if (pBuf) {
        *pBuf = it->second.xrtBuffer;
      } else {
        printf("reusing bank%d...\n", bank_id);
        ++it->second.count;
      }
    } else {
      printf("allocating bank%d...\n", bank_id);
      uint64_t bank_size = 1ull << lg2_bank_size_;
    #ifdef CPP_API
      xrt::bo xrtBuffer(xrtDevice_, bank_size, xrt::bo::flags::normal, bank_id);
    #else
      CHECK_HANDLE(xrtBuffer, xrtBOAlloc(xrtDevice_, bank_size, XRT_BO_FLAGS_NONE, bank_id), {
        return -1;
      });
    #endif
      xrtBuffers_.insert({bank_id, {xrtBuffer, 1}});
      if (pBuf) {
        *pBuf = xrtBuffer;
      }
    }
    return 0;
  }

#endif
};

#include <callbacks.inc>
