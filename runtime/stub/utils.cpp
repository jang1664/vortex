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

#include <iostream>
#include <fstream>
#include <list>
#include <cstring>
#include <vector>
#include <unordered_map>
#include <vortex.h>
#include <assert.h>

class ProfilingMode {
public:
  ProfilingMode() : perf_class_(0) {
    auto profiling_s = getenv("VORTEX_PROFILING");
    if (profiling_s) {
      perf_class_ = std::atoi(profiling_s);
    }
  }

  ~ProfilingMode() {}

  int perf_class() const {
    return perf_class_;
  }

private:
  int perf_class_;
};

int get_profiling_mode() {
  static ProfilingMode gProfilingMode;
  return gProfilingMode.perf_class();
}

extern int vx_upload_kernel_bytes(vx_device_h hdevice, const void* content, uint64_t size, vx_buffer_h* hbuffer) {
  if (nullptr == hdevice || nullptr == content || size <= 8 || nullptr == hbuffer)
    return -1;

  auto bytes = reinterpret_cast<const uint64_t*>(content);

  auto min_vma = *bytes++;
  auto max_vma = *bytes++;
  auto bin_size = size - 2 * 8;
  auto runtime_size = (max_vma - min_vma);

  vx_buffer_h _hbuffer;
  CHECK_ERR(vx_mem_reserve(hdevice, min_vma, runtime_size, 0, &_hbuffer), {
    return err;
  });

  // mask binary region as read-only
  CHECK_ERR(vx_mem_access(_hbuffer, 0, bin_size, VX_MEM_READ), {
    vx_mem_free(_hbuffer);
    return err;
  });

  // mark global variables region as read-write
  CHECK_ERR(vx_mem_access(_hbuffer, bin_size, runtime_size - bin_size, VX_MEM_READ_WRITE), {
    vx_mem_free(_hbuffer);
    return err;
  });

  CHECK_ERR(vx_copy_to_dev(_hbuffer, bytes, 0, bin_size), {
    vx_mem_free(_hbuffer);
    return err;
  });

  *hbuffer = _hbuffer;

  return 0;
}

extern int vx_upload_kernel_file(vx_device_h hdevice, const char* filename, vx_buffer_h* hbuffer) {
  if (nullptr == hdevice || nullptr == filename || nullptr == hbuffer)
    return -1;

  std::ifstream ifs(filename);
  if (!ifs) {
    std::cerr << "Error: " << filename << " not found" << std::endl;
    return -1;
  }

  // read file content
  ifs.seekg(0, ifs.end);
  auto size = ifs.tellg();
  std::vector<char> content(size);
  ifs.seekg(0, ifs.beg);
  ifs.read(content.data(), size);

  // upload buffer
  CHECK_ERR(vx_upload_kernel_bytes(hdevice, content.data(), size, hbuffer), {
    return err;
  });

  return 0;
}

extern int vx_upload_bytes(vx_device_h hdevice, const void* content, uint64_t size, vx_buffer_h* hbuffer) {
  if (nullptr == hdevice || nullptr == content || 0 == size || nullptr == hbuffer)
    return -1;

  vx_buffer_h _hbuffer;

  CHECK_ERR(vx_mem_alloc(hdevice, size, VX_MEM_READ, &_hbuffer), {
    return err;
  });

  CHECK_ERR(vx_copy_to_dev(_hbuffer, content, 0, size), {
    vx_mem_free(_hbuffer);
    return err;
  });

  *hbuffer = _hbuffer;

  return 0;
}

extern int vx_upload_file(vx_device_h hdevice, const char* filename, vx_buffer_h* hbuffer) {
  if (nullptr == hdevice || nullptr == filename || nullptr == hbuffer)
    return -1;

  std::ifstream ifs(filename);
  if (!ifs) {
    std::cerr << "Error: " << filename << " not found" << std::endl;
    return -1;
  }

  // read file content
  ifs.seekg(0, ifs.end);
  auto size = ifs.tellg();
  std::vector<char> content(size);
  ifs.seekg(0, ifs.beg);
  ifs.read(content.data(), size);

  // upload buffer
  CHECK_ERR(vx_upload_bytes(hdevice, content.data(), size, hbuffer), {
    return err;
  });

  return 0;
}

///////////////////////////////////////////////////////////////////////////////

extern int vx_dump_perf(vx_device_h hdevice, FILE* stream) {
  uint64_t total_instrs = 0;
  uint64_t total_cycles = 0;
  uint64_t max_cycles = 0;

  auto calcRatio = [&](uint64_t part, uint64_t total)->int {
    if (total == 0)
      return 0;
    return int((1.0 - (double(part) / double(total))) * 100);
  };

  auto caclAverage = [&](uint64_t part, uint64_t total)->double {
    if (total == 0)
      return 0;
    return double(part) / double(total);
  };

  auto calcAvgPercent = [&](uint64_t part, uint64_t total)->int {
    return int(caclAverage(part, total) * 100);
  };

  // PERF: pipeline stalls
  uint64_t sched_idles = 0;
  uint64_t sched_stalls = 0;
  uint64_t ibuffer_stalls = 0;
  uint64_t scrb_stalls = 0;
  uint64_t opds_stalls = 0;
  uint64_t scrb_alu = 0;
  uint64_t scrb_fpu = 0;
  uint64_t scrb_lsu = 0;
  uint64_t scrb_vpu = 0;
  uint64_t scrb_tcu = 0;
  uint64_t scrb_csrs = 0;
  uint64_t scrb_wctl = 0;
  uint64_t ifetches = 0;
  uint64_t loads = 0;
  uint64_t stores = 0;
  uint64_t ifetch_lat = 0;
  uint64_t load_lat   = 0;
  // PERF: l2cache
  uint64_t l2cache_reads = 0;
  uint64_t l2cache_writes = 0;
  uint64_t l2cache_read_misses = 0;
  uint64_t l2cache_write_misses = 0;
  uint64_t l2cache_bank_stalls = 0;
  uint64_t l2cache_mshr_stalls = 0;
  // PERF: l3cache
  uint64_t l3cache_reads = 0;
  uint64_t l3cache_writes = 0;
  uint64_t l3cache_read_misses = 0;
  uint64_t l3cache_write_misses = 0;
  uint64_t l3cache_bank_stalls = 0;
  uint64_t l3cache_mshr_stalls = 0;
  // PERF: memory
  uint64_t mem_reads = 0;
  uint64_t mem_writes = 0;
  uint64_t mem_lat = 0;
  uint64_t mem_bank_stalls = 0;
  // PERF: accelerator — GEMM unit
  uint64_t gemm_compute_cycles = 0;
  uint64_t gemm_stall_cycles = 0;
  uint64_t gemm_job_count = 0;
  uint64_t mxu_input_fire = 0, mxu_input_stall = 0;
  uint64_t mxu_weight_fire = 0, mxu_weight_stall = 0;
  uint64_t mxu_psum_fire = 0, mxu_psum_stall = 0;
  uint64_t mxu_output_fire = 0, mxu_output_stall = 0;
  uint64_t mxu_mac_count = 0;
  // PERF: accelerator — GEMM node
  uint64_t gemm_total_cycles = 0;
  uint64_t lmem_rd_bytes = 0;
  uint64_t lmem_wr_bytes = 0;
  // PERF: accelerator — DMA
  uint64_t dma_rd_bytes = 0;
  uint64_t dma_wr_bytes = 0;
  uint64_t dma_xfer_count = 0;
  uint64_t dma_active_cycles = 0;
  uint64_t dma_wait_dcache = 0;
  uint64_t dma_wait_lmem = 0;
  uint64_t dma_src_rd_req_fire = 0, dma_src_rd_req_stall = 0;
  uint64_t dma_src_rd_data_fire = 0, dma_src_rd_data_stall = 0;
  uint64_t dma_dst_wr_fire = 0, dma_dst_wr_stall = 0;
  // PERF: accelerator — overlap
  uint64_t overlap_dma_mxu = 0;

  uint64_t num_cores;
  CHECK_ERR(vx_dev_caps(hdevice, VX_CAPS_NUM_CORES, &num_cores), {
    return err;
  });

  uint64_t isa_flags;
  CHECK_ERR(vx_dev_caps(hdevice, VX_CAPS_ISA_FLAGS, &isa_flags), {
    return err;
  });

  uint64_t num_mem_bank_ports;
  CHECK_ERR(vx_dev_caps(hdevice, VX_CAPS_NUM_MEM_BANKS, &num_mem_bank_ports), {
    return err;
  });

  bool icache_enable  = isa_flags & VX_ISA_EXT_ICACHE;
  bool dcache_enable  = isa_flags & VX_ISA_EXT_DCACHE;
  bool l2cache_enable = isa_flags & VX_ISA_EXT_L2CACHE;
  bool l3cache_enable = isa_flags & VX_ISA_EXT_L3CACHE;
  bool lmem_enable    = isa_flags & VX_ISA_EXT_LMEM;
  bool fpu_enable     = isa_flags & VX_ISA_STD_F;
  bool vpu_enable     = isa_flags & VX_ISA_STD_V;
  bool tcu_enable     = isa_flags & VX_ISA_EXT_TCU;

  auto perf_class = get_profiling_mode();

  for (unsigned core_id = 0; core_id < num_cores; ++core_id) {
    uint64_t cycles_per_core;
    CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MCYCLE, core_id, &cycles_per_core), {
      return err;
    });

    uint64_t instrs_per_core;
    CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MINSTRET, core_id, &instrs_per_core), {
      return err;
    });

    switch (perf_class) {
    case VX_DCR_MPM_CLASS_CORE: {
      // PERF: pipeline
      // scheduler idles
      {
        uint64_t sched_idles_per_core;
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_SCHED_ID, core_id, &sched_idles_per_core), {
          return err;
        });
        if (num_cores > 1) {
          int idles_percent_per_core = calcAvgPercent(sched_idles_per_core, cycles_per_core);
          fprintf(stream, "PERF: core%d: scheduler idle=%ld (%d%%)\n", core_id, sched_idles_per_core, idles_percent_per_core);
        }
        sched_idles += sched_idles_per_core;
      }
      // scheduler stalls
      {
        uint64_t sched_stalls_per_core;
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_SCHED_ST, core_id, &sched_stalls_per_core), {
          return err;
        });
        if (num_cores > 1) {
          int stalls_percent_per_core = calcAvgPercent(sched_stalls_per_core, cycles_per_core);
          fprintf(stream, "PERF: core%d: scheduler stalls=%ld (%d%%)\n", core_id, sched_stalls_per_core, stalls_percent_per_core);
        }
        sched_stalls += sched_stalls_per_core;
      }
      // ibuffer stalls
      {
        uint64_t ibuffer_stalls_per_core;
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_IBUF_ST, core_id, &ibuffer_stalls_per_core), {
          return err;
        });
        if (num_cores > 1) {
          int ibuffer_percent_per_core = calcAvgPercent(ibuffer_stalls_per_core, cycles_per_core);
          fprintf(stream, "PERF: core%d: ibuffer stalls=%ld (%d%%)\n", core_id, ibuffer_stalls_per_core, ibuffer_percent_per_core);
        }
        ibuffer_stalls += ibuffer_stalls_per_core;
      }
      // scoreboard stalls
      {
        uint64_t scrb_stalls_per_core;
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_SCRB_ST, core_id, &scrb_stalls_per_core), {
          return err;
        });
        uint64_t scrb_alu_per_core;
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_SCRB_ALU, core_id, &scrb_alu_per_core), {
          return err;
        });
        uint64_t scrb_fpu_per_core;
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_SCRB_FPU, core_id, &scrb_fpu_per_core), {
          return err;
        });
        uint64_t scrb_lsu_per_core;
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_SCRB_LSU, core_id, &scrb_lsu_per_core), {
          return err;
        });
        uint64_t scrb_vpu_per_core;
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_SCRB_VPU, core_id, &scrb_vpu_per_core), {
          return err;
        });
        uint64_t scrb_tcu_per_core;
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_SCRB_TCU, core_id, &scrb_tcu_per_core), {
          return err;
        });
        uint64_t scrb_csrs_per_core;
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_SCRB_CSRS, core_id, &scrb_csrs_per_core), {
          return err;
        });
        uint64_t scrb_wctl_per_core;
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_SCRB_WCTL, core_id, &scrb_wctl_per_core), {
          return err;
        });
        scrb_alu += scrb_alu_per_core;
        scrb_fpu += scrb_fpu_per_core;
        scrb_lsu += scrb_lsu_per_core;
        scrb_vpu += scrb_vpu_per_core;
        scrb_tcu += scrb_tcu_per_core;
        scrb_csrs += scrb_csrs_per_core;
        scrb_wctl += scrb_wctl_per_core;
        if (num_cores > 1) {
          uint64_t scrb_total = scrb_alu_per_core + scrb_lsu_per_core + scrb_csrs_per_core + scrb_wctl_per_core;
          if (fpu_enable) {
            scrb_total += scrb_fpu_per_core;
          }
          if (vpu_enable) {
            scrb_total += scrb_vpu_per_core;
          }
          if (tcu_enable) {
            scrb_total += scrb_tcu_per_core;
          }
          int scrb_percent_per_core = calcAvgPercent(scrb_stalls_per_core, cycles_per_core);
          fprintf(stream, "PERF: core%d: scoreboard stalls=%ld (%d%%) (alu=%d%%, lsu=%d%%, csrs=%d%%, wctl=%d%%"
            , core_id
            , scrb_stalls_per_core
            , scrb_percent_per_core
            , calcAvgPercent(scrb_alu_per_core, scrb_total)
            , calcAvgPercent(scrb_lsu_per_core, scrb_total)
            , calcAvgPercent(scrb_csrs_per_core, scrb_total)
            , calcAvgPercent(scrb_wctl_per_core, scrb_total)
          );
          if (fpu_enable) {
            fprintf(stream, ", fpu=%d%%", calcAvgPercent(scrb_fpu_per_core, scrb_total));
          }
          if (vpu_enable) {
            fprintf(stream, ", vpu=%d%%", calcAvgPercent(scrb_vpu_per_core, scrb_total));
          }
          if (tcu_enable) {
            fprintf(stream, ", tcu=%d%%", calcAvgPercent(scrb_tcu_per_core, scrb_total));
          }
          fprintf(stream, ")\n");
        }
        scrb_stalls += scrb_stalls_per_core;
      }
      // operands stalls
      {
        uint64_t opds_stalls_per_core;
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_OPDS_ST, core_id, &opds_stalls_per_core), {
          return err;
        });
        if (num_cores > 1) {
          int opds_percent_per_core = calcAvgPercent(opds_stalls_per_core, cycles_per_core);
          fprintf(stream, "PERF: core%d: operands stalls=%ld (%d%%)\n", core_id, opds_stalls_per_core, opds_percent_per_core);
        }
        opds_stalls += opds_stalls_per_core;
      }
      // PERF: memory
      // ifetches
      {
        uint64_t ifetches_per_core;
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_IFETCHES, core_id, &ifetches_per_core), {
          return err;
        });
        if (num_cores > 1) fprintf(stream, "PERF: core%d: ifetches=%ld\n", core_id, ifetches_per_core);
        ifetches += ifetches_per_core;

        uint64_t ifetch_lat_per_core;
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_IFETCH_LT, core_id, &ifetch_lat_per_core), {
          return err;
        });
        if (num_cores > 1) {
          int mem_avg_lat = caclAverage(ifetch_lat_per_core, ifetches_per_core);
          fprintf(stream, "PERF: core%d: ifetch latency=%d cycles\n", core_id, mem_avg_lat);
        }
        ifetch_lat += ifetch_lat_per_core;
      }
      // loads
      {
        uint64_t loads_per_core;
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_LOADS, core_id, &loads_per_core), {
          return err;
        });
        if (num_cores > 1) fprintf(stream, "PERF: core%d: loads=%ld\n", core_id, loads_per_core);
        loads += loads_per_core;

        uint64_t load_lat_per_core;
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_LOAD_LT, core_id, &load_lat_per_core), {
          return err;
        });
        if (num_cores > 1) {
          int mem_avg_lat = caclAverage(load_lat_per_core, loads_per_core);
          fprintf(stream, "PERF: core%d: load latency=%d cycles\n", core_id, mem_avg_lat);
        }
        load_lat += load_lat_per_core;
      }
      // stores
      {
        uint64_t stores_per_core;
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_STORES, core_id, &stores_per_core), {
          return err;
        });
        if (num_cores > 1) fprintf(stream, "PERF: core%d: stores=%ld\n", core_id, stores_per_core);
        stores += stores_per_core;
      }
    } break;
    case VX_DCR_MPM_CLASS_MEM: {
      if (lmem_enable) {
        // PERF: lmem
        uint64_t lmem_reads;
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_LMEM_READS, core_id, &lmem_reads), {
          return err;
        });
        uint64_t lmem_writes;
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_LMEM_WRITES, core_id, &lmem_writes), {
          return err;
        });
        uint64_t lmem_bank_stalls;
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_LMEM_BANK_ST, core_id, &lmem_bank_stalls), {
          return err;
        });
        int lmem_bank_utilization = calcAvgPercent(lmem_reads + lmem_writes, lmem_reads + lmem_writes + lmem_bank_stalls);
        fprintf(stream, "PERF: core%d: lmem reads=%ld\n", core_id, lmem_reads);
        fprintf(stream, "PERF: core%d: lmem writes=%ld\n", core_id, lmem_writes);
        fprintf(stream, "PERF: core%d: lmem bank stalls=%ld (utilization=%d%%)\n", core_id, lmem_bank_stalls, lmem_bank_utilization);
      }

      if (icache_enable) {
        // PERF: Icache
        uint64_t icache_reads;
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_ICACHE_READS, core_id, &icache_reads), {
          return err;
        });
        uint64_t icache_read_misses;
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_ICACHE_MISS_R, core_id, &icache_read_misses), {
          return err;
        });
        uint64_t icache_mshr_stalls;
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_ICACHE_MSHR_ST, core_id, &icache_mshr_stalls), {
          return err;
        });
        int icache_read_hit_ratio = calcRatio(icache_read_misses, icache_reads);
        int mshr_utilization = calcAvgPercent(icache_read_misses, icache_read_misses + icache_mshr_stalls);
        fprintf(stream, "PERF: core%d: icache reads=%ld\n", core_id, icache_reads);
        fprintf(stream, "PERF: core%d: icache read misses=%ld (hit ratio=%d%%)\n", core_id, icache_read_misses, icache_read_hit_ratio);
        fprintf(stream, "PERF: core%d: icache mshr stalls=%ld (utilization=%d%%)\n", core_id, icache_mshr_stalls, mshr_utilization);
      }

      uint64_t dcache_requests_per_core = 0;

      if (dcache_enable) {
        // PERF: Dcache
        uint64_t dcache_reads;
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_DCACHE_READS, core_id, &dcache_reads), {
          return err;
        });
        uint64_t dcache_writes;
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_DCACHE_WRITES, core_id, &dcache_writes), {
          return err;
        });
        dcache_requests_per_core += dcache_reads + dcache_writes;
        uint64_t dcache_read_misses;
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_DCACHE_MISS_R, core_id, &dcache_read_misses), {
          return err;
        });
        uint64_t dcache_write_misses;
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_DCACHE_MISS_W, core_id, &dcache_write_misses), {
          return err;
        });
        uint64_t dcache_bank_stalls;
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_DCACHE_BANK_ST, core_id, &dcache_bank_stalls), {
          return err;
        });
        uint64_t dcache_mshr_stalls;
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_DCACHE_MSHR_ST, core_id, &dcache_mshr_stalls), {
          return err;
        });
        int dcache_read_hit_ratio = calcRatio(dcache_read_misses, dcache_reads);
        int dcache_write_hit_ratio = calcRatio(dcache_write_misses, dcache_writes);
        int dcache_bank_utilization = calcAvgPercent(dcache_reads + dcache_writes, dcache_reads + dcache_writes + dcache_bank_stalls);
        int mshr_utilization = calcAvgPercent(dcache_read_misses + dcache_write_misses, dcache_read_misses + dcache_write_misses + dcache_mshr_stalls);
        fprintf(stream, "PERF: core%d: dcache reads=%ld\n", core_id, dcache_reads);
        fprintf(stream, "PERF: core%d: dcache writes=%ld\n", core_id, dcache_writes);
        fprintf(stream, "PERF: core%d: dcache read misses=%ld (hit ratio=%d%%)\n", core_id, dcache_read_misses, dcache_read_hit_ratio);
        fprintf(stream, "PERF: core%d: dcache write misses=%ld (hit ratio=%d%%)\n", core_id, dcache_write_misses, dcache_write_hit_ratio);
        fprintf(stream, "PERF: core%d: dcache bank stalls=%ld (utilization=%d%%)\n", core_id, dcache_bank_stalls, dcache_bank_utilization);
        fprintf(stream, "PERF: core%d: dcache mshr stalls=%ld (utilization=%d%%)\n", core_id, dcache_mshr_stalls, mshr_utilization);
      }

      // PERF: coalescer
      uint64_t coalescer_misses;
      CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_COALESCER_MISS, core_id, &coalescer_misses), {
        return err;
      });
      int coalescer_utilization = calcAvgPercent(dcache_requests_per_core - coalescer_misses, dcache_requests_per_core);
      fprintf(stream, "PERF: core%d: coalescer misses=%ld (hit ratio=%d%%)\n", core_id, coalescer_misses, coalescer_utilization);

      if (l2cache_enable) {
        // PERF: L2cache
        uint64_t tmp;
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_L2CACHE_READS, core_id, &tmp), {
          return err;
        });
        l2cache_reads += tmp;

        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_L2CACHE_WRITES, core_id, &tmp), {
          return err;
        });
        l2cache_writes += tmp;

        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_L2CACHE_MISS_R, core_id, &tmp), {
          return err;
        });
        l2cache_read_misses += tmp;

        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_L2CACHE_MISS_W, core_id, &tmp), {
          return err;
        });
        l2cache_write_misses += tmp;

        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_L2CACHE_BANK_ST, core_id, &tmp), {
          return err;
        });
        l2cache_bank_stalls += tmp;

        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_L2CACHE_MSHR_ST, core_id, &tmp), {
          return err;
        });
        l2cache_mshr_stalls += tmp;
      }
      if (0 == core_id) {
        if (l3cache_enable) {
          // PERF: L3cache
          CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_L3CACHE_READS, core_id, &l3cache_reads), {
            return err;
          });
          CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_L3CACHE_WRITES, core_id, &l3cache_writes), {
            return err;
          });
          CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_L3CACHE_MISS_R, core_id, &l3cache_read_misses), {
            return err;
          });
          CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_L3CACHE_MISS_W, core_id, &l3cache_write_misses), {
            return err;
          });
          CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_L3CACHE_BANK_ST, core_id, &l3cache_bank_stalls), {
            return err;
          });
          CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_L3CACHE_MSHR_ST, core_id, &l3cache_mshr_stalls), {
            return err;
          });
        }
        // PERF: memory
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_MEM_READS, core_id, &mem_reads), {
          return err;
        });
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_MEM_WRITES, core_id, &mem_writes), {
          return err;
        });
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_MEM_LT, core_id, &mem_lat), {
          return err;
        });
        CHECK_ERR(vx_mpm_query(hdevice, VX_CSR_MPM_MEM_BANK_ST, core_id, &mem_bank_stalls), {
          return err;
        });
      }
    } break;
    case VX_DCR_MPM_CLASS_ACCEL: {
      #define READ_PERF(csr, accum) do { \
        uint64_t _v; \
        CHECK_ERR(vx_mpm_query(hdevice, csr, core_id, &_v), { return err; }); \
        accum += _v; \
      } while(0)
      // GEMM unit
      READ_PERF(VX_CSR_MPM_GEMM_COMPUTE_CYC, gemm_compute_cycles);
      READ_PERF(VX_CSR_MPM_GEMM_STALL_CYC, gemm_stall_cycles);
      READ_PERF(VX_CSR_MPM_GEMM_JOB_CNT, gemm_job_count);
      READ_PERF(VX_CSR_MPM_MXU_INPUT_FIRE, mxu_input_fire);
      READ_PERF(VX_CSR_MPM_MXU_INPUT_STALL, mxu_input_stall);
      READ_PERF(VX_CSR_MPM_MXU_WEIGHT_FIRE, mxu_weight_fire);
      READ_PERF(VX_CSR_MPM_MXU_WEIGHT_STALL, mxu_weight_stall);
      READ_PERF(VX_CSR_MPM_MXU_PSUM_FIRE, mxu_psum_fire);
      READ_PERF(VX_CSR_MPM_MXU_PSUM_STALL, mxu_psum_stall);
      READ_PERF(VX_CSR_MPM_MXU_OUTPUT_FIRE, mxu_output_fire);
      READ_PERF(VX_CSR_MPM_MXU_OUTPUT_STALL, mxu_output_stall);
      READ_PERF(VX_CSR_MPM_MXU_MAC_COUNT, mxu_mac_count);
      // GEMM node
      READ_PERF(VX_CSR_MPM_GEMM_TOTAL_CYC, gemm_total_cycles);
      READ_PERF(VX_CSR_MPM_LMEM_RD_BYTES, lmem_rd_bytes);
      READ_PERF(VX_CSR_MPM_LMEM_WR_BYTES, lmem_wr_bytes);
      // DMA
      READ_PERF(VX_CSR_MPM_DMA_RD_BYTES, dma_rd_bytes);
      READ_PERF(VX_CSR_MPM_DMA_WR_BYTES, dma_wr_bytes);
      READ_PERF(VX_CSR_MPM_DMA_XFER_CNT, dma_xfer_count);
      READ_PERF(VX_CSR_MPM_DMA_ACTIVE_CYC, dma_active_cycles);
      READ_PERF(VX_CSR_MPM_DMA_WAIT_DCACHE, dma_wait_dcache);
      READ_PERF(VX_CSR_MPM_DMA_WAIT_LMEM, dma_wait_lmem);
      READ_PERF(VX_CSR_MPM_DMA_SRC_RD_REQ_FIRE, dma_src_rd_req_fire);
      READ_PERF(VX_CSR_MPM_DMA_SRC_RD_REQ_STALL, dma_src_rd_req_stall);
      READ_PERF(VX_CSR_MPM_DMA_SRC_RD_DATA_FIRE, dma_src_rd_data_fire);
      READ_PERF(VX_CSR_MPM_DMA_SRC_RD_DATA_STALL, dma_src_rd_data_stall);
      READ_PERF(VX_CSR_MPM_DMA_DST_WR_FIRE, dma_dst_wr_fire);
      READ_PERF(VX_CSR_MPM_DMA_DST_WR_STALL, dma_dst_wr_stall);
      // Overlap
      READ_PERF(VX_CSR_MPM_OVERLAP_DMA_MXU, overlap_dma_mxu);
      #undef READ_PERF
    } break;
    default:
      break;
    }

    float IPC = caclAverage(instrs_per_core, cycles_per_core);
    if (num_cores > 1) fprintf(stream, "PERF: core%d: instrs=%ld, cycles=%ld, IPC=%f\n", core_id, instrs_per_core, cycles_per_core, IPC);
    total_instrs += instrs_per_core;
    total_cycles += cycles_per_core;
    max_cycles = std::max<uint64_t>(cycles_per_core, max_cycles);
  }

  switch (perf_class) {
  case VX_DCR_MPM_CLASS_CORE: {
    int sched_idles_percent = calcAvgPercent(sched_idles, total_cycles);
    int sched_stalls_percent = calcAvgPercent(sched_stalls, total_cycles);
    int ibuffer_percent = calcAvgPercent(ibuffer_stalls, total_cycles);
    int scrb_percent = calcAvgPercent(scrb_stalls, total_cycles);
    int opds_percent = calcAvgPercent(opds_stalls, total_cycles);
    int ifetch_avg_lat = caclAverage(ifetch_lat, ifetches);
    int load_avg_lat = caclAverage(load_lat, loads);
    uint64_t scrb_total = scrb_alu + scrb_fpu + scrb_lsu + scrb_csrs + scrb_wctl;
    fprintf(stream, "PERF: scheduler idle=%ld (%d%%)\n", sched_idles, sched_idles_percent);
    fprintf(stream, "PERF: scheduler stalls=%ld (%d%%)\n", sched_stalls, sched_stalls_percent);
    fprintf(stream, "PERF: ibuffer stalls=%ld (%d%%)\n", ibuffer_stalls, ibuffer_percent);
    fprintf(stream, "PERF: scoreboard stalls=%ld (%d%%) (alu=%d%%, lsu=%d%%, csrs=%d%%, wctl=%d%%"
      , scrb_stalls
      , scrb_percent
      , calcAvgPercent(scrb_alu, scrb_total)
      , calcAvgPercent(scrb_lsu, scrb_total)
      , calcAvgPercent(scrb_csrs, scrb_total)
      , calcAvgPercent(scrb_wctl, scrb_total)
    );
    if (fpu_enable) {
      fprintf(stream, ", fpu=%d%%", calcAvgPercent(scrb_fpu, scrb_total));
    }
    if (vpu_enable) {
      fprintf(stream, ", vpu=%d%%", calcAvgPercent(scrb_vpu, scrb_total));
    }
    if (tcu_enable) {
      fprintf(stream, ", tcu=%d%%", calcAvgPercent(scrb_tcu, scrb_total));
    }
    fprintf(stream, ")\n");
    fprintf(stream, "PERF: operands stalls=%ld (%d%%)\n", opds_stalls, opds_percent);
    fprintf(stream, "PERF: ifetches=%ld\n", ifetches);
    fprintf(stream, "PERF: loads=%ld\n", loads);
    fprintf(stream, "PERF: stores=%ld\n", stores);
    fprintf(stream, "PERF: ifetch latency=%d cycles\n", ifetch_avg_lat);
    fprintf(stream, "PERF: load latency=%d cycles\n", load_avg_lat);
  } break;
  case VX_DCR_MPM_CLASS_MEM: {
    if (l2cache_enable) {
      l2cache_reads /= num_cores;
      l2cache_writes /= num_cores;
      l2cache_read_misses /= num_cores;
      l2cache_write_misses /= num_cores;
      l2cache_bank_stalls /= num_cores;
      l2cache_mshr_stalls /= num_cores;
      int read_hit_ratio = calcRatio(l2cache_read_misses, l2cache_reads);
      int write_hit_ratio = calcRatio(l2cache_write_misses, l2cache_writes);
      int bank_utilization = calcAvgPercent(l2cache_reads + l2cache_writes, l2cache_reads + l2cache_writes + l2cache_bank_stalls);
      int mshr_utilization = calcAvgPercent(l2cache_read_misses + l2cache_write_misses, l2cache_read_misses + l2cache_write_misses + l2cache_mshr_stalls);
      fprintf(stream, "PERF: l2cache reads=%ld\n", l2cache_reads);
      fprintf(stream, "PERF: l2cache writes=%ld\n", l2cache_writes);
      fprintf(stream, "PERF: l2cache read misses=%ld (hit ratio=%d%%)\n", l2cache_read_misses, read_hit_ratio);
      fprintf(stream, "PERF: l2cache write misses=%ld (hit ratio=%d%%)\n", l2cache_write_misses, write_hit_ratio);
      fprintf(stream, "PERF: l2cache bank stalls=%ld (utilization=%d%%)\n", l2cache_bank_stalls, bank_utilization);
      fprintf(stream, "PERF: l2cache mshr stalls=%ld (utilization=%d%%)\n", l2cache_mshr_stalls, mshr_utilization);
    }

    if (l3cache_enable) {
      int read_hit_ratio = calcRatio(l3cache_read_misses, l3cache_reads);
      int write_hit_ratio = calcRatio(l3cache_write_misses, l3cache_writes);
      int bank_utilization = calcAvgPercent(l3cache_reads + l3cache_writes, l3cache_reads + l3cache_writes + l3cache_bank_stalls);
      int mshr_utilization = calcAvgPercent(l3cache_read_misses + l3cache_write_misses, l3cache_read_misses + l3cache_write_misses + l3cache_mshr_stalls);
      fprintf(stream, "PERF: l3cache reads=%ld\n", l3cache_reads);
      fprintf(stream, "PERF: l3cache writes=%ld\n", l3cache_writes);
      fprintf(stream, "PERF: l3cache read misses=%ld (hit ratio=%d%%)\n", l3cache_read_misses, read_hit_ratio);
      fprintf(stream, "PERF: l3cache write misses=%ld (hit ratio=%d%%)\n", l3cache_write_misses, write_hit_ratio);
      fprintf(stream, "PERF: l3cache bank stalls=%ld (utilization=%d%%)\n", l3cache_bank_stalls, bank_utilization);
      fprintf(stream, "PERF: l3cache mshr stalls=%ld (utilization=%d%%)\n", l3cache_mshr_stalls, mshr_utilization);
    }

    {
      uint64_t mem_requests = mem_reads + mem_writes;
      int mem_avg_lat = caclAverage(mem_lat, mem_reads);
      int mem_bank_utilization = calcAvgPercent(mem_requests, mem_requests + mem_bank_stalls);
      fprintf(stream, "PERF: memory requests=%ld (reads=%ld, writes=%ld)\n", mem_requests, mem_reads, mem_writes);
      fprintf(stream, "PERF: memory latency=%d cycles\n", mem_avg_lat);
      fprintf(stream, "PERF: memory bank stalls=%ld (utilization=%d%%)\n", mem_bank_stalls, mem_bank_utilization);
    }
  } break;
  case VX_DCR_MPM_CLASS_ACCEL: {
    fprintf(stream, "PERF: === GEMM Performance Analysis ===\n");
    fprintf(stream, "PERF: gemm jobs=%ld, total_cycles=%ld, dma_transfers=%ld\n",
            gemm_job_count, gemm_total_cycles, dma_xfer_count);
    fprintf(stream, "PERF: DMA+MXU overlap=%.3f%% (%ld / %ld)\n",
            (gemm_total_cycles > 0) ? 100.0 * overlap_dma_mxu / gemm_total_cycles : 0.0,
            overlap_dma_mxu, gemm_total_cycles);

    // --- MXU Raw Counters ---
    fprintf(stream, "PERF: --- MXU Raw Counters ---\n");
    fprintf(stream, "PERF: compute_cycles=%ld, mac_count=%ld\n", gemm_compute_cycles, mxu_mac_count);
    fprintf(stream, "PERF: input:  fire=%ld, stall=%ld\n", mxu_input_fire, mxu_input_stall);
    fprintf(stream, "PERF: weight: fire=%ld, stall=%ld\n", mxu_weight_fire, mxu_weight_stall);
    fprintf(stream, "PERF: psum:   fire=%ld, stall=%ld\n", mxu_psum_fire, mxu_psum_stall);
    fprintf(stream, "PERF: output: fire=%ld, stall=%ld\n", mxu_output_fire, mxu_output_stall);

    // --- MXU Utilization Table ---
    fprintf(stream, "PERF: --- MXU Utilization (fire / denominator) ---\n");
    fprintf(stream, "PERF: %-16s /total_cycles   /active_cycles\n", "");
    const char* mxu_names[] = {"input_fire", "weight_fire", "psum_fire", "output_fire"};
    uint64_t mxu_fires[] = {mxu_input_fire, mxu_weight_fire, mxu_psum_fire, mxu_output_fire};
    for (int i = 0; i < 4; i++) {
      double pct_total  = (gemm_total_cycles > 0)   ? 100.0 * mxu_fires[i] / gemm_total_cycles   : 0.0;
      double pct_active = (gemm_compute_cycles > 0) ? 100.0 * mxu_fires[i] / gemm_compute_cycles : 0.0;
      fprintf(stream, "PERF: %-16s %7.3f%%        %7.3f%%\n", mxu_names[i], pct_total, pct_active);
    }

    // --- DMA Raw Counters ---
    fprintf(stream, "PERF: --- DMA Raw Counters ---\n");
    fprintf(stream, "PERF: active_cycles=%ld, rd_bytes=%ld, wr_bytes=%ld\n",
            dma_active_cycles, dma_rd_bytes, dma_wr_bytes);
    fprintf(stream, "PERF: wait_dcache=%ld, wait_lmem=%ld\n", dma_wait_dcache, dma_wait_lmem);
    fprintf(stream, "PERF: src_rd_req:  fire=%ld, stall=%ld\n", dma_src_rd_req_fire, dma_src_rd_req_stall);
    fprintf(stream, "PERF: src_rd_data: fire=%ld, stall=%ld\n", dma_src_rd_data_fire, dma_src_rd_data_stall);
    fprintf(stream, "PERF: dst_wr:      fire=%ld, stall=%ld\n", dma_dst_wr_fire, dma_dst_wr_stall);

    // --- DMA Utilization Table ---
    fprintf(stream, "PERF: --- DMA Utilization (fire / denominator) ---\n");
    fprintf(stream, "PERF: %-16s /total_cycles   /active_cycles\n", "");
    const char* dma_names[] = {"src_rd_req_fire", "src_rd_data_fire", "dst_wr_fire"};
    uint64_t dma_fires[] = {dma_src_rd_req_fire, dma_src_rd_data_fire, dma_dst_wr_fire};
    for (int i = 0; i < 3; i++) {
      double pct_total  = (gemm_total_cycles > 0)  ? 100.0 * dma_fires[i] / gemm_total_cycles  : 0.0;
      double pct_active = (dma_active_cycles > 0)  ? 100.0 * dma_fires[i] / dma_active_cycles  : 0.0;
      fprintf(stream, "PERF: %-16s %7.3f%%        %7.3f%%\n", dma_names[i], pct_total, pct_active);
    }

    // --- Roofline ---
    fprintf(stream, "PERF: --- Roofline ---\n");
    uint64_t total_flops = mxu_mac_count * 2;
    uint64_t hbm_bytes = dma_rd_bytes + dma_wr_bytes;
    uint64_t lmem_bytes = lmem_rd_bytes + lmem_wr_bytes;
    float achieved_flops_per_cycle = (gemm_total_cycles > 0) ? (float)total_flops / (float)gemm_total_cycles : 0.0f;
    float hbm_bw_per_cycle = (gemm_total_cycles > 0) ? (float)hbm_bytes / (float)gemm_total_cycles : 0.0f;
    float lmem_bw_per_cycle = (gemm_total_cycles > 0) ? (float)lmem_bytes / (float)gemm_total_cycles : 0.0f;
    float op_intensity = (hbm_bytes > 0) ? (float)total_flops / (float)hbm_bytes : 0.0f;
    fprintf(stream, "PERF: MACs=%ld, FLOPs=%ld\n", mxu_mac_count, total_flops);
    fprintf(stream, "PERF: HBM bytes=%ld (read=%ld, write=%ld)\n", hbm_bytes, dma_rd_bytes, dma_wr_bytes);
    fprintf(stream, "PERF: LMEM bytes=%ld (read=%ld, write=%ld)\n", lmem_bytes, lmem_rd_bytes, lmem_wr_bytes);
    fprintf(stream, "PERF: Operational Intensity=%.3f FLOPs/byte (HBM)\n", op_intensity);
    fprintf(stream, "PERF: Achieved throughput=%.3f FLOPs/cycle\n", achieved_flops_per_cycle);
    fprintf(stream, "PERF: HBM bandwidth=%.3f bytes/cycle\n", hbm_bw_per_cycle);
    fprintf(stream, "PERF: LMEM bandwidth=%.3f bytes/cycle\n", lmem_bw_per_cycle);
  } break;
  default:
    break;
  }

  float IPC = caclAverage(total_instrs, max_cycles);
  fprintf(stream, "PERF: instrs=%ld, cycles=%ld, IPC=%f\n", total_instrs, max_cycles, IPC);

  fflush(stream);

  return 0;
}

int vx_check_occupancy(vx_device_h hdevice, uint32_t group_size, uint32_t* max_localmem) {
   // check group size
  uint64_t warps_per_core, threads_per_warp;
  CHECK_ERR(vx_dev_caps(hdevice, VX_CAPS_NUM_WARPS, &warps_per_core), {
    return err;
  });
  CHECK_ERR(vx_dev_caps(hdevice, VX_CAPS_NUM_THREADS, &threads_per_warp), {
    return err;
  });
  uint32_t threads_per_core = warps_per_core * threads_per_warp;
  if (group_size > threads_per_core) {
    printf("Error: cannot schedule kernel with group_size > threads_per_core (%d,%d)\n", group_size, threads_per_core);
    return -1;
  }

  // calculate groups occupancy
  int warps_per_group = (group_size + threads_per_warp-1) / threads_per_warp;
  int groups_per_core = warps_per_core / warps_per_group;

  // check local memory capacity
  if (max_localmem) {
    uint64_t local_mem_size;
    CHECK_ERR(vx_dev_caps(hdevice, VX_CAPS_LOCAL_MEM_SIZE, &local_mem_size), {
      return err;
    });
    *max_localmem = local_mem_size / groups_per_core;
  }

  return 0;
}