compile: setup
	vcs -sverilog -full64 -debug_access+all -timescale=$(TIME_SCALE) \
	    $(VC_INCDIRS) $(DEFINES) $(RTLS) $(TB) -top $(TOP_MODULE) \
	    -l $(COMPILE_LOG)

sim: compile
	./simv $(EXTRA_SIM_ARGS) -l $(SIM_LOG)
