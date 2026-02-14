#include <c10/util/Exception.h>

#include "VortexException.h"
#include "VortexFunctions.h"
#include "VortexRuntime.h"

namespace c10::vortex {

VORTEX_EXPORT DeviceIndex device_count() noexcept {
  static int count = []() {
    try {
      // Ensure runtime is initialized before querying device count
      VortexRuntime::instance().init();
      int c = 0;
      vortexGetDeviceCount(&c);
      TORCH_CHECK(
          c <= std::numeric_limits<DeviceIndex>::max(),
          "Too many devices, DeviceIndex overflowed");
      return c;
    } catch (const c10::Error& ex) {
      TORCH_WARN("Vortex device initialization: ", ex.msg());
      return 0;
    } catch (...) {
      TORCH_WARN("Vortex device initialization failed with unknown error");
      return 0;
    }
  }();
  return static_cast<DeviceIndex>(count);
}

VORTEX_EXPORT DeviceIndex current_device() {
  // Vortex is single-device, always index 0
  return 0;
}

VORTEX_EXPORT void set_device(DeviceIndex device) {
  check_device_index(device);
  // Single device — ensure runtime is initialized
  VortexRuntime::instance().init();
}

VORTEX_EXPORT DeviceIndex ExchangeDevice(DeviceIndex device) {
  DeviceIndex old = current_device();
  if (device != old) {
    set_device(device);
  }
  return old;
}

VORTEX_EXPORT DeviceIndex maybe_exchange_device(DeviceIndex to_device) {
  check_device_index(to_device);
  return ExchangeDevice(to_device);
}

} // namespace c10::vortex
