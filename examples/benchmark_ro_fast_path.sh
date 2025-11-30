#!/bin/bash
set -e

# Get project root (one level up from examples)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "Running TPC-C Benchmark: Read-Only Fast Path Comparison"
echo "Workload: 10% NewOrder, 90% OrderStatus (Read-Only Heavy)"
echo "Runtime: 30 seconds (default)"
echo "-------------------------------------------------------"

# Function to run benchmark
run_bench() {
    local name=$1
    local enable_fast_path=$2
    
    echo "Building for $name..."
    # Build with appropriate flags
    cd "$PROJECT_ROOT/build"
    if [ "$enable_fast_path" == "ON" ]; then
        cmake -DCMAKE_BUILD_TYPE=Release -DENABLE_RO_FAST_PATH=ON ..
    else
        cmake -DCMAKE_BUILD_TYPE=Release -DENABLE_RO_FAST_PATH=OFF ..
    fi
    make -j12 dbtest
    cd "$PROJECT_ROOT/examples"

    echo "Running $name..."
    # Using 4 threads, 1 shard.
    # Workload mix: 10,0,0,90,0 (10% NewOrder, 90% OrderStatus)
    ../build/dbtest --num-threads 4 --shard-index 0 --shard-config ../config/mako_single_node.yml -P localhost --workload-mix 10,0,0,90,0 > ${name}.log 2>&1
    
    # Parse results for Read-Only transactions (OrderStatus)
    local tput=$(grep "OrderStatus_local_throughput:" ${name}.log | awk '{print $2}')
    local lat=$(grep "OrderStatus_local_commit_latency:" ${name}.log | awk '{print $2}')
    
    echo "${name} Results (Read-Only Transactions):"
    echo "  Throughput: $tput ops/sec"
    echo "  Latency:    $lat ms"
    
    # Show commit stats if available
    if grep -q "DEBUG: Commits" ${name}.log; then
        echo "  Commit Stats:"
        grep "DEBUG: Commits" ${name}.log | tail -n 2 | sed 's/^/    /'
    fi
}

# Run Fast Path (Build with ENABLE_RO_FAST_PATH=ON)
run_bench "fast_path" "ON"

# Run Normal Path (Build with ENABLE_RO_FAST_PATH=OFF)
run_bench "normal_path" "OFF"

echo "-------------------------------------------------------"
echo "Done."
