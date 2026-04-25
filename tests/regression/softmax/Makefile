ROOT_DIR := $(realpath ../../..)
include $(ROOT_DIR)/config.mk

PROJECT      := softmax
BENCH_TARGET := softmax_bench

SRC_DIR := $(VORTEX_HOME)/tests/regression/$(PROJECT)
OPS_DIR := $(VORTEX_HOME)/kernel/src/ops/$(PROJECT)

# Host-side translation units shared by both binaries.
DRIVER_SRCS := $(SRC_DIR)/driver.cpp $(SRC_DIR)/reference.cpp

# `SRCS` drives common.mk's $(PROJECT) rule (the validation binary).
SRCS := $(SRC_DIR)/test_main.cpp $(DRIVER_SRCS)

# Bench binary's source list. bench_harness.cpp is appended below — common.mk
# only injects it into SRCS, not into BENCH_SRCS.
BENCH_SRCS := $(SRC_DIR)/bench_main.cpp $(DRIVER_SRCS)

# Device-side kernel: now lives under kernel/src/ops/<op>/.
VX_SRCS := $(OPS_DIR)/kernel.cpp

# Make softmax_args.h discoverable to host code (driver, both mains).
CXXFLAGS += -I$(OPS_DIR)

include ../common.mk

# common.mk added bench_harness.cpp to SRCS for every regression test. The
# validation binary doesn't actually use it, but the linker GCs unused symbols
# so we leave it. Add it to BENCH_SRCS explicitly here:
BENCH_SRCS += $(BENCH_HARNESS_DIR)/bench_harness.cpp

# Sibling rule mirroring common.mk's `$(PROJECT): $(SRCS)`.
$(BENCH_TARGET): $(BENCH_SRCS)
	$(CXX) $(CXXFLAGS) $^ $(LDFLAGS) -o $@

# Extend the default target so `make all` builds both host binaries.
all: $(BENCH_TARGET)

clean-bench:
	rm -rf $(BENCH_TARGET)

clean: clean-bench
