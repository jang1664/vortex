#include "VortexHooks.h"

namespace c10::vortex {

static bool register_hook_flag [[maybe_unused]] = []() {
  at::RegisterPrivateUse1HooksInterface(new VortexHooksInterface());
  return true;
}();

} // namespace c10::vortex
