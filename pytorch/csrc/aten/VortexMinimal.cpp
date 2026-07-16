#include "native/Minimal.h"

#include <ATen/native/CPUFallback.h>
#include <ATen/native/DispatchStub.h>
#include <torch/library.h>

// Metadata-only view/shape ops.  Each of these computes new sizes/strides
// and calls self.as_strided(...) (already registered natively on
// PrivateUse1 above), so registering them here keeps the whole op on
// device instead of falling through to the global CPU fallback.
#include <ATen/ops/_unsafe_view_native.h>
#include <ATen/ops/contiguous_native.h>
#include <ATen/ops/expand_native.h>
#include <ATen/ops/flatten_native.h>
#include <ATen/ops/permute_native.h>
#include <ATen/ops/reshape_native.h>
#include <ATen/ops/select_native.h>
#include <ATen/ops/slice_native.h>
#include <ATen/ops/squeeze_native.h>
#include <ATen/ops/t_native.h>
#include <ATen/ops/transpose_native.h>
#include <ATen/ops/unsqueeze_native.h>

namespace at::vortex {

namespace {

at::Tensor wrapper_empty_memory_format(
    c10::IntArrayRef size,
    std::optional<c10::ScalarType> dtype_opt,
    std::optional<c10::Layout> layout_opt,
    std::optional<c10::Device> device_opt,
    std::optional<bool> pin_memory_opt,
    std::optional<c10::MemoryFormat> memory_format_opt) {
  return at::native::vortex::empty_memory_format(
      size, dtype_opt, layout_opt, device_opt, pin_memory_opt, memory_format_opt);
}

at::Tensor wrapper_empty_strided(
    c10::IntArrayRef size,
    c10::IntArrayRef stride,
    std::optional<c10::ScalarType> dtype_opt,
    std::optional<c10::Layout> layout_opt,
    std::optional<c10::Device> device_opt,
    std::optional<bool> pin_memory_opt) {
  return at::native::vortex::empty_strided(
      size, stride, dtype_opt, layout_opt, device_opt, pin_memory_opt);
}

at::Tensor wrapper_as_strided(
    const at::Tensor& self,
    c10::SymIntArrayRef size,
    c10::SymIntArrayRef stride,
    std::optional<c10::SymInt> storage_offset) {
  return at::native::vortex::as_strided(self, size, stride, storage_offset);
}

const at::Tensor& wrapper_resize_(
    const at::Tensor& self,
    c10::SymIntArrayRef size,
    std::optional<at::MemoryFormat> memory_format) {
  return at::native::vortex::resize_(self, size, memory_format);
}

at::Tensor wrapper__reshape_alias(
    const at::Tensor& self,
    c10::SymIntArrayRef size,
    c10::SymIntArrayRef stride) {
  return at::native::vortex::_reshape_alias(self, size, stride);
}

at::Tensor wrapper__copy_from(
    const at::Tensor& self,
    const at::Tensor& dst,
    bool non_blocking) {
  return at::native::vortex::_copy_from(self, dst, non_blocking);
}

at::Tensor wrapper__copy_from_and_resize(
    const at::Tensor& self,
    const at::Tensor& dst) {
  return at::native::vortex::_copy_from_and_resize(self, dst);
}

at::Scalar wrapper__local_scalar_dense(const at::Tensor& self) {
  return at::native::vortex::_local_scalar_dense(self);
}

at::Tensor& wrapper_set_source_Tensor_(
    at::Tensor& self,
    const at::Tensor& source) {
  return at::native::vortex::set_source_Tensor_(self, source);
}

at::Tensor& wrapper_set_source_Storage_(at::Tensor& self, at::Storage source) {
  return at::native::vortex::set_source_Storage_(self, source);
}

at::Tensor& wrapper_set_source_Storage_storage_offset_(
    at::Tensor& result,
    at::Storage storage,
    int64_t storage_offset,
    c10::IntArrayRef size,
    c10::IntArrayRef stride) {
  return at::native::vortex::set_source_Storage_storage_offset_(
      result, storage, storage_offset, size, stride);
}

at::Tensor wrapper_view(const at::Tensor& self, c10::SymIntArrayRef size) {
  return at::native::vortex::view(self, size);
}

// ---- Pure-metadata view/shape ops ----
// Each wrapper below forwards to the backend-agnostic at::native::<op> free
// function, which computes new sizes/strides and calls self.as_strided(...).
// as_strided is already registered natively on PrivateUse1, so these ops
// stay entirely on device (no CPU round trip).

at::Tensor wrapper_transpose_int(
    const at::Tensor& self,
    int64_t dim0,
    int64_t dim1) {
  return at::native::transpose(self, dim0, dim1);
}

at::Tensor wrapper_permute(const at::Tensor& self, c10::IntArrayRef dims) {
  return at::native::permute(self, dims);
}

at::Tensor wrapper_reshape(const at::Tensor& self, c10::SymIntArrayRef shape) {
  return at::native::reshape_symint(self, shape);
}

at::Tensor wrapper_unsqueeze(const at::Tensor& self, int64_t dim) {
  return at::native::unsqueeze(self, dim);
}

at::Tensor wrapper_squeeze(const at::Tensor& self) {
  return at::native::squeeze(self);
}

at::Tensor wrapper_squeeze_dim(const at::Tensor& self, int64_t dim) {
  return at::native::squeeze(self, dim);
}

at::Tensor wrapper_squeeze_dims(const at::Tensor& self, c10::IntArrayRef dim) {
  return at::native::squeeze(self, dim);
}

at::Tensor wrapper_select_int(
    const at::Tensor& self,
    int64_t dim,
    c10::SymInt index) {
  return at::native::select_symint(self, dim, std::move(index));
}

at::Tensor wrapper_slice_Tensor(
    const at::Tensor& self,
    int64_t dim,
    std::optional<c10::SymInt> start,
    std::optional<c10::SymInt> end,
    c10::SymInt step) {
  // native::slice only takes plain int64_t bounds; guard_int() is the
  // standard way to materialize a SymInt when no symbolic shapes are in
  // play (always true for this eager-mode backend).
  std::optional<int64_t> start_i = start.has_value()
      ? std::make_optional(start->guard_int(__FILE__, __LINE__))
      : std::nullopt;
  std::optional<int64_t> end_i = end.has_value()
      ? std::make_optional(end->guard_int(__FILE__, __LINE__))
      : std::nullopt;
  int64_t step_i = step.guard_int(__FILE__, __LINE__);
  return at::native::slice(self, dim, start_i, end_i, step_i);
}

at::Tensor wrapper_contiguous(
    const at::Tensor& self,
    at::MemoryFormat memory_format) {
  return at::native::contiguous(self, memory_format);
}

at::Tensor wrapper_t(const at::Tensor& self) {
  return at::native::t(self);
}

at::Tensor wrapper_expand(
    const at::Tensor& self,
    c10::SymIntArrayRef size,
    bool implicit) {
  return at::native::expand(self, C10_AS_INTARRAYREF_SLOW(size), implicit);
}

at::Tensor wrapper__unsafe_view(
    const at::Tensor& self,
    c10::SymIntArrayRef size) {
  return at::native::_unsafe_view(self, C10_AS_INTARRAYREF_SLOW(size));
}

at::Tensor wrapper_flatten_using_ints(
    const at::Tensor& self,
    int64_t start_dim,
    int64_t end_dim) {
  return at::native::flatten(self, start_dim, end_dim);
}

bool wrapper_has_compatible_shallow_copy_type(
    const at::Tensor& /*self*/,
    const at::Tensor& /*other*/) {
  return true;
}

void wrapper_cpu_fallback(
    const c10::OperatorHandle& op,
    torch::jit::Stack* stack) {
  at::native::vortex::cpu_fallback(op, stack);
}

} // namespace

// ---- Register mandatory ops ----
TORCH_LIBRARY_IMPL(aten, PrivateUse1, m) {
  m.impl("empty.memory_format", wrapper_empty_memory_format);
  m.impl("empty_strided", wrapper_empty_strided);
  m.impl("as_strided", wrapper_as_strided);
  m.impl("resize_", wrapper_resize_);
  m.impl("_reshape_alias", wrapper__reshape_alias);
  m.impl("_copy_from", wrapper__copy_from);
  m.impl("_copy_from_and_resize", wrapper__copy_from_and_resize);
  m.impl("_local_scalar_dense", wrapper__local_scalar_dense);
  m.impl("_has_compatible_shallow_copy_type", wrapper_has_compatible_shallow_copy_type);
  m.impl("set_.source_Tensor", wrapper_set_source_Tensor_);
  m.impl("set_.source_Storage", wrapper_set_source_Storage_);
  m.impl("set_.source_Storage_storage_offset", wrapper_set_source_Storage_storage_offset_);
  m.impl("view", wrapper_view);

  // ---- Pure-metadata view/shape ops (see wrappers above) ----
  m.impl("transpose.int", wrapper_transpose_int);
  m.impl("permute", wrapper_permute);
  m.impl("reshape", wrapper_reshape);
  m.impl("unsqueeze", wrapper_unsqueeze);
  m.impl("squeeze", wrapper_squeeze);
  m.impl("squeeze.dim", wrapper_squeeze_dim);
  m.impl("squeeze.dims", wrapper_squeeze_dims);
  m.impl("select.int", wrapper_select_int);
  m.impl("slice.Tensor", wrapper_slice_Tensor);
  m.impl("contiguous", wrapper_contiguous);
  m.impl("t", wrapper_t);
  m.impl("expand", wrapper_expand);
  m.impl("_unsafe_view", wrapper__unsafe_view);
  m.impl("flatten.using_ints", wrapper_flatten_using_ints);
}

// ---- Global CPU fallback for all unregistered ops ----
TORCH_LIBRARY_IMPL(_, PrivateUse1, m) {
  m.fallback(
      torch::CppFunction::makeFromBoxedFunction<&wrapper_cpu_fallback>());
}

} // namespace at::vortex
