#!/usr/bin/env bash
# Starts `swift test` and, once the test binary has been alive for GRACE seconds
# without exiting, dumps every one of its threads.
#
# It exists because the Linux job's only symptom is "cancelled after 30 minutes",
# which leaves no stack behind. An earlier version of this watched the log for
# silence instead, and that does not work: swift-testing's output reaches the
# pipe a block at a time, so a compile is indistinguishable from a hang.
# Elapsed time against a test that should take under a second is the honest
# signal, so that is what this waits on.
set -uo pipefail

grace="${GRACE:-90}"
log="${LOG_FILE:-probe.log}"

export SWIFT_BACKTRACE=enable=yes,threads=all,interactive=no,color=no,cache=no

: > "$log"

swift test "$@" > "$log" 2>&1 &
swift_pid=$!

test_pids() { pgrep -f 'PackageTests\.xctest' || true; }

# Wait for the test binary itself: everything before it is compilation.
for _ in $(seq 1 240); do
    [ -n "$(test_pids)" ] && break
    kill -0 "$swift_pid" 2>/dev/null || break
    sleep 1
done

started_at=$(date +%s)
while [ -n "$(test_pids)" ]; do
    if [ $(( $(date +%s) - started_at )) -gt "$grace" ]; then
        echo "=== test binary still alive after ${grace}s ==="
        echo "=== tail of its output ==="
        tail -40 "$log"
        for pid in $(test_pids); do
            echo "--- pid $pid ---"
            grep -E '^(Name|State|Threads)' "/proc/$pid/status" || true
            echo "--- thread apply all bt ---"
            # The status has to come from gdb, not from a pipeline ending in
            # `head`, which always succeeds.
            gdb -p "$pid" -batch \
                -ex 'set pagination off' \
                -ex 'thread apply all bt' > "gdb-$pid.txt" 2>&1
            gdb_status=$?
            head -600 "gdb-$pid.txt"
            if [ "$gdb_status" -ne 0 ] || grep -q 'Could not attach' "gdb-$pid.txt"; then
                echo "--- gdb could not attach, falling back to SIGABRT ---"
                kill -ABRT "$pid" || true
                sleep 25
                tail -200 "$log"
            fi
        done
        pkill -f 'PackageTests\.xctest' || true
        exit 1
    fi
    sleep 2
done

wait "$swift_pid"
status=$?
cat "$log"
exit "$status"
