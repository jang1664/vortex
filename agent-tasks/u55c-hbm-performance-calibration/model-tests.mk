# Supplemental native-model tests. Invoke from a configured build/sim/xrtsim_vcs.
# This file does not compile archived hardware RTL and edits no existing Makefile.
include ../../../sim/xrtsim_vcs/Makefile

CALIBRATION_TEST_NAMES := hbm_service_budget u55c_address hbm_performance_probe hbm_read_bandwidth hbm_mixed_bandwidth
CALIBRATION_TEST_BINS := $(addprefix $(DESTDIR)/test_,$(CALIBRATION_TEST_NAMES))
CALIBRATION_HEADERS := $(SRC_DIR)/hbm_service_budget.h $(SW_COMMON_DIR)/u55c_address.h

$(HBM_TEST_BINS) $(CALIBRATION_TEST_BINS): $(CALIBRATION_HEADERS)

$(CALIBRATION_TEST_BINS): $(DESTDIR)/test_%: $(SRC_DIR)/test_%.cpp $(HBM_TEST_COMMON) $(HBM_TEST_HEADERS) $(DESTDIR)/u55c_model_config.h $(THIRD_PARTY_DIR)/ramulator/libramulator.so
	/usr/bin/g++ $(CXXFLAGS) -UNDEBUG -pthread $< $(HBM_TEST_COMMON) -L$(THIRD_PARTY_DIR)/ramulator -Wl,-rpath,$(THIRD_PARTY_DIR)/ramulator -lramulator -o $@

.PHONY: calibration-native-tests
calibration-native-tests: $(CALIBRATION_TEST_BINS)
	python3 $(SRC_DIR)/test_hbm_performance_profile.py -v
	@set -e; for test in $(CALIBRATION_TEST_BINS); do "$$test"; done
