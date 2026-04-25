// driver.h — host-side driver for the softmax kernel.
//
// Owns the device-side buffers and kernel-args layout for the softmax kernel.
// Borrows vx_device_h (does NOT open/close the device).
//
// Typical use:
//   vx_device_h device;
//   RT_CHECK(vx_dev_open(&device));
//   SoftmaxDriver drv(device, cfg);
//   drv.upload_inputs(host_in.data());
//   drv.upload_kernel();           // default: "kernel.vxbin" in cwd
//   drv.launch();                  // vx_start + vx_ready_wait
//   drv.download(host_out.data());
//   vx_dev_close(device);

#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vortex.h>

#include "softmax_args.h"

struct SoftmaxConfig {
  uint32_t batch_size = 2;
  uint32_t num_heads  = 16;
  uint32_t seq_len_q  = 8;
  uint32_t seq_len_k  = 8;
  uint32_t use_mask   = 1;       // 1: causal mask
  float    scale      = 0.125f;  // 1/sqrt(64) — head_dim=64 default
};

class SoftmaxDriver {
public:
  // Allocates device buffers and uploads kernel_arg_t. Calls exit(-1) on
  // any vx_* failure (matches existing test semantics).
  SoftmaxDriver(vx_device_h device, const SoftmaxConfig& cfg);

  // Frees device buffers (null-checked).
  ~SoftmaxDriver();

  SoftmaxDriver(const SoftmaxDriver&) = delete;
  SoftmaxDriver& operator=(const SoftmaxDriver&) = delete;

  size_t input_size_elems() const;   // batch * heads * seq_q * seq_k
  size_t input_size_bytes() const;

  // Copy host floats to the device input buffer.
  void upload_inputs(const float* host);

  // Load and stage the kernel binary. `vxbin_path` is opened with the runtime
  // file API (relative to the process cwd by default).
  void upload_kernel(const std::string& vxbin_path = "kernel.vxbin");

  // vx_start + vx_ready_wait. Throws (via exit) on failure.
  void launch();

  // Copy the device output buffer back to host.
  void download(float* host);

  const SoftmaxConfig& config() const { return cfg_; }

  // Read-only accessors useful for tests/diagnostics.
  vx_device_h device() const { return device_; }

private:
  vx_device_h   device_;          // borrowed, not owned
  SoftmaxConfig cfg_;

  vx_buffer_h input_buffer_  = nullptr;
  vx_buffer_h output_buffer_ = nullptr;
  vx_buffer_h args_buffer_   = nullptr;
  vx_buffer_h krnl_buffer_   = nullptr;

  size_t buffer_bytes_ = 0;       // == input_size_bytes()
};
