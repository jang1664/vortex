compile: setup
	bash -o pipefail -c 'verilator -Wall --binary --trace-fst -Wno-fatal -Wno-TIMESCALEMOD \
		-MAKEFLAGS "CXX=$(CXX) CC=$(CC)" \
		${VL_INCDIRS} \
		$(DEFINES) \
		--top-module $(TOP_MODULE) \
		$(RTLS) \
		$(TB) \
		$(PARAMS) \
		2>&1 | tee $(COMPILE_LOG)'

sim: compile
	bash -o pipefail -c './obj_dir/V$(TOP_MODULE) 2>&1 | tee $(SIM_LOG)'
