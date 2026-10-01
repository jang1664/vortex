#include <algorithm>
#include <array>
#include <cinttypes>
#include <cstdint>
#include <iostream>
#include <string>
#include <vector>

#include <VX_config.h>
#include <vortex.h>

#include "common.h"

static_assert(NUM_BARRIERS == UP(NUM_WARPS / 2),
              "cta_resource supports only the default NUM_BARRIERS contract");

namespace {

const char* kernel_file = "kernel.vxbin";
vx_device_h device = nullptr;
vx_buffer_h dst_buffer = nullptr;
vx_buffer_h krnl_buffer = nullptr;
vx_buffer_h args_buffer = nullptr;

uint64_t num_threads = 0;
uint64_t num_warps = 0;
uint64_t num_cores = 0;
uint64_t local_mem_size = 0;

struct TestCase {
  const char* name;
  std::array<uint32_t, 3> grid;
  std::array<uint32_t, 3> block;
  bool require_batch_reuse;
};

void cleanup_case() {
  if (args_buffer) {
    vx_mem_free(args_buffer);
    args_buffer = nullptr;
  }
  if (dst_buffer) {
    vx_mem_free(dst_buffer);
    dst_buffer = nullptr;
  }
}

void cleanup() {
  cleanup_case();
  if (krnl_buffer) {
    vx_mem_free(krnl_buffer);
    krnl_buffer = nullptr;
  }
  if (device) {
    vx_dev_close(device);
    device = nullptr;
  }
}

#define RT_CHECK(_expr)                                                   \
  do {                                                                    \
    int _ret = (_expr);                                                   \
    if (_ret == 0)                                                        \
      break;                                                              \
    std::cerr << "Error: '" << #_expr << "' returned " << _ret << "!"  \
              << std::endl;                                              \
    cleanup();                                                            \
    return 1;                                                             \
  } while (false)

uint32_t checked_product(const std::array<uint32_t, 3>& dims) {
  uint64_t product = 1;
  for (uint32_t dim : dims)
    product *= dim;
  if (product > UINT32_MAX)
    return 0;
  return static_cast<uint32_t>(product);
}

uint32_t make_token(uint32_t block_id, uint32_t local_id) {
  return 0xc7000000u ^ (block_id * 0x10001u) ^ local_id;
}

uint64_t lmem_addr(const resource_result_t& result) {
  return (static_cast<uint64_t>(result.lmem_addr_hi) << 32)
       | result.lmem_addr_lo;
}

int report_error(const TestCase& test, uint32_t global_id,
                 const std::string& message, int errors) {
  if (errors < 32) {
    std::cerr << "*** " << test.name << " error at result #" << global_id
              << ": " << message << std::endl;
  }
  return errors + 1;
}

int run_case(const TestCase& test) {
  uint32_t block_size = checked_product(test.block);
  uint32_t block_count = checked_product(test.grid);
  uint64_t total_threads = static_cast<uint64_t>(block_size) * block_count;
  uint64_t dst_size = total_threads * sizeof(resource_result_t);
  uint32_t warps_per_group = (block_size + num_threads - 1) / num_threads;
  uint32_t groups_per_core = num_warps / warps_per_group;
  uint32_t needed_cores =
      (block_count * warps_per_group + num_warps - 1) / num_warps;
  uint32_t active_cores = std::min<uint64_t>(needed_cores, num_cores);

  if (block_size == 0 || block_size > num_threads * num_warps) {
    std::cerr << "Invalid test geometry for " << test.name << std::endl;
    return 1;
  }
  if (groups_per_core * kSharedBytesPerBlock > local_mem_size) {
    std::cerr << "LMEM is too small for " << test.name << std::endl;
    return 1;
  }

  std::cout << "CASE " << test.name
            << ": grid=(" << test.grid[0] << ',' << test.grid[1] << ','
            << test.grid[2] << ") block=(" << test.block[0] << ','
            << test.block[1] << ',' << test.block[2] << ')'
            << " block_threads=" << block_size
            << " warps_per_group=" << warps_per_group
            << " resident_groups_per_core=" << groups_per_core
            << " active_cores=" << active_cores << std::endl;

  kernel_arg_t arg = {};
  std::copy(test.block.begin(), test.block.end(), arg.block_dim);
  std::copy(test.grid.begin(), test.grid.end(), arg.grid_dim);

  int ret = vx_mem_alloc(device, dst_size, VX_MEM_WRITE, &dst_buffer);
  if (ret != 0) {
    std::cerr << "Error: vx_mem_alloc returned " << ret << '!' << std::endl;
    return 1;
  }
  ret = vx_mem_address(dst_buffer, &arg.dst_addr);
  if (ret != 0) {
    std::cerr << "Error: vx_mem_address returned " << ret << '!' << std::endl;
    cleanup_case();
    return 1;
  }
  ret = vx_upload_bytes(device, &arg, sizeof(arg), &args_buffer);
  if (ret != 0) {
    std::cerr << "Error: vx_upload_bytes returned " << ret << '!' << std::endl;
    cleanup_case();
    return 1;
  }
  ret = vx_start(device, krnl_buffer, args_buffer);
  if (ret == 0)
    ret = vx_ready_wait(device, VX_MAX_TIMEOUT);
  if (ret != 0) {
    std::cerr << "Error: kernel execution returned " << ret << '!' << std::endl;
    cleanup_case();
    return 1;
  }

  std::vector<resource_result_t> results(total_threads);
  ret = vx_copy_from_dev(results.data(), dst_buffer, 0, dst_size);
  if (ret != 0) {
    std::cerr << "Error: vx_copy_from_dev returned " << ret << '!' << std::endl;
    cleanup_case();
    return 1;
  }

  std::vector<uint32_t> core_starts(active_cores);
  std::vector<uint32_t> core_counts(active_cores);
  uint32_t base_count = block_count / active_cores;
  uint32_t extra_count = block_count % active_cores;
  uint32_t next_start = 0;
  for (uint32_t core = 0; core < active_cores; ++core) {
    core_starts[core] = next_start;
    core_counts[core] = base_count + (core < extra_count);
    next_start += core_counts[core];
  }

  std::vector<uint64_t> core_lmem_base(active_cores, UINT64_MAX);
  std::vector<uint32_t> block_visit_count(
      static_cast<size_t>(active_cores) * groups_per_core, 0);
  int errors = 0;

  for (uint32_t block_id = 0; block_id < block_count; ++block_id) {
    uint32_t expected_core = 0;
    while (expected_core + 1 < active_cores
        && block_id >= core_starts[expected_core] + core_counts[expected_core]) {
      ++expected_core;
    }
    uint32_t expected_slot =
        (block_id - core_starts[expected_core]) % groups_per_core;
    ++block_visit_count[expected_core * groups_per_core + expected_slot];

    for (uint32_t local_id = 0; local_id < block_size; ++local_id) {
      uint32_t global_id = block_id * block_size + local_id;
      const auto& result = results[global_id];

      std::array<uint32_t, 3> expected_block = {
        block_id % test.grid[0],
        (block_id / test.grid[0]) % test.grid[1],
        block_id / (test.grid[0] * test.grid[1]),
      };
      std::array<uint32_t, 3> expected_thread = {
        local_id % test.block[0],
        (local_id / test.block[0]) % test.block[1],
        local_id / (test.block[0] * test.block[1]),
      };
      for (uint32_t axis = 0; axis < 3; ++axis) {
        if (result.block_idx[axis] != expected_block[axis])
          errors = report_error(test, global_id, "wrong block index", errors);
        if (result.thread_idx[axis] != expected_thread[axis])
          errors = report_error(test, global_id, "wrong thread index", errors);
      }
      if (result.core_id != expected_core)
        errors = report_error(test, global_id, "wrong core ID", errors);
      if (result.local_group_id != expected_slot)
        errors = report_error(test, global_id, "wrong resident slot ID", errors);
      if (result.warps_per_group != warps_per_group)
        errors = report_error(test, global_id, "wrong warps-per-group", errors);
      uint32_t expected_warp =
          expected_slot * warps_per_group + local_id / num_threads;
      if (result.warp_id != expected_warp)
        errors = report_error(test, global_id, "wrong physical warp ID", errors);
      uint32_t peer_id = (local_id + block_size / 2) % block_size;
      if (result.peer_value != make_token(block_id, peer_id))
        errors = report_error(test, global_id,
                              "shared-memory/barrier value mismatch", errors);

      uint64_t address = lmem_addr(result);
      if (expected_slot == 0 && core_lmem_base[expected_core] == UINT64_MAX)
        core_lmem_base[expected_core] = address;
      if (core_lmem_base[expected_core] != UINT64_MAX) {
        uint64_t expected_address = core_lmem_base[expected_core]
                                  + expected_slot * kSharedBytesPerBlock;
        if (address != expected_address)
          errors = report_error(test, global_id,
                                "wrong block-local LMEM slice", errors);
      }
    }
  }

  if (test.require_batch_reuse) {
    for (uint32_t core = 0; core < active_cores; ++core) {
      for (uint32_t slot = 0; slot < groups_per_core; ++slot) {
        if (block_visit_count[core * groups_per_core + slot] < 2) {
          errors = report_error(test, 0, "resident slot was not reused", errors);
        }
      }
    }
  }

  cleanup_case();
  if (errors != 0) {
    std::cerr << "CASE " << test.name << " FAILED with " << errors
              << " errors" << std::endl;
    return 1;
  }
  std::cout << "CASE " << test.name << " PASSED" << std::endl;
  return 0;
}

}  // namespace

int main() {
  std::cout << "open device connection" << std::endl;
  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_LOCAL_MEM_SIZE, &local_mem_size));

  std::cout << "RESOURCE_PROFILE: threads_per_warp=" << num_threads
            << " warps_per_core=" << num_warps
            << " cores=" << num_cores
            << " local_mem_bytes=" << local_mem_size
            << " default_num_barriers=" << NUM_BARRIERS << std::endl;

  if (num_threads != NUM_THREADS || num_warps != NUM_WARPS
      || local_mem_size != (uint64_t{1} << LMEM_LOG_SIZE)) {
    std::cerr << "Compiled resource profile does not match the device"
              << std::endl;
    cleanup();
    return 1;
  }

  RT_CHECK(vx_upload_kernel_file(device, kernel_file, &krnl_buffer));

  const uint32_t capacity = num_threads * num_warps;
  std::vector<TestCase> tests;
  if (capacity >= 32)
    tests.push_back({"mapping-2d", {3, 2, 1}, {8, 4, 1}, false});
  if (capacity >= 16)
    tests.push_back({"mapping-3d", {2, 3, 2}, {4, 2, 2}, false});

  auto add_batched_case = [&](const char* name, uint32_t block_size) {
    if (block_size > capacity)
      return;
    uint32_t warps_per_group = (block_size + num_threads - 1) / num_threads;
    uint32_t groups_per_core = num_warps / warps_per_group;
    uint32_t blocks = num_cores * groups_per_core * 2 + 1;
    tests.push_back({name, {blocks, 1, 1}, {block_size, 1, 1}, true});
  };

  add_batched_case("single-warp-batched", num_threads);
  add_batched_case("one-warp-plus-one-batched", num_threads + 1);
  add_batched_case("two-warps-minus-one-batched", num_threads * 2 - 1);
  add_batched_case("two-warp-batched", num_threads * 2);
  add_batched_case("two-warps-plus-one-batched", num_threads * 2 + 1);
  add_batched_case("three-warp-batched", num_threads * 3);
  add_batched_case("four-warps-minus-one-batched", num_threads * 4 - 1);
  add_batched_case("four-warp-batched", num_threads * 4);

  int errors = 0;
  for (const auto& test : tests)
    errors += run_case(test);

  cleanup();
  if (errors != 0) {
    std::cerr << "Found " << errors << " failing cases!" << std::endl;
    std::cerr << "FAILED!" << std::endl;
    return 1;
  }

  std::cout << "PASSED!" << std::endl;
  return 0;
}
