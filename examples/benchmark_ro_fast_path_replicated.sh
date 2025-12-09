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
    local enable_fast_path=$2
    
    echo "Building for $name..."
    # Build with appropriate flags
    cd ../build
    if [ "$enable_fast_path" == "ON" ]; then
        cmake -DCMAKE_BUILD_TYPE=Release -DENABLE_RO_FAST_PATH=ON -DENABLE_SINGLE_NODE_WATERMARK=OFF ..
    else
        cmake -DCMAKE_BUILD_TYPE=Release -DENABLE_RO_FAST_PATH=OFF -DENABLE_SINGLE_NODE_WATERMARK=OFF ..
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
    
    TRD=4
    SHARD=0
    NSHARD=1
    CONFIG_PATH="../src/mako/config"
    PAXOS_CONFIG_PATH="../config/1leader_2followers"
    
    # Common command prefix
    # 1 warehouse each
    # CMD_PREFIX="../build/dbtest --num-threads $TRD --shard-index $SHARD --shard-config $CONFIG_PATH/local-shards$NSHARD-warehouses$TRD.yml -F $PAXOS_CONFIG_PATH/paxos${TRD}_shardidx${SHARD}.yml -F ../config/occ_paxos.yml --is-replicated"
    # 1 warehouse total
    CMD_PREFIX="../build/dbtest --num-threads $TRD --shard-index $SHARD --shard-config $CONFIG_PATH/local-shards$NSHARD-warehouses1.yml -F $PAXOS_CONFIG_PATH/paxos${TRD}_shardidx${SHARD}.yml -F ../config/occ_paxos.yml --is-replicated"


    # Start Learner
    nohup $CMD_PREFIX -P learner > ${name}_learner.log 2>&1 &
    
    # Start Follower 2
    nohup $CMD_PREFIX -P p2 --allow-follower-workload --workload-mix 0,0,0,100,0 > ${name}_p2.log 2>&1 &
    
    # Start Follower 1
    nohup $CMD_PREFIX -P p1 --allow-follower-workload --workload-mix 0,0,0,100,0 > ${name}_p1.log 2>&1 &
    
    sleep 2
    
    # Start Leader (localhost) with workload mix
    # Workload mix: 10,0,0,90,0 (10% NewOrder, 90% OrderStatus)
    nohup $CMD_PREFIX -P localhost --workload-mix 10,0,0,90,0 > ${name}.log 2>&1 &
    LEADER_PID=$!
    
    echo "Benchmark running with PID $LEADER_PID..."
    
    # Wait for benchmark to finish (approx 30s + startup + loading)
    sleep 70
    
    # Kill processes
    pkill -9 -f dbtest || true
    
    # Parse results
    if [ -f "${name}.log" ]; then
        # Leader stats
        local tput=$(grep "OrderStatus_local_throughput:" ${name}.log | awk '{print $2}')
        local lat=$(grep "OrderStatus_local_commit_latency:" ${name}.log | awk '{print $2}')
        
        # Follower 1 stats
        local tput_p1=0
        if [ -f "${name}_p1.log" ]; then
             tput_p1=$(grep "OrderStatus_local_throughput:" ${name}_p1.log | awk '{print $2}')
        fi
        
        # Follower 2 stats
        local tput_p2=0
        if [ -f "${name}_p2.log" ]; then
             tput_p2=$(grep "OrderStatus_local_throughput:" ${name}_p2.log | awk '{print $2}')
        fi
        
        # Calculate total throughput
        # Use python for float addition if needed, or simple integer math if bash handles it (bash only integers)
        # Using awk for safety
        local total_tput=$(awk "BEGIN {print $tput + $tput_p1 + $tput_p2}")
        
        echo "${name} Results (Read-Only Transactions):"
        echo "  Leader Throughput:     $tput ops/sec"
        echo "  Follower 1 Throughput: $tput_p1 ops/sec"
        echo "  Follower 2 Throughput: $tput_p2 ops/sec"
        echo "  Total Throughput:      $total_tput ops/sec"
        echo "  Leader Latency:        $lat ms"
        
        # Show commit stats if available
        if grep -q "DEBUG: Commits" ${name}.log; then
            echo "  Commit Stats:"
            grep "DEBUG: Commits" ${name}.log | tail -n 2 | sed 's/^/    /'
        fi
    else
        echo "Error: Log file ${name}.log not found."
    fi
}

# Run Fast Path (Build with ENABLE_RO_FAST_PATH=ON)
run_benchmark "fast_path_replicated" "ON"

# Run Normal Path (Build with ENABLE_RO_FAST_PATH=OFF)
run_benchmark "normal_path_replicated" "OFF"

echo "-------------------------------------------------------"
echo "Done."
