compile: setup
	verilator -Wall --binary --trace-fst -Wno-fatal \
		-Wno-DECLFILENAME -Wno-BLKSEQ \
		-MAKEFLAGS "CXX=$(CXX) CC=$(CC)" \
		--Mdir $(BUILD_DIR)/obj_dir \
		$(VL_INCDIRS) \
		$(DEFINES) \
		--top-module $(TOP_MODULE) \
		$(RTLS) \
		$(TB) \
		$(PARAMS) \
		2>&1 | tee $(COMPILE_LOG)

run: compile
	$(BUILD_DIR)/obj_dir/V$(TOP_MODULE) 2>&1 | tee $(SIM_LOG)
