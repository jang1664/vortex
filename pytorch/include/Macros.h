#pragma once

#ifdef _WIN32
#define VORTEX_EXPORT __declspec(dllexport)
#else
#define VORTEX_EXPORT __attribute__((visibility("default")))
#endif
