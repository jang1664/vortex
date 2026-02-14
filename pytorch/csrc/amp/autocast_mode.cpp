#include <ATen/autocast_mode.h>

using at::Tensor;

// ---- AMP (Automatic Mixed Precision) support ----

// Fallthrough: let all ops pass through without casting by default
TORCH_LIBRARY_IMPL(_, AutocastPrivateUse1, m) {
  m.fallback(torch::CppFunction::makeFallthrough());
}

// Specific AMP overrides can be added here:
// TORCH_LIBRARY_IMPL(aten, AutocastPrivateUse1, m) {
//   KERNEL_PRIVATEUSEONE(mm, lower_precision_fp)
//   KERNEL_PRIVATEUSEONE(asin, fp32)
// }
