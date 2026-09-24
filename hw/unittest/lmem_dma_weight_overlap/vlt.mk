lint: setup
	verilator -Wall --lint-only --timing -Wno-fatal \
		$(VL_INCDIRS) \
		$(DEFINES) \
		--top-module $(TOP_MODULE) \
		$(RTLS) \
		$(TB) \
		$(PARAMS) \
		2>&1 | tee logs/lint.log
