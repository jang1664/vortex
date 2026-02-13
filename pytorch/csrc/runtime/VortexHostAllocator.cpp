#include "VortexHostAllocator.h"

namespace c10::vortex {

VortexHostAllocator caching_host_allocator;
REGISTER_HOST_ALLOCATOR(at::kPrivateUse1, &caching_host_allocator);

} // namespace c10::vortex
