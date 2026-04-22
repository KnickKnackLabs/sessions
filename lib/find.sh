#!/usr/bin/env bash
# Back-compat shim for session lookup.
#
# Pre-multi-harness, this file owned the find_session_file function.
# It now delegates to the pi harness adapter. Left in place so anything
# (tests, ad-hoc scripts) that sources `lib/find.sh` keeps working while
# we migrate to the adapter-aware `lib/harness/*.sh` layout.
#
# Step 2 (sessions#50) will replace this with a dispatcher that picks
# the right harness adapter at call time.

# shellcheck source=/dev/null
source "$MISE_CONFIG_ROOT/lib/harness/pi.sh"

find_session_file() {
  harness_pi_find_session "$@"
}
