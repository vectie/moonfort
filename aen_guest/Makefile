CC ?= cc
CFLAGS ?= -O2 -pipe
CPPFLAGS ?=
BUILD_DIR ?= ../_build/aen-guest/bin
COMMON_FLAGS = -std=c11 -D_GNU_SOURCE -Wall -Wextra -Werror -Wpedantic -fstack-protector-strong -D_FORTIFY_SOURCE=2
LDFLAGS ?= -static -Wl,-z,relro,-z,now

.PHONY: all probes clean
all: $(BUILD_DIR)/guest_attester $(BUILD_DIR)/guest_supervisor

probes:
	@test -n "$(PROBE_IPV4)" -a -n "$(PROBE_PORT)" -a -n "$(PROBE_EXPECTED)" || { echo "PROBE_IPV4, PROBE_PORT, and PROBE_EXPECTED are required" >&2; exit 64; }
	../scripts/build-aen-canary-probes.sh "$(PROBE_IPV4)" "$(PROBE_PORT)" "$(PROBE_EXPECTED)" "$(BUILD_DIR)"

$(BUILD_DIR):
	mkdir -p $@

$(BUILD_DIR)/guest_attester: runtime.c runtime.h guest_attester.c | $(BUILD_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(COMMON_FLAGS) runtime.c guest_attester.c $(LDFLAGS) -o $@

$(BUILD_DIR)/guest_supervisor: runtime.c runtime.h guest_supervisor.c | $(BUILD_DIR)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(COMMON_FLAGS) runtime.c guest_supervisor.c $(LDFLAGS) -o $@

clean:
	rm -f $(BUILD_DIR)/guest_attester $(BUILD_DIR)/guest_supervisor $(BUILD_DIR)/network-proof $(BUILD_DIR)/symlink-proof
