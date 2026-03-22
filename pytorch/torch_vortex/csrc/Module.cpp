#include <ATen/Context.h>

#include <torch/csrc/Exceptions.h>
#include <torch/csrc/utils.h>
#include <torch/csrc/utils/device_lazy_init.h>
#include <torch/csrc/utils/object_ptr.h>
#include <torch/csrc/utils/python_numbers.h>

#include <runtime/VortexFunctions.h>
#include <runtime/VortexDeviceAllocator.h>
#include <runtime/VortexRuntime.h>

static PyObject* _initExtension(PyObject* self, PyObject* noargs) {
  HANDLE_TH_ERRORS
  torch::utils::register_fork_handler_for_device_init(at::kPrivateUse1);
  at::globalContext().lazyInitDevice(c10::DeviceType::PrivateUse1);
  Py_RETURN_NONE;
  END_HANDLE_TH_ERRORS
}

static PyObject* _isInBadFork(PyObject* self, PyObject* noargs) {
  HANDLE_TH_ERRORS
  return PyBool_FromLong(torch::utils::is_device_in_bad_fork(at::kPrivateUse1));
  END_HANDLE_TH_ERRORS
}

static PyObject* _getDefaultGenerator(PyObject* self, PyObject* arg) {
  HANDLE_TH_ERRORS
  TORCH_CHECK(
      THPUtils_checkLong(arg),
      "_get_default_generator expects an int, but got ",
      THPUtils_typename(arg));
  auto idx = static_cast<int>(THPUtils_unpackLong(arg));

  torch::utils::register_fork_handler_for_device_init(at::kPrivateUse1);
  return THPGenerator_initDefaultGenerator(
      at::globalContext().defaultGenerator(
          c10::Device(c10::DeviceType::PrivateUse1, idx)));
  END_HANDLE_TH_ERRORS
}

static PyObject* _setDevice(PyObject* self, PyObject* arg) {
  HANDLE_TH_ERRORS
  TORCH_CHECK(THPUtils_checkLong(arg), "invalid argument to setDevice");
  auto device = THPUtils_unpackDeviceIndex(arg);
  torch::utils::device_lazy_init(at::kPrivateUse1);
  c10::vortex::set_device(device);
  Py_RETURN_NONE;
  END_HANDLE_TH_ERRORS
}

static PyObject* _exchangeDevice(PyObject* self, PyObject* arg) {
  HANDLE_TH_ERRORS
  TORCH_CHECK(THPUtils_checkLong(arg), "invalid argument to exchangeDevice");
  auto device_index = THPUtils_unpackDeviceIndex(arg);
  if (device_index < 0) {
    return THPUtils_packInt32(-1);
  }
  torch::utils::device_lazy_init(at::kPrivateUse1);
  auto current_device = c10::vortex::ExchangeDevice(device_index);
  return THPUtils_packDeviceIndex(current_device);
  END_HANDLE_TH_ERRORS
}

static PyObject* _getDevice(PyObject* self, PyObject* noargs) {
  HANDLE_TH_ERRORS
  torch::utils::device_lazy_init(at::kPrivateUse1);
  auto device = static_cast<int32_t>(c10::vortex::current_device());
  return THPUtils_packInt32(device);
  END_HANDLE_TH_ERRORS
}

static PyObject* _getDeviceCount(PyObject* self, PyObject* noargs) {
  HANDLE_TH_ERRORS
  torch::utils::register_fork_handler_for_device_init(at::kPrivateUse1);
  return THPUtils_packUInt64(c10::vortex::device_count());
  END_HANDLE_TH_ERRORS
}

static PyObject* _getGlobalMemSize(PyObject* self, PyObject* noargs) {
  HANDLE_TH_ERRORS
  auto mem_size = c10::vortex::VortexRuntime::instance().globalMemSize();
  return THPUtils_packUInt64(mem_size);
  END_HANDLE_TH_ERRORS
}

static PyObject* _emptyCache(PyObject* self, PyObject* noargs) {
  HANDLE_TH_ERRORS
  c10::vortex::allocator_empty_cache();
  Py_RETURN_NONE;
  END_HANDLE_TH_ERRORS
}

static PyObject* _memoryAllocated(PyObject* self, PyObject* arg) {
  HANDLE_TH_ERRORS
  TORCH_CHECK(THPUtils_checkLong(arg), "invalid argument to memory_allocated");
  auto device = THPUtils_unpackDeviceIndex(arg);
  return THPUtils_packUInt64(c10::vortex::allocator_memory_allocated(device));
  END_HANDLE_TH_ERRORS
}

static PyObject* _memoryReserved(PyObject* self, PyObject* arg) {
  HANDLE_TH_ERRORS
  TORCH_CHECK(THPUtils_checkLong(arg), "invalid argument to memory_reserved");
  auto device = THPUtils_unpackDeviceIndex(arg);
  return THPUtils_packUInt64(c10::vortex::allocator_memory_reserved(device));
  END_HANDLE_TH_ERRORS
}

static PyObject* _maxMemoryAllocated(PyObject* self, PyObject* arg) {
  HANDLE_TH_ERRORS
  TORCH_CHECK(THPUtils_checkLong(arg), "invalid argument to max_memory_allocated");
  auto device = THPUtils_unpackDeviceIndex(arg);
  return THPUtils_packUInt64(c10::vortex::allocator_max_memory_allocated(device));
  END_HANDLE_TH_ERRORS
}

static PyObject* _maxMemoryReserved(PyObject* self, PyObject* arg) {
  HANDLE_TH_ERRORS
  TORCH_CHECK(THPUtils_checkLong(arg), "invalid argument to max_memory_reserved");
  auto device = THPUtils_unpackDeviceIndex(arg);
  return THPUtils_packUInt64(c10::vortex::allocator_max_memory_reserved(device));
  END_HANDLE_TH_ERRORS
}

static PyObject* _resetPeakMemoryStats(PyObject* self, PyObject* arg) {
  HANDLE_TH_ERRORS
  TORCH_CHECK(THPUtils_checkLong(arg), "invalid argument to reset_peak_memory_stats");
  auto device = THPUtils_unpackDeviceIndex(arg);
  c10::vortex::allocator_reset_peak_memory_stats(device);
  Py_RETURN_NONE;
  END_HANDLE_TH_ERRORS
}

static PyObject* _isAllocatorCachingEnabled(PyObject* self, PyObject* noargs) {
  HANDLE_TH_ERRORS
  return PyBool_FromLong(c10::vortex::allocator_is_caching_enabled());
  END_HANDLE_TH_ERRORS
}

static PyMethodDef methods[] = {
    {"_init", _initExtension, METH_NOARGS, nullptr},
    {"_isInBadFork", _isInBadFork, METH_NOARGS, nullptr},
    {"_get_default_generator", _getDefaultGenerator, METH_O, nullptr},
    {"_get_device", _getDevice, METH_NOARGS, nullptr},
    {"_set_device", _setDevice, METH_O, nullptr},
    {"_exchangeDevice", _exchangeDevice, METH_O, nullptr},
    {"_get_device_count", _getDeviceCount, METH_NOARGS, nullptr},
    {"_get_global_mem_size", _getGlobalMemSize, METH_NOARGS, nullptr},
    {"_empty_cache", _emptyCache, METH_NOARGS, nullptr},
    {"_memory_allocated", _memoryAllocated, METH_O, nullptr},
    {"_memory_reserved", _memoryReserved, METH_O, nullptr},
    {"_max_memory_allocated", _maxMemoryAllocated, METH_O, nullptr},
    {"_max_memory_reserved", _maxMemoryReserved, METH_O, nullptr},
    {"_reset_peak_memory_stats", _resetPeakMemoryStats, METH_O, nullptr},
    {"_is_allocator_caching_enabled", _isAllocatorCachingEnabled, METH_NOARGS, nullptr},
    {nullptr, nullptr, 0, nullptr}};

extern "C" VORTEX_EXPORT PyObject* initVortexModule(void) {
  static struct PyModuleDef vortex_C_module = {
      PyModuleDef_HEAD_INIT, "torch_vortex._C", nullptr, -1, methods};
  PyObject* mod = PyModule_Create(&vortex_C_module);
  return mod;
}
