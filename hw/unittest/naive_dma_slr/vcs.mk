compile: setup
	vcs -sverilog -full64 -debug_access+all -timescale=1ns/1ps \
	    +incdir+$(RTL_DIR) $(DEFINES) $(RTLS) \
	    $(SRC_DIR)/tb_naive_dma_slr.sv -top tb_naive_dma_slr -l logs/compile.log
sim: compile
	./simv $(EXTRA_SIM_ARGS) -l logs/sim.log
