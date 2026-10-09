#ifndef _FPINT_GEMM_FFN_HW_LAYOUT_H_
#define _FPINT_GEMM_FFN_HW_LAYOUT_H_

#include <assert.h>
#include <stddef.h>
#include <stdint.h>

#include <limits>
#include <stdexcept>

namespace fpint_gemm_layout {

static constexpr uint64_t kExternalTransferBytes = 64;
static constexpr uint64_t kSlotAlignmentBytes = 512;
static constexpr uint64_t kStripeRows = 8;
static constexpr uint64_t kFp16Bytes = 2;

struct SlotBytes {
  uint64_t payload;
  uint64_t transfer;
  uint64_t reserved;
};

inline uint64_t checked_add(uint64_t lhs, uint64_t rhs) {
  if (rhs > std::numeric_limits<uint64_t>::max() - lhs)
    throw std::overflow_error("GEMM layout byte addition overflow");
  return lhs + rhs;
}

inline uint64_t checked_mul(uint64_t lhs, uint64_t rhs) {
  if (lhs != 0 && rhs > std::numeric_limits<uint64_t>::max() / lhs)
    throw std::overflow_error("GEMM layout byte multiplication overflow");
  return lhs * rhs;
}

inline uint64_t checked_mul3(uint64_t a, uint64_t b, uint64_t c) {
  return checked_mul(checked_mul(a, b), c);
}

inline uint64_t ceil_div(uint64_t value, uint64_t divisor) {
  if (divisor == 0)
    throw std::invalid_argument("GEMM layout divisor must be nonzero");
  return value / divisor + (value % divisor != 0);
}

inline uint64_t align_up(uint64_t value, uint64_t alignment) {
  if (alignment == 0)
    throw std::invalid_argument("GEMM layout alignment must be nonzero");
  return checked_mul(ceil_div(value, alignment), alignment);
}

inline size_t to_size(uint64_t value) {
  if (value > std::numeric_limits<size_t>::max())
    throw std::overflow_error("GEMM layout size exceeds size_t");
  return static_cast<size_t>(value);
}

inline uint32_t qcol_groups(uint32_t cur_k, uint32_t qblk) {
  const uint64_t groups = ceil_div(cur_k, qblk);
  if (groups > std::numeric_limits<uint32_t>::max())
    throw std::overflow_error("GEMM QCOL group count exceeds uint32_t");
  return static_cast<uint32_t>(groups);
}

inline uint32_t qrow_groups_per_mxu_nt(uint32_t mxu_nt, uint32_t qblk) {
  const uint64_t groups = ceil_div(mxu_nt, qblk);
  if (groups > std::numeric_limits<uint32_t>::max())
    throw std::overflow_error("GEMM QROW group count exceeds uint32_t");
  return static_cast<uint32_t>(groups);
}

inline uint64_t external_transfer_bytes(uint64_t payload) {
  return align_up(payload, kExternalTransferBytes);
}

inline SlotBytes checked_slot(uint64_t payload, uint64_t reserved) {
  const SlotBytes bytes = {payload, external_transfer_bytes(payload), reserved};
  if (bytes.transfer > bytes.reserved)
    throw std::logic_error("rounded GEMM transfer exceeds its reserved slot");
  return bytes;
}

inline SlotBytes input_slot_bytes(uint32_t cur_m, uint32_t cur_k) {
  const uint64_t payload = checked_mul3(cur_m, cur_k, kFp16Bytes);
  const uint64_t reserved = checked_mul3(
      align_up(cur_m, kStripeRows), cur_k, kFp16Bytes);
  const SlotBytes bytes = checked_slot(payload, reserved);
  assert(bytes.transfer <= bytes.reserved);
  return bytes;
}

inline SlotBytes output_slot_bytes(uint32_t cur_m, uint32_t cur_n) {
  // Like input, reserve padding at the DMA tile end, not between microtiles.
  // The same calculation also gives the total reservation for an M tile.
  return input_slot_bytes(cur_m, cur_n);
}

inline SlotBytes weight_microtile_bytes(uint32_t mxu_kt, uint32_t mxu_nt) {
  const uint64_t elements = checked_mul(mxu_kt, mxu_nt);
  if ((elements & 1u) != 0)
    throw std::logic_error("INT4 weight microtile must contain an even element count");
  const uint64_t payload = elements / 2;
  const SlotBytes bytes = checked_slot(payload, payload);
  assert(bytes.transfer <= bytes.reserved);
  return bytes;
}

inline uint64_t qparam_payload_bytes(uint32_t cur_k, uint32_t cur_n,
                                     uint32_t mxu_nt, uint32_t qblk,
                                     uint32_t qdir) {
  if (qdir == 0) {
    return checked_mul3(qcol_groups(cur_k, qblk), cur_n, kFp16Bytes);
  }
  if (qdir == 1) {
    if ((cur_n % mxu_nt) != 0)
      throw std::logic_error("QROW slot width must contain whole MXU N microtiles");
    return checked_mul3(
        checked_mul(cur_n / mxu_nt, cur_k),
        qrow_groups_per_mxu_nt(mxu_nt, qblk), kFp16Bytes);
  }
  throw std::invalid_argument("GEMM quantization direction must be 0 or 1");
}

inline SlotBytes qparam_slot_bytes(uint32_t cur_k, uint32_t cur_n,
                                   uint32_t mxu_nt, uint32_t qblk,
                                   uint32_t qdir) {
  const uint64_t payload =
      qparam_payload_bytes(cur_k, cur_n, mxu_nt, qblk, qdir);
  const uint64_t reserved = align_up(payload, kSlotAlignmentBytes);
  const SlotBytes bytes = checked_slot(payload, reserved);
  assert(bytes.transfer <= bytes.reserved);
  return bytes;
}

// Shared host TMEM allocation for the standalone GEMM and decoder app.
// Keep double-buffer order and capacities identical to the original host.
template <typename Args>
inline bool allocate_tmem_buffers(Args& kargs, uint64_t tensor_mem_size,
    uint32_t dma_mt, uint32_t dma_kt, uint32_t dma_nt, uint32_t mxu_nt,
    uint32_t qblk, uint32_t qdir) {
  uint32_t groups_tile = dma_kt / qblk;
  uint32_t nb_per_nt = dma_nt / mxu_nt;
  uint32_t ng_per_mxu_nt =
      fpint_gemm_layout::qrow_groups_per_mxu_nt(mxu_nt, qblk);

  uint64_t tmem_ibuf_bytes =
      fpint_gemm_layout::checked_mul3(dma_mt, dma_kt, 2);
  uint64_t tmem_wbuf_bytes = fpint_gemm_layout::checked_mul(
      dma_kt, (dma_nt + 1) / 2);
  uint64_t tmem_scbuf_bytes = (qdir == 0)
      ? fpint_gemm_layout::checked_mul3(groups_tile, dma_nt, 2)
      : fpint_gemm_layout::checked_mul3(
            fpint_gemm_layout::checked_mul(dma_kt, nb_per_nt),
            ng_per_mxu_nt, 2);
  uint64_t tmem_zpbuf_bytes = tmem_scbuf_bytes;
  uint64_t tmem_obuf_bytes =
      fpint_gemm_layout::checked_mul3(dma_mt, dma_nt, 2);

  uint64_t cur = 0;

  auto alloc = [&](uint64_t bytes, uint64_t& out_base) -> bool {
    cur = fpint_gemm_layout::align_up(cur, kSlotAlignmentBytes);
    if (cur > tensor_mem_size || bytes > (tensor_mem_size - cur)) return false;
    out_base = cur;
    cur = fpint_gemm_layout::checked_add(
        cur, fpint_gemm_layout::align_up(bytes, kSlotAlignmentBytes));
    return true;
  };

  // Double-buffered: buf0, buf1 consecutive for each category.
  // scbuf_bytes == zpbuf_bytes, so zpbuf[i] - scbuf[i] is constant = 2 * scbuf_slot.
  if (!alloc(tmem_ibuf_bytes,  kargs.lmem_ibuf[0]))  return false;
  if (!alloc(tmem_ibuf_bytes,  kargs.lmem_ibuf[1]))  return false;
  if (!alloc(tmem_wbuf_bytes,  kargs.lmem_wbuf[0]))  return false;
  if (!alloc(tmem_wbuf_bytes,  kargs.lmem_wbuf[1]))  return false;
  if (!alloc(tmem_scbuf_bytes, kargs.lmem_scbuf[0])) return false;
  if (!alloc(tmem_scbuf_bytes, kargs.lmem_scbuf[1])) return false;
  if (!alloc(tmem_zpbuf_bytes, kargs.lmem_zpbuf[0])) return false;
  if (!alloc(tmem_zpbuf_bytes, kargs.lmem_zpbuf[1])) return false;
  if (!alloc(tmem_obuf_bytes,  kargs.lmem_obuf[0]))  return false;
  if (!alloc(tmem_obuf_bytes,  kargs.lmem_obuf[1]))  return false;

  return true;
}

}  // namespace fpint_gemm_layout

#endif  // _FPINT_GEMM_FFN_HW_LAYOUT_H_
