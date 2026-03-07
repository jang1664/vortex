#include <Python.h>

#ifdef _WIN32
#define VORTEX_EXPORT __declspec(dllexport)
#else
#define VORTEX_EXPORT __attribute__((visibility("default")))
#endif

extern VORTEX_EXPORT PyObject* initVortexModule(void);

#ifdef __cplusplus
extern "C"
#endif

    VORTEX_EXPORT PyObject*
    PyInit__C(void);

PyMODINIT_FUNC PyInit__C(void) {
  return initVortexModule();
}
