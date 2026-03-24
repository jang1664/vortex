#include <assert.h>
#include <iostream>
#include <string.h>
#include <unistd.h>
#include <vector>
#include <vortex.h>
#include "common.h"

#define RT_CHECK(_expr)                                         \
  do {                                                          \
    int _ret = _expr;                                           \
    if (0 == _ret)                                              \
      break;                                                    \
    printf("Error: '%s' returned %d!\n", #_expr, (int)_ret);    \
    cleanup();                                                  \
    exit(-1);                                                   \
  } while (false)

const char* kernel_file = "kernel.vxbin";
uint32_t count = 0;

vx_device_h device = nullptr;
vx_buffer_h addr_buffer = nullptr;
vx_buffer_h src_buffer = nullptr;
vx_buffer_h dst_buffer = nullptr;
vx_buffer_h krnl_buffer = nullptr;
vx_buffer_h args_buffer = nullptr;
kernel_arg_t kernel_arg = {};

static inline uint32_t rotl32(uint32_t value, uint32_t shift) {
  return (value << shift) | (value >> (32 - shift));
}

static uint32_t ref_value(const std::vector<uint32_t>& h_addr,
                          const std::vector<uint32_t>& h_src,
                          uint32_t out_idx) {
  uint32_t acc = 0x9e3779b9u ^ out_idx;
  for (uint32_t j = 0; j < NUM_GATHERS; ++j) {
    uint32_t addr_idx = out_idx * NUM_GATHERS + j;
    uint32_t src_idx = h_addr[addr_idx];
    uint32_t value = h_src[src_idx];
    acc = rotl32(acc ^ (value + 0x7f4a7c15u + j), 5) + (value ^ (j * 0x45d9f3bu));
  }
  uint32_t echo = acc;
  uint32_t tail_idx = h_addr[out_idx * NUM_GATHERS + (NUM_GATHERS - 1)];
  uint32_t tail = h_src[tail_idx];
  return rotl32(echo, 7) ^ tail ^ (out_idx * 0x27d4eb2du);
}

static void show_usage() {
  std::cout << "Usage: [-k kernel] [-n work-per-thread] [-h]" << std::endl;
}

static void parse_args(int argc, char** argv) {
  int c;
  while ((c = getopt(argc, argv, "n:k:h")) != -1) {
    switch (c) {
    case 'n':
      count = atoi(optarg);
      break;
    case 'k':
      kernel_file = optarg;
      break;
    case 'h':
      show_usage();
      exit(0);
    default:
      show_usage();
      exit(-1);
    }
  }
}

static void cleanup() {
  if (device) {
    vx_mem_free(addr_buffer);
    vx_mem_free(src_buffer);
    vx_mem_free(dst_buffer);
    vx_mem_free(krnl_buffer);
    vx_mem_free(args_buffer);
    vx_dev_close(device);
  }
}

int main(int argc, char* argv[]) {
  parse_args(argc, argv);

  if (count == 0) {
    count = 256;
  }

  std::srand(50);

  RT_CHECK(vx_dev_open(&device));

  uint64_t num_cores, num_warps, num_threads;
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_CORES, &num_cores));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_WARPS, &num_warps));
  RT_CHECK(vx_dev_caps(device, VX_CAPS_NUM_THREADS, &num_threads));

  uint32_t total_threads = num_cores * num_warps * num_threads;
  uint32_t num_points = count * total_threads;
  uint32_t src_span = count * 4;
  uint32_t num_src_points = total_threads * src_span;
  uint32_t num_addrs = num_points * NUM_GATHERS;

  uint32_t addr_buf_size = num_addrs * sizeof(uint32_t);
  uint32_t src_buf_size  = num_src_points * sizeof(uint32_t);
  uint32_t dst_buf_size  = num_points * sizeof(uint32_t);

  kernel_arg.num_tasks = total_threads;
  kernel_arg.stride = count;

  RT_CHECK(vx_mem_alloc(device, addr_buf_size, VX_MEM_READ, &addr_buffer));
  RT_CHECK(vx_mem_address(addr_buffer, &kernel_arg.addr_addr));
  RT_CHECK(vx_mem_alloc(device, src_buf_size, VX_MEM_READ, &src_buffer));
  RT_CHECK(vx_mem_address(src_buffer, &kernel_arg.src_addr));
  RT_CHECK(vx_mem_alloc(device, dst_buf_size, VX_MEM_WRITE, &dst_buffer));
  RT_CHECK(vx_mem_address(dst_buffer, &kernel_arg.dst_addr));

  std::vector<uint32_t> h_addr(num_addrs);
  std::vector<uint32_t> h_src(num_src_points);
  std::vector<uint32_t> h_dst(num_points, 0);

  for (uint32_t i = 0; i < num_src_points; ++i) {
    uint32_t x = std::rand();
    h_src[i] = (x << 1) ^ (0x9e3779b9u + i * 17);
  }

  for (uint32_t task = 0; task < total_threads; ++task) {
    uint32_t addr_base = task * count * NUM_GATHERS;
    for (uint32_t i = 0; i < count * NUM_GATHERS; ++i) {
      uint32_t slot = std::rand() % src_span;
      h_addr[addr_base + i] = slot * total_threads + task;
    }
  }

  RT_CHECK(vx_copy_to_dev(addr_buffer, h_addr.data(), 0, addr_buf_size));
  RT_CHECK(vx_copy_to_dev(src_buffer, h_src.data(), 0, src_buf_size));
  RT_CHECK(vx_upload_kernel_file(device, kernel_file, &krnl_buffer));
  RT_CHECK(vx_upload_bytes(device, &kernel_arg, sizeof(kernel_arg_t), &args_buffer));
  RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
  RT_CHECK(vx_copy_from_dev(h_dst.data(), dst_buffer, 0, dst_buf_size));

  int errors = 0;
  for (uint32_t i = 0; i < num_points; ++i) {
    uint32_t ref = ref_value(h_addr, h_src, i);
    if (h_dst[i] != ref) {
      std::cout << "error at result #" << i
                << ": actual=0x" << std::hex << h_dst[i]
                << ", expected=0x" << ref << std::dec << std::endl;
      ++errors;
      if (errors > 20)
        break;
    }
  }

  cleanup();

  if (errors != 0) {
    std::cout << "Found " << errors << " errors!" << std::endl;
    std::cout << "FAILED!" << std::endl;
    return 1;
  }

  std::cout << "PASSED!" << std::endl;
  return 0;
}
