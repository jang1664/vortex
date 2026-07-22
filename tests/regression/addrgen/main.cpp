#include <array>
#include <cinttypes>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <vector>

#include <addrgen_reference.h>
#include <vortex.h>

#include "common.h"

namespace {

using DescriptorCase = std::array<addrgen_descriptor_t, ADDRGEN_STREAM_COUNT>;

vx_device_h device = nullptr;
vx_buffer_h descriptor_buffer = nullptr;
vx_buffer_h output_buffer = nullptr;
vx_buffer_h kernel_buffer = nullptr;
vx_buffer_h args_buffer = nullptr;

void cleanup() {
  if (device == nullptr)
    return;
  if (descriptor_buffer != nullptr)
    vx_mem_free(descriptor_buffer);
  if (output_buffer != nullptr)
    vx_mem_free(output_buffer);
  if (kernel_buffer != nullptr)
    vx_mem_free(kernel_buffer);
  if (args_buffer != nullptr)
    vx_mem_free(args_buffer);
  vx_dev_close(device);
  device = nullptr;
}

#define RT_CHECK(expression)                                                \
  do {                                                                      \
    const int status = (expression);                                        \
    if (status != 0) {                                                      \
      std::cerr << #expression << " failed with status " << status          \
                << std::endl;                                               \
      cleanup();                                                            \
      return 1;                                                             \
    }                                                                       \
  } while (false)

addrgen_descriptor_t descriptor(
    uint64_t base,
    int64_t stride0, int64_t stride1, int64_t stride2,
    uint32_t bound0, uint32_t bound1, uint32_t bound2) {
  addrgen_descriptor_t result = {};
  result.base = base;
  result.stride[0] = stride0;
  result.stride[1] = stride1;
  result.stride[2] = stride2;
  result.bound[0] = bound0;
  result.bound[1] = bound1;
  result.bound[2] = bound2;
  return result;
}

uint64_t next_random(uint64_t* state) {
  uint64_t value = *state;
  value ^= value >> 12;
  value ^= value << 25;
  value ^= value >> 27;
  *state = value;
  return value * UINT64_C(0x2545f4914f6cdd1d);
}

std::vector<DescriptorCase> make_cases() {
  std::vector<DescriptorCase> cases;
  cases.push_back({{
      descriptor(UINT64_C(0x1000), 8, 0, 0, 5, 1, 1),
      descriptor(UINT64_C(0x2000), -4, 0, 0, 4, 1, 1),
      descriptor(UINT64_C(0x3000), 0, 0, 0, 3, 1, 1),
  }});
  cases.push_back({{
      descriptor(UINT64_C(0x4000), 2, 64, 0, 3, 2, 1),
      descriptor(UINT64_C(0x5000), -2, 48, 0, 2, 3, 1),
      descriptor(UINT64_C(0x6000), 16, -128, 0, 4, 2, 1),
  }});
  cases.push_back({{
      descriptor(UINT64_C(0x7000), 1, 32, 512, 2, 3, 2),
      descriptor(UINT64_C(0x8000), -3, 0, 257, 3, 2, 2),
      descriptor(UINT64_C(0x9000), 5, -40, -1024, 2, 2, 3),
  }});
  cases.push_back({{
      descriptor(UINT64_C(0xa000), 7, 11, 13, 1, 1, 1),
      descriptor(UINT64_C(0xb000), 0, 0, 0, 1, 1, 1),
      descriptor(UINT64_C(0xc000), -1, -1, -1, 1, 1, 1),
  }});
  cases.push_back({{
      descriptor(UINT64_C(0xd000), 1, 2, 3, 0, 1, 1),
      descriptor(UINT64_C(0xe000), 1, 2, 3, 1, 0, 1),
      descriptor(UINT64_C(0xf000), 1, 2, 3, 1, 1, 0),
  }});
  cases.push_back({{
      descriptor(UINT64_C(0xfffffffffffffff8), 8, 32, 0, 4, 2, 1),
      descriptor(UINT64_C(0x4), -8, -64, 0, 3, 2, 1),
      descriptor(UINT64_C(0xfffffffffffffff0), 24, -48, 96, 2, 2, 2),
  }});
  cases.push_back({{
      descriptor(UINT64_C(0x123456789abcdef0),
                 std::numeric_limits<int64_t>::max(),
                 std::numeric_limits<int64_t>::min(), 0, 2, 2, 1),
      descriptor(UINT64_C(0xfedcba9876543210),
                 std::numeric_limits<int64_t>::min(), -1,
                 std::numeric_limits<int64_t>::max(), 2, 2, 2),
      descriptor(UINT64_C(0),
                 std::numeric_limits<int64_t>::max(), 0,
                 std::numeric_limits<int64_t>::min(), 3, 1, 2),
  }});

  uint64_t random_state = UINT64_C(0x6a09e667f3bcc909);
  for (uint32_t case_index = 0; case_index < 32; ++case_index) {
    DescriptorCase random_case = {};
    for (uint32_t stream = 0; stream < ADDRGEN_STREAM_COUNT; ++stream) {
      auto& item = random_case[stream];
      item.base = next_random(&random_state);
      for (uint32_t dim = 0; dim < 3; ++dim) {
        const uint64_t random_stride = next_random(&random_state);
        item.stride[dim] = ((case_index + stream + dim) % 7 == 0)
                         ? 0
                         : static_cast<int64_t>(random_stride);
        item.bound[dim] = 1 + (next_random(&random_state) % 3);
      }
    }
    cases.push_back(random_case);
  }
  return cases;
}

vortex::test::AddrGenDescriptor reference_descriptor(
    const addrgen_descriptor_t& descriptor) {
  vortex::test::AddrGenDescriptor result;
  result.base = descriptor.base;
  for (uint32_t dim = 0; dim < 3; ++dim) {
    result.stride[dim] = descriptor.stride[dim];
    result.bound[dim] = descriptor.bound[dim];
  }
  return result;
}

std::vector<uint64_t> generate_expected(
    const std::vector<DescriptorCase>& cases) {
  std::vector<uint64_t> expected;
  for (const auto& descriptor_case : cases) {
    std::array<std::vector<uint64_t>, ADDRGEN_STREAM_COUNT> streams;
    for (uint32_t stream = 0; stream < ADDRGEN_STREAM_COUNT; ++stream) {
      vortex::test::AddrGenReferenceIterator iterator(
          reference_descriptor(descriptor_case[stream]));
      uint64_t address = 0;
      while (iterator.next(&address))
        streams[stream].push_back(address);
    }

    std::array<size_t, ADDRGEN_STREAM_COUNT> positions = {{0, 0, 0}};
    bool pending = true;
    while (pending) {
      pending = false;
      for (uint32_t stream = 0; stream < ADDRGEN_STREAM_COUNT; ++stream) {
        if (positions[stream] < streams[stream].size()) {
          expected.push_back(streams[stream][positions[stream]++]);
          pending = true;
        }
      }
    }
  }
  return expected;
}

}  // namespace

int main() {
  const auto cases = make_cases();
  const auto expected = generate_expected(cases);
  std::vector<addrgen_descriptor_t> flat_descriptors;
  flat_descriptors.reserve(cases.size() * ADDRGEN_STREAM_COUNT);
  for (const auto& descriptor_case : cases) {
    for (const auto& item : descriptor_case)
      flat_descriptors.push_back(item);
  }

  const uint64_t descriptor_bytes =
      flat_descriptors.size() * sizeof(addrgen_descriptor_t);
  const uint64_t output_words = expected.size() + 1;
  const uint64_t output_bytes = output_words * sizeof(uint64_t);

  RT_CHECK(vx_dev_open(&device));
  RT_CHECK(vx_mem_alloc(device, descriptor_bytes, VX_MEM_READ,
                        &descriptor_buffer));
  RT_CHECK(vx_mem_alloc(device, output_bytes, VX_MEM_WRITE, &output_buffer));
  RT_CHECK(vx_copy_to_dev(descriptor_buffer, flat_descriptors.data(), 0,
                          descriptor_bytes));

  kernel_arg_t kernel_arg = {};
  kernel_arg.num_cases = cases.size();
  RT_CHECK(vx_mem_address(descriptor_buffer, &kernel_arg.descriptors_addr));
  RT_CHECK(vx_mem_address(output_buffer, &kernel_arg.output_addr));
  RT_CHECK(vx_upload_kernel_file(device, "kernel.vxbin", &kernel_buffer));
  RT_CHECK(vx_upload_bytes(device, &kernel_arg, sizeof(kernel_arg),
                           &args_buffer));
  RT_CHECK(vx_start(device, kernel_buffer, args_buffer));
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));

  std::vector<uint64_t> actual(output_words, 0);
  RT_CHECK(vx_copy_from_dev(actual.data(), output_buffer, 0, output_bytes));

  uint32_t errors = 0;
  if (actual[0] != expected.size()) {
    std::cerr << "address count mismatch: actual=" << actual[0]
              << ", expected=" << expected.size() << std::endl;
    ++errors;
  }
  const size_t comparable = actual[0] < expected.size()
                          ? static_cast<size_t>(actual[0])
                          : expected.size();
  for (size_t index = 0; index < comparable; ++index) {
    if (actual[index + 1] != expected[index]) {
      if (errors < 20) {
        std::cerr << "address mismatch at " << index
                  << ": actual=0x" << std::hex << actual[index + 1]
                  << ", expected=0x" << expected[index] << std::dec
                  << std::endl;
      }
      ++errors;
    }
  }

  cleanup();
  if (errors != 0) {
    std::cerr << "FAILED: " << errors << " address-generator mismatches"
              << std::endl;
    return 1;
  }

  std::cout << "PASSED: " << cases.size() << " descriptor sets, "
            << expected.size() << " interleaved addresses" << std::endl;
  return 0;
}
