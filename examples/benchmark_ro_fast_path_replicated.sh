#!/bin/bash
set -e

# Get the directory where the script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Go to examples directory
cd "$PROJECT_ROOT/examples"

echo "Running TPC-C Benchmark: Read-Only Fast Path Comparison (Replicated)"
echo "Workload: 10% NewOrder, 90% OrderStatus (Read-Only Heavy)"
echo "Runtime: 30 seconds (default)"
echo "-------------------------------------------------------"

run_benchmark() {
    local name=$1
    local extra_args=$2
    
    # Build with appropriate flags
    cd ../build
    if [ "$name" == "fast_path" ]; then
        cmake -DCMAKE_BUILD_TYPE=Release -DENABLE_SINGLE_NODE_WATERMARK=OFF ..
    else
        cmake -DCMAKE_BUILD_TYPE=Release -DENABLE_SINGLE_NODE_WATERMARK=OFF ..
    fi
    make -j12 dbtest
    cd ../examples

    # Generate configs
    echo "Generating configs..."
    cd ..
    bash src/mako/update_config.sh > /dev/null 2>&1
    cd examples

    # Clean up old processes
    pkill -9 -f dbtest || true
    sleep 2

    echo "Running $name..."
    
    # Launch replicas
    # We need 4 processes: localhost (leader), learner, p2, p1
    # Arguments based on bash/shard.sh logic but with extra args
    
    TRD=4
    SHARD=0
    NSHARD=1
    CONFIG_PATH="../src/mako/config"
    PAXOS_CONFIG_PATH="../config/1leader_2followers"
    
    # Common command prefix
    CMD_PREFIX="../build/dbtest --num-threads $TRD --shard-index $SHARD --shard-config $CONFIG_PATH/local-shards$NSHARD-warehouses$TRD.yml -F $PAXOS_CONFIG_PATH/paxos${TRD}_shardidx${SHARD}.yml -F ../config/occ_paxos.yml --is-replicated"

    # Start Learner
    nohup $CMD_PREFIX -P learner > ${name}_learner.log 2>&1 &
    
    # Start Follower 2
    nohup $CMD_PREFIX -P p2 > ${name}_p2.log 2>&1 &
    
    # Start Follower 1
    nohup $CMD_PREFIX -P p1 > ${name}_p1.log 2>&1 &
    
    sleep 2
    
    # Start Leader (localhost) with workload mix
    # Workload mix: 10,0,0,90,0 (10% NewOrder, 90% OrderStatus)
    nohup $CMD_PREFIX -P localhost --workload-mix 10,0,0,90,0 $extra_args > ${name}.log 2>&1 &
    LEADER_PID=$!
    
    echo "Benchmark running with PID $LEADER_PID..."
    
    # Wait for benchmark to finish (approx 30s + startup + loading)
    sleep 70
    
    # Kill processes
    pkill -9 -f dbtest || true
    
    # Parse results for Read-Only transactions (OrderStatus) from Leader log
    if [ -f "${name}.log" ]; then
        local tput=$(grep "OrderStatus_local_throughput:" ${name}.log | awk '{print $2}')
        local lat=$(grep "OrderStatus_local_commit_latency:" ${name}.log | awk '{print $2}')
        
        echo "${name} Results (Read-Only Transactions):"
        echo "  Throughput: $tput ops/sec"
        echo "  Latency:    $lat ms"
    else
        echo "Error: Log file ${name}.log not found."
    fi
}

# Run Fast Path
# Note: Fast path is enabled by default in the code if TXN_FLAG_READ_ONLY is set.
# We control it via the --disable-read-only-snapshots flag we added earlier.
# Wait, we added --disable-read-only-snapshots to dbtest.cc?
# Let's check dbtest.cc to confirm.
# Yes, we added 'd' option for --disable-read-only-snapshots.

run_benchmark "fast_path" ""
run_benchmark "normal_path" "--disable-read-only-snapshots"

echo "-------------------------------------------------------"
echo "Done."
