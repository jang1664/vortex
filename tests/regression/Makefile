ROOT_DIR := $(realpath ../..)
include $(ROOT_DIR)/config.mk

TEST_DIRS := \
	addrgen \
	basic \
	conv3 \
	cta \
	dequant_hbm_energy \
	dequantize_pt_int4 \
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
	embedding \
	fence

ifneq (,$(findstring -DEXT_ZFH_ENABLE,$(CONFIGS)))
TEST_DIRS += \
	fp16_quant_debug \
	fp16_zfh
endif

ifneq (,$(findstring -DENABLE_GEMM_ACCEL,$(CONFIGS)))
ifeq (,$(findstring -DGEMM_NAIVE,$(CONFIGS)))
TEST_DIRS += \
	flash_attn \
	fpint_gemm_eladd_fused_hw
endif
endif

TEST_DIRS += \
	fpint_gemm_ffn_hw \
	fpint_gemm_ffn_hw_naive \
	fpu_format_switch_debug \
	gemm_fpint \
	hadamard \
	hadamard_base \
	hadamard_k \
	hadamard_layout_fused \
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
	qk_asym_correction \
	quantize_pt_int4 \
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

run-simx-softmax-rev2-pair:
	$(MAKE) -C softmax run-simx SOFTMAX_VARIANT=rev2 \
		OPTS="-batch 1 -heads 1 -seqq 2 -seqk 32 -mask 0 -scale 1.0"
	$(MAKE) -C softmax_layout_fused run-simx SOFTMAX_LAYOUT_FUSED_VARIANT=rev2 \
		OPTS="-batch 1 -heads 1 -seqq 2 -seqk 32 -mask 0 -scale 1.0"
	$(MAKE) -C softmax run-simx SOFTMAX_VARIANT=rev2 \
		OPTS="-batch 1 -heads 1 -seqq 3 -seqk 33 -seqk-stride 40 -mask 1 -scale 1.0"
	$(MAKE) -C softmax_layout_fused run-simx SOFTMAX_LAYOUT_FUSED_VARIANT=rev2 \
		OPTS="-batch 1 -heads 1 -seqq 3 -seqk 33 -seqk-stride 40 -mask 1 -scale 1.0"

run-rtlsim:
	@for t in $(TEST_DIRS); do \
		$(MAKE) -C $$t run-rtlsim || exit $$?; \
	done

clean:
	@for t in $(TEST_DIRS); do \
		$(MAKE) -C $$t clean || exit $$?; \
	done

.PHONY: all run-simx run-simx-softmax-rev2-pair run-rtlsim clean
