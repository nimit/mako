#!/bin/bash

# Script to test Read-Only Fast Path with Replication
# Launches 3 processes: Leader (shard 0), Follower 1, Follower 2 (Learner)

echo "========================================="
echo "Testing Read-Only Fast Path with Replication"
echo "========================================="

trd=1
script_name="$(basename "$0")"
ps aux | grep -i test_ro_fast_path_rep | grep -v test_ro_fast_path_rep.sh | awk "{print \$2}" | xargs kill -9 2>/dev/null
# Clean up old log files
rm -f ro_rep_*.log
rm -rf /tmp/mako_rocksdb_shard*

# Start processes in background
echo "Starting Learner (Follower 3)..."
nohup ./build/test_ro_fast_path_rep 1 0 $trd learner 1 > ro_rep_learner.log 2>&1 &
PID_LEARNER=$!
sleep 1

echo "Starting Follower 2 (p2)..."
nohup ./build/test_ro_fast_path_rep 1 0 $trd p2 1 > ro_rep_p2.log 2>&1 &
PID_P2=$!
sleep 1

echo "Starting Follower 1 (p1)..."
nohup ./build/test_ro_fast_path_rep 1 0 $trd p1 1 > ro_rep_p1.log 2>&1 &
PID_P1=$!
sleep 1

echo "Starting Leader (localhost)..."
nohup ./build/test_ro_fast_path_rep 1 0 $trd localhost 1 > ro_rep_leader.log 2>&1 &
PID_LEADER=$!

# Wait for leader to finish (it runs the test logic)
# The followers just wait, so we'll kill them after leader finishes
echo "Waiting for Leader to complete..."
wait $PID_LEADER

echo "Leader finished. Stopping followers..."
kill $PID_LEARNER 2>/dev/null
kill $PID_P2 2>/dev/null
kill $PID_P1 2>/dev/null

echo ""
echo "========================================="
echo "Checking test results..."
echo "========================================="

failed=0
log="ro_rep_leader.log"

if [ ! -f "$log" ]; then
    echo "  ✗ Log file $log not found"
    failed=1
else
    # Check for success messages
    if grep -q "RO Read V1: SUCCESS" "$log"; then
        echo "  ✓ Found 'RO Read V1: SUCCESS'"
    else
        echo "  ✗ 'RO Read V1: SUCCESS' not found"
        failed=1
    fi

    if grep -q "RO Read V2: SUCCESS" "$log"; then
        echo "  ✓ Found 'RO Read V2: SUCCESS'"
    else
        echo "  ✗ 'RO Read V2: SUCCESS' not found"
        failed=1
    fi
fi

if [ $failed -eq 0 ]; then
    echo "All checks passed!"
    exit 0
else
    echo "Checks failed!"
    echo "Last 20 lines of $log:"
    tail -n 20 $log
    exit 1
fi
