#!/bin/bash
# Fast Path Performance Diagnostics

echo "=== Fast Path Diagnostics ==="
echo ""

# 1. Check if fast path is being used
echo "1. Fast Path Usage:"
TOTAL=$(grep "DEBUG: Commits - Total:" fast_path.log | tail -1 | awk '{print $5}' | tr -d ',')
FAST=$(grep "DEBUG: Commits - Total:" fast_path.log | tail -1 | awk '{print $7}')
RATIO=$(echo "scale=2; 100 * $FAST / $TOTAL" | bc)
echo "   Total commits: $TOTAL"
echo "   Fast path commits: $FAST"
echo "   Fast path ratio: $RATIO%"
echo "   Expected: ~90% (matching 90% OrderStatus workload)"
if (( $(echo "$RATIO < 85" | bc -l) )); then
    echo "   ⚠️  WARNING: Fast path usage is low! Expected ~90%"
fi
echo ""

# 2. Check throughput
echo "2. Throughput Comparison:"
FP_TPUT=$(grep "OrderStatus_local_throughput:" fast_path.log | awk '{print $2}')
NP_TPUT=$(grep "OrderStatus_local_throughput:" normal_path.log | awk '{print $2}')
DIFF=$(echo "scale=2; 100 * ($FP_TPUT - $NP_TPUT) / $NP_TPUT" | bc)
echo "   Fast path: $FP_TPUT ops/sec"
echo "   Normal path: $NP_TPUT ops/sec"
echo "   Difference: $DIFF%"
if (( $(echo "$DIFF < 0" | bc -l) )); then
    echo "   ⚠️  PROBLEM: Fast path is SLOWER!"
fi
echo ""

# 3. Watermark lag indicator (indirect)
echo "3. Fast Path Adoption Rate:"
echo "   (Faster adoption = better watermark)"
EARLY=$(grep "DEBUG: Commits - Total: 50000" fast_path.log | awk '{print $7}')
MID=$(grep "DEBUG: Commits - Total: 500000" fast_path.log | awk '{print $7}')
LATE=$(grep "DEBUG: Commits - Total:" fast_path.log | tail -1 | awk '{print $7}')

if [ -n "$EARLY" ] && [ -n "$MID" ]; then
    EARLY_RATIO=$(echo "scale=2; 100 * $EARLY / 50000" | bc)
    MID_RATIO=$(echo "scale=2; 100 * $MID / 500000" | bc)
    LATE_RATIO=$(echo "scale=2; 100 * $LATE / $TOTAL" | bc)
    
    echo "   Early (first 50k):    $EARLY_RATIO%"
    echo "   Mid (at 500k):        $MID_RATIO%"
    echo "   Late (final):         $LATE_RATIO%"
    
    GROWTH=$(echo "scale=2; $LATE_RATIO - $EARLY_RATIO" | bc)
    if (( $(echo "$GROWTH > 10" | bc -l) )); then
        echo "   ⚠️  Fast path ratio grew by $GROWTH% - indicates watermark lag!"
    fi
fi
echo ""

# 4. Configuration check
echo "4. Configuration:"
grep "read_only_snapshots" fast_path.log | head -1
grep "is_replicated" fast_path.log | head -1
echo ""

# 5. Commit timing
echo "5. Commit Progression Analysis:"
echo "   Checking how fast path adoption progresses..."
grep "DEBUG: Commits" fast_path.log | awk '{
    total=$5; 
    gsub(/,/, "", total); 
    fast=$7;
    if (NR % 50 == 0) {
        ratio = 100 * fast / total;
        printf "   At %8s commits: %6.2f%% fast path\n", total, ratio
    }
}' | head -20

echo ""
echo "=== Recommendations ==="
if (( $(echo "$DIFF < -10" | bc -l) )); then
    echo "❌ Fast path is significantly slower ($DIFF%). Top suspects:"
    echo "   1. Watermark lag causing long version chain traversals"
    echo "   2. Check if ENABLE_SINGLE_NODE_WATERMARK is defined in build"
    echo "   3. Apply 'Fix 1' from fast-path-performance-analysis.md"
    echo "   4. Add watermark lag instrumentation (see analysis doc)"
elif (( $(echo "$DIFF < 0" | bc -l) )); then
    echo "⚠️  Fast path is slightly slower ($DIFF%)."
    echo "   Run step-by-step troubleshooting from analysis doc."
else
    echo "✅ Fast path is faster! ($DIFF% improvement)"
fi
