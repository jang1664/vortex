compile: $(TB) $(RTLS) Makefile vcs.mk | setup
	vcs \
	-V \
	-kdb \
	-sverilog \
	-full64 \
	-top $(TOP_MODULE) \
	-debug_access+all \
	+ntb_random_seed=1234 \
	-l $(COMPILE_LOG) \
	-timescale=$(TIME_SCALE) \
	+libext+.v+.sv \
	${VC_INCDIRS} \
	$(DEFINES) \
	$(RTLS) \
	$(TB) \
	$(PARAMS)
	@touch $@

run: compile
	@set -eu; \
	if [ -z "$(strip $(EXPECTED_FATAL))" ]; then \
	  ./simv -reportstats $(EXTRA_SIM_ARGS) -l $(SIM_LOG); \
	else \
	  case "$(EXPECTED_FATAL)" in \
	    stale_response) expected="response original tag mismatch" ;; \
	    duplicate_response) expected="duplicate bank response" ;; \
	    unissued_response) expected="response from unissued bank" ;; \
	    free_context_response) expected="response for free context" ;; \
	    *) echo "TEST FAILED: unknown EXPECTED_FATAL=$(EXPECTED_FATAL)" > $(SIM_LOG); exit 2 ;; \
	  esac; \
	  raw_log="logs/expected_$(EXPECTED_FATAL).raw"; \
	  : > "$$raw_log"; \
	  set +e; ./simv -reportstats +NEGATIVE=$(EXPECTED_FATAL) \
	    $(EXTRA_SIM_ARGS) -l "$$raw_log" > /dev/null 2>&1; set -e; \
	  if ! grep -F "VX_tmem_wide_read_switch.sv" "$$raw_log" > /dev/null \
	   || ! grep -F "$$expected" "$$raw_log" > /dev/null; then \
	    echo "TEST FAILED: expected production assertion '$$expected' was not observed; inspect $$raw_log" > $(SIM_LOG); \
	    exit 1; \
	  fi; \
	  echo "TEST PASSED: expected VX_tmem_wide_read_switch assertion $(EXPECTED_FATAL)" > $(SIM_LOG); \
	fi

expected-stale: EXPECTED_FATAL := stale_response
expected-stale: run

expected-duplicate: EXPECTED_FATAL := duplicate_response
expected-duplicate: run

expected-unissued: EXPECTED_FATAL := unissued_response
expected-unissued: run

expected-free: EXPECTED_FATAL := free_context_response
expected-free: run

sim: run
