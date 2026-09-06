compile: setup
	vcs -sverilog -full64 -debug_access+all -timescale=1ns/1ps \
	    +incdir+$(RTL_DIR) $(DEFINES) $(RTLS) \
	    $(SRC_DIR)/tb_slr_mem_bus.sv -top tb_slr_mem_bus -l logs/compile.log
sim: compile
	./simv $(EXTRA_SIM_ARGS) -l logs/sim.log
