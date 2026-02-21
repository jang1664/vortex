#--debug --gdbbt
compile: setup
	verilator -Wall --binary --trace-fst -Wno-fatal \
		-MAKEFLAGS "CXX=$(CXX) CC=$(CC)" \
		${VL_INCDIRS} \
		$(DEFINES) \
		-CFLAGS $(CFLAGS) \
		--top-module $(TOP_MODULE) \
		$(RTLS) \
		$(TB) \
		$(DPI_SRCS) \
		$(SOFTFLOAT_LIB) \
		$(PARAMS) \
		2>&1 | tee $(COMPILE_LOG)

run:
	./obj_dir/V$(TOP_MODULE) $(SIM_ARGS) 2>&1 | tee $(SIM_LOG)

sim: compile run
