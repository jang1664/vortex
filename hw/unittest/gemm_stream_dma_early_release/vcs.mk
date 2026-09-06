compile: setup
	vcs -sverilog -full64 -debug_access+all -timescale=1ns/1ps \
	    +incdir+$(RTL_DIR) $(DEFINES) $(RTLS) \
	    $(SRC_DIR)/tb_gemm_stream_dma_early_release.sv \
	    -top tb_gemm_stream_dma_early_release -l logs/compile.log
sim: compile
	./simv -l logs/sim.log
