#include "VortexGenerator.h"

static std::vector<at::Generator> default_generators;

namespace c10::vortex {

const at::Generator& getDefaultVortexGenerator(c10::DeviceIndex device_index) {
  static bool flag [[maybe_unused]] = []() {
    auto num_devices = device_count();
    default_generators.resize(num_devices);
    for (int i = 0; i < num_devices; i++) {
      default_generators[i] = at::make_generator<VortexGeneratorImpl>(i);
      default_generators[i].seed();
    }
    return true;
  }();

  c10::DeviceIndex idx = device_index;
  if (idx == -1) {
    idx = current_device();
  } else {
    TORCH_CHECK(idx >= 0 && idx < device_count());
  }
  return default_generators[idx];
}

} // namespace c10::vortex
