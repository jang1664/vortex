// Reuse the production logical oracle and backend storage conversion verbatim.
#define main production_host_main
#ifdef GEMM_NAIVE
#include "../fpint_gemm_ffn_hw_naive/main.cpp"
#else
#include "../fpint_gemm_ffn_hw/main.cpp"
#endif
#undef main
#include "common.h"
#include <array>

int main(int argc, char** argv) {
  (void)argv;
  if (argc != 1) {
    std::cerr << "This directed test takes no arguments: M3 K64 N64 QCOL WTRANS0, three jobs.\n";
    return 1;
  }
  M = kLifecycleM; K = kLifecycleK; N = kLifecycleN;
  QBLK = 32; QDIR = 0; WTRANS = 0; TAGGED_VECTORS = true;
#ifndef GEMM_NAIVE
  M_pad = align_up8_u32(M); K_logical = K; N_logical = N;
#endif
  RT_CHECK(vx_dev_open(&device));
  std::vector<vx_buffer_h> allocations;
  auto upload = [&](const void* data, size_t bytes, int flags, uint64_t& address) {
    vx_buffer_h buffer = nullptr;
    RT_CHECK(vx_mem_alloc_aligned(device, bytes, 512, flags, &buffer));
    allocations.push_back(buffer);
    RT_CHECK(vx_copy_to_dev(buffer, data, 0, bytes));
    RT_CHECK(vx_mem_address(buffer, &address));
    return buffer;
  };
  lifecycle_arg_t args = {};
  args.failed_job = args.failed_index = 0xffffffffu;
  std::array<std::vector<uint16_t>, kLifecycleJobs> references;
  std::array<vx_buffer_h, kLifecycleJobs> outputs;
  std::array<size_t, kLifecycleJobs> output_sizes;
  std::vector<uint32_t> offsets(M * N);
  for (uint32_t m = 0; m < M; ++m)
    for (uint32_t n = 0; n < N; ++n) {
#ifdef GEMM_NAIVE
      offsets[m * N + n] = (m * N + n) * 2;
#else
      offsets[m * N + n] = ((n / DMA_MXU_NT) * M_pad * DMA_MXU_NT
                           + m * DMA_MXU_NT + n % DMA_MXU_NT) * 2;
#endif
    }
  upload(offsets.data(), offsets.size() * sizeof(uint32_t), VX_MEM_READ, args.output_offsets);
  std::vector<uint16_t> previous_a, previous_s;
  std::vector<int16_t> previous_z;
  std::vector<uint8_t> previous_w;
  for (uint32_t job = 0; job < kLifecycleJobs; ++job) {
    auto& arg = args.jobs[job];
    arg.M = M; arg.K = K; arg.N = N;
    arg.QBLK = QBLK; arg.QDIR = QDIR; arg.WTRANS = WTRANS;
    arg.power_kernel_iterations = 1;
    std::vector<uint16_t> a, scales;
    std::vector<int16_t> zeros;
    std::vector<uint8_t> packed_w;
#ifdef GEMM_NAIVE
    build_test_vectors(a, packed_w, scales, zeros, references[job], true, job);
    upload(a.data(), a.size() * 2, VX_MEM_READ, arg.input_base);
    upload(packed_w.data(), packed_w.size(), VX_MEM_READ, arg.weight_base);
    upload(scales.data(), scales.size() * 2, VX_MEM_READ, arg.scale_base);
    upload(zeros.data(), zeros.size() * 2, VX_MEM_READ, arg.zp_base);
    output_sizes[job] = M * N * 2;
    uint64_t local_mem_size = 0;
    RT_CHECK(vx_dev_caps(device, VX_CAPS_LOCAL_MEM_SIZE, &local_mem_size));
    if (!compute_lmem_layout(arg, local_mem_size)) return 1;
    arg.grid_dim[0] = arg.grid_dim[1] = 1;
    arg.block_dim[0] = arg.block_dim[1] = 1;
    auto& output_address = arg.output_base;
#else
    std::vector<int8_t> raw_w;
    build_test_vectors(a, raw_w, scales, zeros, references[job], true, job);
    std::vector<uint8_t> tiled_a, tiled_s, tiled_z;
    convert_input_tiled(a, tiled_a);
    convert_weight_tiled(raw_w, packed_w);
    convert_scale_tiled(scales, tiled_s);
    convert_zp_tiled(zeros, tiled_z);
    upload(tiled_a.data(), tiled_a.size(), VX_MEM_READ, arg.dram_in_base);
    upload(packed_w.data(), packed_w.size(), VX_MEM_READ, arg.dram_w_base);
    upload(tiled_s.data(), tiled_s.size(), VX_MEM_READ, arg.dram_sc_base);
    upload(tiled_z.data(), tiled_z.size(), VX_MEM_READ, arg.dram_zp_base);
    output_sizes[job] = (N / DMA_MXU_NT)
        * fpint_gemm_layout::output_slot_bytes(M, DMA_MXU_NT).reserved;
    if (!compute_tmem_layout(arg, uint64_t(TMEM_BANK_SIZE) * NUM_TMEM_BANKS)) return 1;
    auto& output_address = arg.dram_out_base;
#endif
    // Explicitly reject an accidentally repeated operand family or reference.
    if (job && (a == previous_a || packed_w == previous_w || scales == previous_s
                || zeros == previous_z || references[job] == references[job - 1])) {
      std::cerr << "Generation did not change every operand family and reference\n";
      return 1;
    }
    previous_a = a; previous_w = packed_w; previous_s = scales; previous_z = zeros;
    for (uint16_t value : references[job]) {
      if ((value & 0x7c00u) == 0x7c00u) {
        std::cerr << "Nonfinite reference\n";
        return 1;
      }
    }
    // NaN poison is guaranteed to fail the finite-reference comparator.
    std::vector<uint16_t> poison(output_sizes[job] / 2, 0x7e00u);
    outputs[job] = upload(poison.data(), output_sizes[job], VX_MEM_READ_WRITE, output_address);
    upload(references[job].data(), references[job].size() * 2, VX_MEM_READ, args.references[job]);
  }
  RT_CHECK(vx_upload_kernel_file(device, kernel_file, &krnl_buffer));
  RT_CHECK(vx_mem_alloc(device, sizeof(args), VX_MEM_READ_WRITE, &args_buffer));
  RT_CHECK(vx_copy_to_dev(args_buffer, &args, 0, sizeof(args)));
  std::cout << "LIFECYCLE_SINGLE_START jobs=3 M=3 K=64 N=64 QDIR=0 WTRANS=0\n";
  RT_CHECK(vx_start(device, krnl_buffer, args_buffer));
  RT_CHECK(vx_ready_wait(device, VX_MAX_TIMEOUT));
  RT_CHECK(vx_copy_from_dev(&args, args_buffer, 0, sizeof(args)));
  int errors = (args.completed != kLifecycleJobs || args.failed_job != 0xffffffffu);
  for (uint32_t job = 0; job < kLifecycleJobs; ++job) {
    const uint64_t start = args.start_cycles[job];
    const uint64_t verified = args.verified_cycles[job];
    std::cout << "LIFECYCLE_START job=" << job << " device_cycle=" << start << '\n';
    std::cout << "LIFECYCLE_VERIFIED job=" << job << " device_cycle=" << verified << '\n';
    if (start == 0 || verified <= start
        || (job && start <= args.verified_cycles[job - 1])) {
      std::cerr << "Invalid device lifecycle ordering at job " << job << '\n';
      ++errors;
    }
  }
  if (errors)
    std::cerr << "Device validation failed: completed=" << args.completed
              << " job=" << args.failed_job << " index=" << args.failed_index
              << " got=" << args.actual_bits << " expected=" << args.expected_bits << '\n';
  for (uint32_t job = 0; job < kLifecycleJobs; ++job) {
    std::vector<uint16_t> raw(output_sizes[job] / 2);
    RT_CHECK(vx_copy_from_dev(raw.data(), outputs[job], 0, output_sizes[job]));
    for (uint32_t i = 0; i < M * N; ++i)
      if (!compare_fp16(raw[offsets[i] / 2], references[job][i], 0.001f)) ++errors;
  }
  for (auto buffer : allocations) RT_CHECK(vx_mem_free(buffer));
  cleanup();
  if (errors) {
    std::cerr << "TEST FAILED: lifecycle errors=" << errors << '\n';
    return 1;
  }
  std::cout << "TEST PASSED: three distinct jobs, device verification before each next job, host verification of every output\n";
  return 0;
}
