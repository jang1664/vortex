compile: setup
	vcs \
		-V \
		-kdb \
		-sverilog \
		-full64 \
		-debug_access+all \
		-top $(TOP_MODULE) \
		-l $(COMPILE_LOG) \
		-timescale=$(TIME_SCALE) \
		+libext+.v+ \
		$(VC_INCDIRS) \
		$(DEFINES) \
		$(RTLS) \
		$(TB)

sim: compile
	./simv -reportstats -l $(SIM_LOG)

invalid_case: setup
	vcs \
		-sverilog \
		-full64 \
		-top $(INVALID_TOP_MODULE) \
		-o simv_invalid_$(INVALID_NAME) \
		-l logs/compile_invalid_$(INVALID_NAME).log \
		-timescale=$(TIME_SCALE) \
		+libext+.v+ \
		$(VC_INCDIRS) \
		$(DEFINES) \
		-pvalue+$(INVALID_TOP_MODULE).IN_BYTES=$(INVALID_IN_BYTES) \
		-pvalue+$(INVALID_TOP_MODULE).OUT_BYTES=$(INVALID_OUT_BYTES) \
		$(RTLS) \
		$(INVALID_TB)
	-./simv_invalid_$(INVALID_NAME) -l logs/sim_invalid_$(INVALID_NAME).log
	grep -q "gearbox widths must" logs/sim_invalid_$(INVALID_NAME).log
	@echo "PASS: invalid parameter case $(INVALID_NAME) was rejected"

.PHONY: compile sim invalid_case
