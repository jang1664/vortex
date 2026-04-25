#include "driver.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>

namespace {

#define DRV_CHECK(_expr)                                          \
  do {                                                            \
    int _ret = (_expr);                                           \
    if (_ret != 0) {                                              \
      std::fprintf(stderr,                                        \
                   "[SoftmaxDriver] '%s' returned %d\n",          \
                   #_expr, _ret);                                 \
      std::exit(-1);                                              \
    }                                                             \
  } while (0)

} // namespace

SoftmaxDriver::SoftmaxDriver(vx_device_h device, const SoftmaxConfig& cfg)
    : device_(device), cfg_(cfg) {
  // Query device caps for thread count (used to size block_dim).
  uint64_t num_warps = 0, num_threads = 0;
  DRV_CHECK(vx_dev_caps(device_, VX_CAPS_NUM_WARPS, &num_warps));
  DRV_CHECK(vx_dev_caps(device_, VX_CAPS_NUM_THREADS, &num_threads));

  buffer_bytes_ = input_size_bytes();

  // Input buffer: read-only from device.
  DRV_CHECK(vx_mem_alloc(device_, buffer_bytes_, VX_MEM_READ, &input_buffer_));
  // Output buffer: kernel reads back exp values during normalization, so it
  // must be R/W to allow load-after-store within the kernel.
  DRV_CHECK(vx_mem_alloc(device_, buffer_bytes_,
                         VX_MEM_READ | VX_MEM_WRITE, &output_buffer_));

  // Build kernel_arg_t. Layout matches softmax_args.h.
  kernel_arg_t kargs = {};
  kargs.kernel_id = KERNEL_SOFTMAX;

  // One block per row, threads/block sized to the device's warp*thread count
  // (capped at 256 — matches the previous main.cpp behavior).
  uint32_t total_rows = cfg_.batch_size * cfg_.num_heads * cfg_.seq_len_q;
  uint32_t threads_per_block = std::min(256u,
      static_cast<uint32_t>(num_warps * num_threads));

  kargs.grid_dim[0]  = total_rows;
  kargs.grid_dim[1]  = 1;
  kargs.grid_dim[2]  = 1;
  kargs.block_dim[0] = threads_per_block;
  kargs.block_dim[1] = 1;
  kargs.block_dim[2] = 1;

  DRV_CHECK(vx_mem_address(input_buffer_,  &kargs.input_addr));
  DRV_CHECK(vx_mem_address(output_buffer_, &kargs.output_addr));
  kargs.mask_addr = 0;   // causal mask is implicit in the kernel (use_mask flag)

  kargs.batch_size = cfg_.batch_size;
  kargs.num_heads  = cfg_.num_heads;
  kargs.seq_len_q  = cfg_.seq_len_q;
  kargs.seq_len_k  = cfg_.seq_len_k;
  kargs.use_mask   = cfg_.use_mask;
  kargs.scale      = cfg_.scale;

  DRV_CHECK(vx_upload_bytes(device_, &kargs, sizeof(kargs), &args_buffer_));
}

SoftmaxDriver::~SoftmaxDriver() {
  if (krnl_buffer_)   vx_mem_free(krnl_buffer_);
  if (args_buffer_)   vx_mem_free(args_buffer_);
  if (output_buffer_) vx_mem_free(output_buffer_);
  if (input_buffer_)  vx_mem_free(input_buffer_);
}

size_t SoftmaxDriver::input_size_elems() const {
  return static_cast<size_t>(cfg_.batch_size) * cfg_.num_heads
       * cfg_.seq_len_q * cfg_.seq_len_k;
}

size_t SoftmaxDriver::input_size_bytes() const {
  return input_size_elems() * sizeof(float);
}

void SoftmaxDriver::upload_inputs(const float* host) {
  DRV_CHECK(vx_copy_to_dev(input_buffer_, host, 0, buffer_bytes_));
}

void SoftmaxDriver::upload_kernel(const std::string& vxbin_path) {
  // vx_upload_kernel_file replaces the staged kernel; free any previous one.
  if (krnl_buffer_) {
    vx_mem_free(krnl_buffer_);
    krnl_buffer_ = nullptr;
  }
  DRV_CHECK(vx_upload_kernel_file(device_, vxbin_path.c_str(), &krnl_buffer_));
}

void SoftmaxDriver::launch() {
  DRV_CHECK(vx_start(device_, krnl_buffer_, args_buffer_));
  DRV_CHECK(vx_ready_wait(device_, VX_MAX_TIMEOUT));
}

void SoftmaxDriver::download(float* host) {
  DRV_CHECK(vx_copy_from_dev(host, output_buffer_, 0, buffer_bytes_));
}
