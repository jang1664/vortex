ROOT_DIR := $(realpath ../..)
include $(ROOT_DIR)/config.mk

TEST_DIRS := \
	basic \
	conv3 \
	cta \
	demo \
	diverge \
	dogfood \
	dotproduct \
	dropout \
	eladd \
	eldiv \
	elmul \
	elreduce \
	elscalar \
	elsub \
	elunary \
	fence \
	gemm_fpint \
	io_addr \
	madmax \
	mstress \
	o3stress \
	printf \
	relu \
	rmsnorm \
	rope \
	sgemm \
	sgemm2 \
	sgemm_tcu \
	sgemv \
	silu \
	softmax \
	sort \
	stencil3d \
	vecadd \
	vecadd_multi_invoke

all:
	@for t in $(TEST_DIRS); do \
		$(MAKE) -C $$t || exit $$?; \
	done

run-simx:
	@for t in $(TEST_DIRS); do \
		$(MAKE) -C $$t run-simx || exit $$?; \
	done

run-rtlsim:
	@for t in $(TEST_DIRS); do \
		$(MAKE) -C $$t run-rtlsim || exit $$?; \
	done

clean:
	@for t in $(TEST_DIRS); do \
		$(MAKE) -C $$t clean || exit $$?; \
	done
