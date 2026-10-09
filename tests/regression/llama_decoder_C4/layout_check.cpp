// Host ABI check: enumerate physical DMA order independently of offset helpers.
#include "../layout_fused_common/layout_fused_layouts.h"
#include "../fpint_gemm_ffn_hw/layout.h"
#include <cassert>
#include <iostream>
#include <vector>

int main() {
  for (uint32_t target_rows : {1u, 4u, 32u, 129u, 136u, 256u}) {
    // The decoder's fused vectors use a padded parent matrix, while GEMM
    // executes only target_rows. Enumerate the parent's physical DMA order.
    const uint32_t rows = (target_rows + 7u) & ~7u;
    for (uint32_t columns : {32u, 128u, 256u, 4096u, 11008u, 14336u}) {
      std::vector<uint32_t> packed(rows * columns);
      uint64_t cursor = 0;
      for (uint32_t tile = 0; tile < rows; tile += 128)
        for (uint32_t micro = 0; micro < columns; micro += 16)
          for (uint32_t row = tile; row < min_u32(rows, tile + 128); ++row)
            for (uint32_t lane = 0; lane < 16; ++lane) {
              auto column = micro + lane;
              auto offset = gemm_c_tiled_elem_offset(row, column, rows, columns, 7, 4);
              assert(offset == cursor++);
              packed[offset] = row * columns + column;
            }
      assert(cursor == packed.size());
      for (uint32_t row = 0; row < target_rows; ++row)
        for (uint32_t column = 0; column < columns; ++column)
          assert(packed[gemm_a_tiled_elem_offset(row, column, rows, columns, 7, 4)]
                 == row * columns + column);
    }
  }
  struct Args {
    uint64_t lmem_ibuf[2], lmem_wbuf[2], lmem_scbuf[2], lmem_zpbuf[2], lmem_obuf[2];
  } args{};
  // The original QCOL/32 host allocation occupies 151552 bytes exactly.
  assert(fpint_gemm_layout::allocate_tmem_buffers(args, 151552, 128, 128, 128, 16, 32, 0));
  assert(args.lmem_ibuf[1] == 32768 && args.lmem_wbuf[0] == 65536);
  assert(args.lmem_scbuf[0] == 81920 && args.lmem_obuf[1] == 118784);
  assert(!fpint_gemm_layout::allocate_tmem_buffers(args, 151551, 128, 128, 128, 16, 32, 0));
  std::cout << "HOST LAYOUT/TMEM CHECK PASS\n";
}
