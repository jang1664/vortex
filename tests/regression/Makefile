ROOT_DIR := $(realpath ../..)
include $(ROOT_DIR)/config.mk

TEST_DIRS := \
	basic \
	conv3 \
	cta \
	demo \
	detile_output \
	diverge \
	dogfood \
	dotproduct \
	dropout \
	eladd \
	eladd_layout_fused \
	eldiv \
	elmul \
	elmul_layout_fused \
	elreduce \
	elscalar \
	elsub \
	elunary \
	fence \
	fpint_gemm_ffn_hw \
	fpint_gemm_ffn_hw_naive \
	gemm_fpint \
	hadamard \
	head_concat \
	head_concat_layout_fused \
	io_addr \
	kv_cache_dequant_w4a16 \
	kv_cache_quant_layout_fused_w4a16 \
	kv_cache_quant_w4a16 \
	madmax \
	mmio_burst_proto \
	mstress \
	printf \
	relu \
	rms_norm_layout_fused \
	rmsnorm \
	rope \
	rope_layout_fused \
	sgemm \
	sgemm2 \
	sgemm_tcu \
	sgemv \
	silu \
	silu_layout_fused \
	softmax \
	softmax_layout_fused \
	sort \
	stencil3d \
	tile_input_a \
	tile_scale_zp_w4a16 \
	tile_weight_w4a16 \
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
