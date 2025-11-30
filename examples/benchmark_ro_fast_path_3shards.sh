#!/bin/bash
set -e

# Get the directory where the script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Go to examples directory
cd "$PROJECT_ROOT/examples"

echo "Running TPC-C Benchmark: Read-Only Fast Path Comparison (3 Shards, 4 Replicas)"
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
    NSHARD=3
    CONFIG_PATH="../src/mako/config"
    PAXOS_CONFIG_PATH="../config/1leader_2followers"
    
    # Launch processes for each shard
    for SHARD in 0 1 2; do
        echo "Launching Shard $SHARD..."
        
        CMD_PREFIX="../build/dbtest --num-threads $TRD --shard-index $SHARD --shard-config $CONFIG_PATH/local-shards$NSHARD-warehouses$TRD.yml -F $PAXOS_CONFIG_PATH/paxos${TRD}_shardidx${SHARD}.yml -F ../config/occ_paxos.yml --is-replicated"

        # Start Learner
        nohup $CMD_PREFIX -P learner > ${name}_shard${SHARD}_learner.log 2>&1 &
        
        # Start Follower 2
        nohup $CMD_PREFIX -P p2 > ${name}_shard${SHARD}_p2.log 2>&1 &
        
        # Start Follower 1
        nohup $CMD_PREFIX -P p1 > ${name}_shard${SHARD}_p1.log 2>&1 &
        
        sleep 1
        
        # Start Leader (localhost) with workload mix
        # Workload mix: 10,0,0,90,0 (10% NewOrder, 90% OrderStatus)
        nohup $CMD_PREFIX -P localhost --workload-mix 10,0,0,90,0 > ${name}_shard${SHARD}.log 2>&1 &
    done
    
    echo "Benchmark running..."
    
    # Wait for benchmark to finish (approx 30s + startup + loading)
    sleep 180
    
    # Kill processes
    pkill -9 -f dbtest || true
    
    # Parse results
    echo "${name} Results (Read-Only Transactions):"
    
    total_tput=0
    total_lat=0
    count=0
    
    for SHARD in 0 1 2; do
        if [ -f "${name}_shard${SHARD}.log" ]; then
            local tput=$(grep "OrderStatus_local_throughput:" ${name}_shard${SHARD}.log | awk '{print $2}')
            local lat=$(grep "OrderStatus_local_commit_latency:" ${name}_shard${SHARD}.log | awk '{print $2}')
            
            if [ ! -z "$tput" ]; then
                echo "  Shard $SHARD Throughput: $tput ops/sec"
                echo "  Shard $SHARD Latency:    $lat ms"
                total_tput=$(echo "$total_tput + $tput" | bc)
                total_lat=$(echo "$total_lat + $lat" | bc)
                count=$((count + 1))
                
                # Show commit stats if available
                if grep -q "DEBUG: Commits" ${name}_shard${SHARD}.log; then
                    echo "  Shard $SHARD Commit Stats:"
                    grep "DEBUG: Commits" ${name}_shard${SHARD}.log | tail -n 2 | sed 's/^/    /'
                fi
            else
                echo "  Shard $SHARD: No results found"
            fi
        else
            echo "Error: Log file ${name}_shard${SHARD}.log not found."
        fi
    done
    
    if [ $count -gt 0 ]; then
        avg_lat=$(echo "scale=5; $total_lat / $count" | bc)
        echo "  Total Throughput: $total_tput ops/sec"
        echo "  Avg Latency:      $avg_lat ms"
    fi
}

# Run Fast Path (Build with ENABLE_RO_FAST_PATH=ON)
run_benchmark "fast_path" "ON"

# Run Normal Path (Build with ENABLE_RO_FAST_PATH=OFF)
run_benchmark "normal_path" "OFF"

echo "-------------------------------------------------------"
echo "Done."
