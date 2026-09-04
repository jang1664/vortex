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

inline SlotBytes output_slot_bytes(uint32_t cur_m, uint32_t mxu_nt) {
  const uint64_t payload = checked_mul3(cur_m, mxu_nt, kFp16Bytes);
  const uint64_t reserved = checked_mul3(
      align_up(cur_m, kStripeRows), mxu_nt, kFp16Bytes);
  const SlotBytes bytes = checked_slot(payload, reserved);
  assert(bytes.transfer <= bytes.reserved);
  return bytes;
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

}  // namespace fpint_gemm_layout

#endif  // _FPINT_GEMM_FFN_HW_LAYOUT_H_
