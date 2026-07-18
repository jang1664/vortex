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

# ---- Build PyTorch-compatible Vortex kernel variants ----
# The PyTorch host launch contracts currently require contiguous softmax rows
# and row-major SGEMM weights. Build those exact variants before installation
# instead of copying whichever kernel.vxbin was last produced by regression.
find_program(VORTEX_MAKE_EXECUTABLE NAMES gmake make)
if(NOT VORTEX_MAKE_EXECUTABLE)
  message(FATAL_ERROR "GNU Make is required to build Vortex kernels")
endif()

set(VORTEX_PYTORCH_SOFTMAX_VARIANT "rev1")
set(VORTEX_PYTORCH_SGEMM_TCU_VARIANT "baseline")
set(_SOFTMAX_BUILD_DIR "${VORTEX_BUILD_DIR}/tests/regression/softmax")
set(_SGEMM_TCU_BUILD_DIR "${VORTEX_BUILD_DIR}/tests/regression/sgemm_tcu")
set(_SOFTMAX_VXBIN "${_SOFTMAX_BUILD_DIR}/kernel.vxbin")
set(_SGEMM_TCU_VXBIN "${_SGEMM_TCU_BUILD_DIR}/kernel.vxbin")

foreach(_kernel_build_dir IN ITEMS "${_SOFTMAX_BUILD_DIR}" "${_SGEMM_TCU_BUILD_DIR}")
  if(NOT EXISTS "${_kernel_build_dir}/Makefile")
    message(FATAL_ERROR
      "Missing configured Vortex regression build directory: ${_kernel_build_dir}")
  endif()
endforeach()

add_custom_target(vortex_pytorch_kernels ALL
  COMMAND "${CMAKE_COMMAND}" -E env "MAKEFLAGS="
          "${VORTEX_MAKE_EXECUTABLE}" -C "${_SOFTMAX_BUILD_DIR}"
          "SOFTMAX_VARIANT=${VORTEX_PYTORCH_SOFTMAX_VARIANT}" kernel.vxbin
  COMMAND "${CMAKE_COMMAND}" -E env "MAKEFLAGS="
          "${VORTEX_MAKE_EXECUTABLE}" -C "${_SGEMM_TCU_BUILD_DIR}"
          "SGEMM_TCU_VARIANT=${VORTEX_PYTORCH_SGEMM_TCU_VARIANT}" kernel.vxbin
  BYPRODUCTS "${_SOFTMAX_VXBIN}" "${_SGEMM_TCU_VXBIN}"
  COMMENT "Building PyTorch-compatible Vortex kernels"
  VERBATIM
  USES_TERMINAL
)

# SpinQuant single-layer accuracy uses decomposed kernels so every physical
# layout boundary can be captured independently. Build and package the exact
# set here instead of depending on stale regression artifacts in a build tree.
set(_SPINQUANT_LAYER_KERNELS
    eladd
    elmul
    silu
    rmsnorm
    rope
    hadamard_base
    hadamard_k
    quantize_pt_int4
    head_concat
    qk_asym_correction
    tile_input_a
    tile_weight_w4a16
    tile_scale_zp_w4a16
    detile_output
    fpint_gemm_ffn_hw)

add_custom_target(vortex_spinquant_layer_kernels ALL
  COMMAND "${CMAKE_COMMAND}" -E echo "Building SpinQuant layer-accuracy kernels"
  COMMENT "Building SpinQuant layer-accuracy Vortex kernels"
  VERBATIM
  USES_TERMINAL)

foreach(_kernel_name IN LISTS _SPINQUANT_LAYER_KERNELS)
  set(_kernel_build_dir "${VORTEX_BUILD_DIR}/tests/regression/${_kernel_name}")
  if(NOT EXISTS "${_kernel_build_dir}/Makefile")
    message(FATAL_ERROR
      "Missing configured SpinQuant regression build directory: ${_kernel_build_dir}")
  endif()
  add_custom_command(TARGET vortex_spinquant_layer_kernels POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E env "MAKEFLAGS="
            "${VORTEX_MAKE_EXECUTABLE}" -C "${_kernel_build_dir}" kernel.vxbin
    VERBATIM)
  install(FILES "${_kernel_build_dir}/kernel.vxbin"
          DESTINATION ${CMAKE_INSTALL_PREFIX}/kernels
          RENAME "${_kernel_name}.vxbin")
endforeach()

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

set(_ELSUB_VXBIN "${VORTEX_BUILD_DIR}/tests/regression/elsub/kernel.vxbin")
if(EXISTS ${_ELSUB_VXBIN})
  install(FILES ${_ELSUB_VXBIN}
          DESTINATION ${CMAKE_INSTALL_PREFIX}/kernels
          RENAME elsub.vxbin)
  message(STATUS "Will install elsub kernel: ${_ELSUB_VXBIN}")
else()
  message(WARNING "elsub kernel binary not found at ${_ELSUB_VXBIN} — "
                  "native aten::sub will not work.  Build the elsub test first.")
endif()

set(_ELDIV_VXBIN "${VORTEX_BUILD_DIR}/tests/regression/eldiv/kernel.vxbin")
if(EXISTS ${_ELDIV_VXBIN})
  install(FILES ${_ELDIV_VXBIN}
          DESTINATION ${CMAKE_INSTALL_PREFIX}/kernels
          RENAME eldiv.vxbin)
  message(STATUS "Will install eldiv kernel: ${_ELDIV_VXBIN}")
else()
  message(WARNING "eldiv kernel binary not found at ${_ELDIV_VXBIN} — "
                  "native aten::div will not work.  Build the eldiv test first.")
endif()

set(_ELUNARY_VXBIN "${VORTEX_BUILD_DIR}/tests/regression/elunary/kernel.vxbin")
if(EXISTS ${_ELUNARY_VXBIN})
  install(FILES ${_ELUNARY_VXBIN}
          DESTINATION ${CMAKE_INSTALL_PREFIX}/kernels
          RENAME elunary.vxbin)
  message(STATUS "Will install elunary kernel: ${_ELUNARY_VXBIN}")
else()
  message(WARNING "elunary kernel binary not found at ${_ELUNARY_VXBIN} — "
                  "native aten::sin/cos/rsqrt/etc will not work.  Build the elunary test first.")
endif()

set(_ELSCALAR_VXBIN "${VORTEX_BUILD_DIR}/tests/regression/elscalar/kernel.vxbin")
if(EXISTS ${_ELSCALAR_VXBIN})
  install(FILES ${_ELSCALAR_VXBIN}
          DESTINATION ${CMAKE_INSTALL_PREFIX}/kernels
          RENAME elscalar.vxbin)
  message(STATUS "Will install elscalar kernel: ${_ELSCALAR_VXBIN}")
else()
  message(WARNING "elscalar kernel binary not found at ${_ELSCALAR_VXBIN} — "
                  "native aten::pow will not work.  Build the elscalar test first.")
endif()

set(_ELREDUCE_VXBIN "${VORTEX_BUILD_DIR}/tests/regression/elreduce/kernel.vxbin")
if(EXISTS ${_ELREDUCE_VXBIN})
  install(FILES ${_ELREDUCE_VXBIN}
          DESTINATION ${CMAKE_INSTALL_PREFIX}/kernels
          RENAME elreduce.vxbin)
  message(STATUS "Will install elreduce kernel: ${_ELREDUCE_VXBIN}")
else()
  message(WARNING "elreduce kernel binary not found at ${_ELREDUCE_VXBIN} — "
                  "native aten::mean will not work.  Build the elreduce test first.")
endif()

install(FILES ${_SOFTMAX_VXBIN}
        DESTINATION ${CMAKE_INSTALL_PREFIX}/kernels
        RENAME softmax.vxbin)
message(STATUS
  "Will build and install softmax kernel variant ${VORTEX_PYTORCH_SOFTMAX_VARIANT}: "
  "${_SOFTMAX_VXBIN}")

install(FILES ${_SGEMM_TCU_VXBIN}
        DESTINATION ${CMAKE_INSTALL_PREFIX}/kernels
        RENAME sgemm_tcu.vxbin)
message(STATUS
  "Will build and install sgemm_tcu kernel variant ${VORTEX_PYTORCH_SGEMM_TCU_VARIANT}: "
  "${_SGEMM_TCU_VXBIN}")

set(_FPINT_GEMM_FFN_HW_VXBIN "${VORTEX_BUILD_DIR}/tests/regression/fpint_gemm_ffn_hw/kernel.vxbin")
if(EXISTS ${_FPINT_GEMM_FFN_HW_VXBIN})
  install(FILES ${_FPINT_GEMM_FFN_HW_VXBIN}
          DESTINATION ${CMAKE_INSTALL_PREFIX}/kernels
          RENAME fpint_gemm_ffn_hw.vxbin)
  message(STATUS "Will install fpint_gemm_ffn_hw kernel: ${_FPINT_GEMM_FFN_HW_VXBIN}")
else()
  message(WARNING "fpint_gemm_ffn_hw kernel binary not found at ${_FPINT_GEMM_FFN_HW_VXBIN} -- "
                  "vortex::mm_w4a16_opt will not work.  Build the fpint_gemm_ffn_hw test first.")
endif()

set(_FPINT_GEMM_FFN_HW_NAIVE_VXBIN "${VORTEX_BUILD_DIR}/tests/regression/fpint_gemm_ffn_hw_naive/kernel.vxbin")
if(EXISTS ${_FPINT_GEMM_FFN_HW_NAIVE_VXBIN})
  install(FILES ${_FPINT_GEMM_FFN_HW_NAIVE_VXBIN}
          DESTINATION ${CMAKE_INSTALL_PREFIX}/kernels
          RENAME fpint_gemm_ffn_hw_naive.vxbin)
  message(STATUS "Will install fpint_gemm_ffn_hw_naive kernel: ${_FPINT_GEMM_FFN_HW_NAIVE_VXBIN}")
else()
  message(WARNING "fpint_gemm_ffn_hw_naive kernel binary not found at ${_FPINT_GEMM_FFN_HW_NAIVE_VXBIN} -- "
                  "vortex::mm_w4a16 will not work.  Build the fpint_gemm_ffn_hw_naive test first.")
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
