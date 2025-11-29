#!/bin/bash
set -e

# Get project root (one level up from examples)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Compile
cd "$PROJECT_ROOT"
mkdir -p build
cd build
cmake ..
make -j32 dbtest
cd "$PROJECT_ROOT/examples"

echo "Running TPC-C Benchmark: Read-Only Fast Path Comparison"
echo "Workload: 10% NewOrder, 90% OrderStatus (Read-Only Heavy)"
echo "Runtime: 30 seconds (default)"
echo "-------------------------------------------------------"

# Function to run benchmark
run_bench() {
    local name=$1
    local extra_args=$2
    
    # Build with appropriate flags
    cd ../build
    if [ "$name" == "fast_path" ]; then
        cmake -DCMAKE_BUILD_TYPE=Release -DENABLE_SINGLE_NODE_WATERMARK=ON ..
    else
        cmake -DCMAKE_BUILD_TYPE=Release -DENABLE_SINGLE_NODE_WATERMARK=OFF ..
    fi
    make -j12 dbtest
    cd ../examples

    echo "Running $name..."
    # Using 4 threads, 1 shard.
    # Workload mix: 10,0,0,90,0 (10% NewOrder, 90% OrderStatus)
    ../build/dbtest --num-threads 4 --shard-index 0 --shard-config ../config/mako_single_node.yml -P localhost --workload-mix 10,0,0,90,0 $extra_args > ${name}.log 2>&1
    
    # Parse results for Read-Only transactions (OrderStatus)
    local tput=$(grep "OrderStatus_local_throughput:" ${name}.log | awk '{print $2}')
    local lat=$(grep "OrderStatus_local_commit_latency:" ${name}.log | awk '{print $2}')
    
    echo "${name} Results (Read-Only Transactions):"
    echo "  Throughput: $tput ops/sec"
    echo "  Latency:    $lat ms"
}

# Run Fast Path (Default)
run_bench "fast_path" ""

# Run Normal Path (Disabled)
run_bench "normal_path" "--disable-read-only-snapshots"

echo "-------------------------------------------------------"
echo "Done."
