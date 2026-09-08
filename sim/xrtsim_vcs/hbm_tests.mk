# Standalone tests run from the same configured build as the VCS integration.
HBM_TEST_NAMES := hbm_clock hbm_dram hbm_model hbm_transfer hbm_replay hbm_topology hbm_write_response
HBM_TEST_BINS := $(addprefix $(DESTDIR)/test_,$(HBM_TEST_NAMES))
HBM_TEST_COMMON := $(SRC_DIR)/hbm_model.cpp $(SW_COMMON_DIR)/dram_sim.cpp $(SW_COMMON_DIR)/mem.cpp $(SW_COMMON_DIR)/util.cpp
HBM_TEST_HEADERS := $(SRC_DIR)/hbm_model.h $(SRC_DIR)/hbm_clock.h $(SRC_DIR)/hbm_transfer.h $(SRC_DIR)/vcs_protocol.h $(SW_COMMON_DIR)/dram_sim.h $(SW_COMMON_DIR)/mem.h

.PHONY: hbm-tests
.PHONY: hbm-vcs-transport-tests
hbm-vcs-transport-tests: simv
	python3 $(SRC_DIR)/test_hbm_vcs_transport.py --simv $(DESTDIR)/simv --manifest $(DESTDIR)/u55c_model_manifest.json --output-dir $(DESTDIR)/hbm-vcs-transport-tests
.PHONY: hbm-adapter-build
.PHONY: hbm-adapter-tests
hbm-adapter-tests:
	python3 $(SRC_DIR)/test_hbm_adapter.py --output-dir $(DESTDIR)/hbm-adapter-tests
hbm-adapter-build: $(DESTDIR)/u55c_model_config.h $(DESTDIR)/u55c_model_config.svh
	@mkdir -p $(DESTDIR)/hbm-adapter-tests
	cd $(DESTDIR)/hbm-adapter-tests && vcs -full64 -sverilog -timescale=1ns/1ps \
		$(VCS_CONFIGS) $(VCS_DEFINES) +define+HBM_AXI_SELFTEST \
		$(foreach d,$(RTL_DIRS),+incdir+$(d)) \
		$(if $(FSDB_DUMP),+define+FSDB_DUMP -debug_access+all $(VCS_FSDB_OPTS)) \
		-CFLAGS "$(VCS_CPPFLAGS)" \
		-LDFLAGS "-Wl,--whole-archive $(SOFTFLOAT_LIB) -Wl,--no-whole-archive -Wl,-rpath,$(THIRD_PARTY_DIR)/ramulator -L$(THIRD_PARTY_DIR)/ramulator -lramulator -pthread" \
		$(SRC_DIR)/tb_vcs_xrtsim.sv $(SRC_DIR)/VX_hbm_axi_guard.sv $(DPI_SRCS) \
		-top tb_vcs_xrtsim -o simv > compile.log 2>&1
.PHONY: hbm-axi-tests
hbm-axi-tests:
	python3 $(SRC_DIR)/test_hbm_axi_guard.py --output-dir $(DESTDIR)/hbm-axi-tests
hbm-tests: $(HBM_TEST_BINS)
	python3 $(SRC_DIR)/test_hbm_config.py -v
	@set -e; for test in $(HBM_TEST_BINS); do "$$test"; done

$(HBM_TEST_BINS): $(DESTDIR)/test_%: $(SRC_DIR)/test_%.cpp $(HBM_TEST_COMMON) $(HBM_TEST_HEADERS) $(DESTDIR)/u55c_model_config.h $(THIRD_PARTY_DIR)/ramulator/libramulator.so
	/usr/bin/g++ $(CXXFLAGS) -UNDEBUG -pthread $< $(HBM_TEST_COMMON) -L$(THIRD_PARTY_DIR)/ramulator -Wl,-rpath,$(THIRD_PARTY_DIR)/ramulator -lramulator -o $@
