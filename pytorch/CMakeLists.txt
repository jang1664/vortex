cmake_minimum_required(VERSION 3.18 FATAL_ERROR)

project(TORCH_VORTEX CXX C)

include(GNUInstallDirs)
include(CheckCXXCompilerFlag)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_C_STANDARD 17)
set(CMAKE_CXX_EXTENSIONS OFF)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
set(CMAKE_SKIP_BUILD_RPATH FALSE)
set(CMAKE_BUILD_WITH_INSTALL_RPATH TRUE)
set(CMAKE_INSTALL_RPATH_USE_LINK_PATH FALSE)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)

set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)

if(APPLE)
  set(CMAKE_INSTALL_RPATH "@loader_path/lib;@loader_path")
elseif(UNIX)
  set(CMAKE_INSTALL_RPATH "$ORIGIN/lib:$ORIGIN")
elseif(WIN32)
  set(CMAKE_INSTALL_RPATH "")
endif()
set(CMAKE_INSTALL_LIBDIR lib)
set(CMAKE_INSTALL_MESSAGE NEVER)

# ---- Find PyTorch ----
set(Torch_DIR ${PYTORCH_INSTALL_DIR}/share/cmake/Torch)
find_package(Torch REQUIRED)

# ---- Python ----
if(DEFINED PYTHON_INCLUDE_DIR)
  include_directories(${PYTHON_INCLUDE_DIR})
else()
  message(FATAL_ERROR "Cannot find Python directory")
endif()

# ---- Vortex runtime ----
if(NOT DEFINED VORTEX_HOME)
  message(FATAL_ERROR "VORTEX_HOME must be set to the Vortex project root")
endif()
if(NOT DEFINED VORTEX_BUILD_DIR)
  set(VORTEX_BUILD_DIR "${VORTEX_HOME}/build")
endif()

# Create an imported target for libvortex.so
add_library(vortex SHARED IMPORTED)
set_target_properties(vortex PROPERTIES
  IMPORTED_LOCATION "${VORTEX_BUILD_DIR}/runtime/libvortex.so"
  INTERFACE_INCLUDE_DIRECTORIES "${VORTEX_HOME}/runtime/include;${VORTEX_BUILD_DIR}/hw"
)

# ---- Project includes ----
include_directories(${CMAKE_CURRENT_SOURCE_DIR})
include_directories(${CMAKE_CURRENT_SOURCE_DIR}/include)
include(${PROJECT_SOURCE_DIR}/cmake/TorchPythonTargets.cmake)

# ---- Sub-projects ----
add_subdirectory(${PROJECT_SOURCE_DIR}/csrc)
# Use a custom binary dir to avoid creating build/torch_vortex/ which shadows
# the real Python package when cwd is the build directory.
add_subdirectory(${PROJECT_SOURCE_DIR}/torch_vortex/csrc ${CMAKE_BINARY_DIR}/bindings)

# ---- Install Vortex runtime libraries into torch_vortex/lib/ ----
# This lets libtorch_vortex.so (RUNPATH=$ORIGIN/lib:$ORIGIN) find libvortex.so
# at runtime without requiring LD_LIBRARY_PATH.
file(GLOB _vortex_runtime_libs "${VORTEX_BUILD_DIR}/runtime/lib*.so")
install(FILES ${_vortex_runtime_libs}
        DESTINATION ${CMAKE_INSTALL_PREFIX}/lib)
# Also bundle transitive dependencies (e.g. libramulator.so used by libsimx.so)
file(GLOB _vortex_thirdparty_libs "${VORTEX_HOME}/third_party/ramulator/lib*.so")
install(FILES ${_vortex_thirdparty_libs}
        DESTINATION ${CMAKE_INSTALL_PREFIX}/lib)

# ---- Install pre-built Vortex kernel binaries into torch_vortex/kernels/ ----
# These are the RISC-V binaries that native ATen ops launch on the device.
set(_ELADD_VXBIN "${VORTEX_BUILD_DIR}/tests/regression/eladd/kernel.vxbin")
if(EXISTS ${_ELADD_VXBIN})
  install(FILES ${_ELADD_VXBIN}
          DESTINATION ${CMAKE_INSTALL_PREFIX}/kernels
          RENAME eladd.vxbin)
  message(STATUS "Will install eladd kernel: ${_ELADD_VXBIN}")
else()
  message(WARNING "eladd kernel binary not found at ${_ELADD_VXBIN} — "
                  "native aten::add will not work.  Build the eladd test first.")
endif()

set(_ELMUL_VXBIN "${VORTEX_BUILD_DIR}/tests/regression/elmul/kernel.vxbin")
if(EXISTS ${_ELMUL_VXBIN})
  install(FILES ${_ELMUL_VXBIN}
          DESTINATION ${CMAKE_INSTALL_PREFIX}/kernels
          RENAME elmul.vxbin)
  message(STATUS "Will install elmul kernel: ${_ELMUL_VXBIN}")
else()
  message(WARNING "elmul kernel binary not found at ${_ELMUL_VXBIN} — "
                  "native aten::mul will not work.  Build the elmul test first.")
endif()

set(_SOFTMAX_VXBIN "${VORTEX_BUILD_DIR}/tests/regression/softmax/kernel.vxbin")
if(EXISTS ${_SOFTMAX_VXBIN})
  install(FILES ${_SOFTMAX_VXBIN}
          DESTINATION ${CMAKE_INSTALL_PREFIX}/kernels
          RENAME softmax.vxbin)
  message(STATUS "Will install softmax kernel: ${_SOFTMAX_VXBIN}")
else()
  message(WARNING "softmax kernel binary not found at ${_SOFTMAX_VXBIN} — "
                  "native aten::_softmax will not work.  Build the softmax test first.")
endif()

set(_SGEMM_TCU_VXBIN "${VORTEX_BUILD_DIR}/tests/regression/sgemm_tcu/kernel.vxbin")
if(EXISTS ${_SGEMM_TCU_VXBIN})
  install(FILES ${_SGEMM_TCU_VXBIN}
          DESTINATION ${CMAKE_INSTALL_PREFIX}/kernels
          RENAME sgemm_tcu.vxbin)
  message(STATUS "Will install sgemm_tcu kernel: ${_SGEMM_TCU_VXBIN}")
else()
  message(WARNING "sgemm_tcu kernel binary not found at ${_SGEMM_TCU_VXBIN} — "
                  "native aten::mm will not work.  Build the sgemm_tcu test first.")
endif()

set(_SILU_VXBIN "${VORTEX_BUILD_DIR}/tests/regression/silu/kernel.vxbin")
if(EXISTS ${_SILU_VXBIN})
  install(FILES ${_SILU_VXBIN}
          DESTINATION ${CMAKE_INSTALL_PREFIX}/kernels
          RENAME silu.vxbin)
  message(STATUS "Will install silu kernel: ${_SILU_VXBIN}")
else()
  message(WARNING "silu kernel binary not found at ${_SILU_VXBIN} — "
                  "native aten::silu will not work.  Build the silu test first.")
endif()

set(_RMSNORM_VXBIN "${VORTEX_BUILD_DIR}/tests/regression/rmsnorm/kernel.vxbin")
if(EXISTS ${_RMSNORM_VXBIN})
  install(FILES ${_RMSNORM_VXBIN}
          DESTINATION ${CMAKE_INSTALL_PREFIX}/kernels
          RENAME rmsnorm.vxbin)
  message(STATUS "Will install rmsnorm kernel: ${_RMSNORM_VXBIN}")
else()
  message(WARNING "rmsnorm kernel binary not found at ${_RMSNORM_VXBIN} — "
                  "vortex::rms_norm will not work.  Build the rmsnorm test first.")
endif()

set(_ROPE_VXBIN "${VORTEX_BUILD_DIR}/tests/regression/rope/kernel.vxbin")
if(EXISTS ${_ROPE_VXBIN})
  install(FILES ${_ROPE_VXBIN}
          DESTINATION ${CMAKE_INSTALL_PREFIX}/kernels
          RENAME rope.vxbin)
  message(STATUS "Will install rope kernel: ${_ROPE_VXBIN}")
else()
  message(WARNING "rope kernel binary not found at ${_ROPE_VXBIN} — "
                  "vortex::apply_rotary_pos_emb will not work.  Build the rope test first.")
endif()

set(_DROPOUT_VXBIN "${VORTEX_BUILD_DIR}/tests/regression/dropout/kernel.vxbin")
if(EXISTS ${_DROPOUT_VXBIN})
  install(FILES ${_DROPOUT_VXBIN}
          DESTINATION ${CMAKE_INSTALL_PREFIX}/kernels
          RENAME dropout.vxbin)
  message(STATUS "Will install dropout kernel: ${_DROPOUT_VXBIN}")
else()
  message(WARNING "dropout kernel binary not found at ${_DROPOUT_VXBIN} — "
                  "native aten::native_dropout will not work.  Build the dropout test first.")
endif()
