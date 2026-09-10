.PHONY: compile sim
compile: $(TB) $(RTLS) | setup
	vcs -sverilog -full64 -top $(TOP_MODULE) -timescale=1ns/1ps \
		$(foreach dir,$(INCDIRS),+incdir+$(dir)) $(DEFINES) $(EXTRA_DEFINES) \
		-y $(RTL_DIR)/libs +libext+.sv $(RTLS) $(TB) -o $(SIMV) -l $(COMPILE_LOG)

sim: compile
	./$(SIMV) $(EXTRA_SIM_ARGS) -l logs/sim.log
