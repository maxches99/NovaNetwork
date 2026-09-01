#!/usr/bin/env bash
# Runs `swift test` under a silence watchdog and dumps every thread of the test
# binary when it stops producing output.
#
# It exists because the Linux job's only symptom is "cancelled after 30 minutes":
# swift-testing's output is block-buffered through a pipe, so the last line in the
# log is the last line that was flushed, not the line the suite stopped on, and a
# job killed by `timeout-minutes` leaves no stack behind at all. This turns both
# of those into an answer: line-buffered output for the where, and a backtrace of
# every thread for the why.
set -uo pipefail

silence_limit="${SILENCE_LIMIT:-180}"
log="${LOG_FILE:-probe.log}"

# For the fallback path below, and in case the process dies rather than hangs.
export SWIFT_BACKTRACE=enable=yes,threads=all,interactive=no,color=no,cache=no

: > "$log"

stdbuf -oL -eL swift test "$@" 2>&1 \
  | stdbuf -oL awk '{ printf "%s %s\n", strftime("%H:%M:%S"), $0; fflush() }' \
  | tee -a "$log" &
pipeline_pid=$!

test_pids() {
    pgrep -f 'PackageTests\.xctest' || true
}

dump_stacks() {
    local found=0
    for pid in $(test_pids); do
        found=1
        echo "--- pid $pid ---"
        grep -E '^(Name|State|Threads)' "/proc/$pid/status" || true

        echo "--- thread apply all bt ---"
        # The status has to come from gdb rather than from the pipeline, which
        # reports `head`, which always succeeds.
        gdb -p "$pid" -batch \
            -ex 'set pagination off' \
            -ex 'thread apply all bt' > "gdb-$pid.txt" 2>&1
        gdb_status=$?
        head -600 "gdb-$pid.txt"
        if [ "$gdb_status" -ne 0 ] || grep -q 'Could not attach' "gdb-$pid.txt"; then
            # No ptrace, or no gdb. SIGABRT is in the Swift backtracer's signal
            # set, so the runtime prints the stacks on its way out instead.
            echo "--- gdb could not attach, falling back to SIGABRT ---"
            kill -ABRT "$pid" || true
            sleep 25
        fi
    done
    [ "$found" = 1 ] || echo "no PackageTests.xctest process found"
}

while kill -0 "$pipeline_pid" 2>/dev/null; do
    sleep 5
    if [ $(( $(date +%s) - $(stat -c %Y "$log") )) -gt "$silence_limit" ]; then
        echo "=== no output for ${silence_limit}s ==="
        echo "=== last 40 lines before the stall ==="
        tail -40 "$log"
        dump_stacks
        pkill -f 'PackageTests\.xctest' || true
        exit 1
    fi
done

wait "$pipeline_pid"
