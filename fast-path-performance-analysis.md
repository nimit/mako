# Fast Path Performance Analysis: Why It's Slower

## Summary of Results

**Unexpected Performance Regression:**
```
Fast path:    122,755 ops/sec, 0.016895 ms latency
Normal path:  161,657 ops/sec, 0.0123739 ms latency
Degradation:  -24% throughput, +37% latency
```

This is the **opposite** of what we'd expect. The fast path should be faster by skipping validation.

---

## Root Cause Analysis

Based on the logs and implementation, here are the likely culprits:

### 1. ⚠️ **CRITICAL: Watermark Lag (Most Likely)**

**The Problem:**
Looking at your log (line 201-793), I see:
```
DEBUG: Commits - Total: 0, FastPath: 0        # Transaction start
...
DEBUG: Commits - Total: 130000, FastPath: 3444   # ~2.6% using fast path
...  
DEBUG: Commits - Total: 4900000, FastPath: 4296692  # ~87.7% using fast path
```

The fast path ratio starts very low (~2.6%) and grows over time. This suggests **watermark lag**: the watermark is stuck at a very old value, causing most version chains to be long.

**Why This Hurts Performance:**

When a read-only transaction starts:
```cpp
read_only_snapshot_id_ = sync_util::sync_logger::retrieveShardW_relaxed();
```

If the watermark is **far behind** the current timestamp:
- **Every read** has to traverse the version chain backward
- In your workload (90% OrderStatus), each transaction reads multiple tables
- Each read does a linear scan through versions until finding `timestamp <= snapshot_id`

**Example:**
```
Current time: 5000
Watermark:    100  ← stuck!
Snapshot ID:  100  ← captured from watermark

Version chain:
V5: ts=5000 ← not visible
  ↓
V4: ts=4000 ← not visible  
  ↓
V3: ts=3000 ← not visible
  ↓
V2: ts=2000 ← not visible
  ↓  
V1: ts=100  ← FINALLY visible! (4 iterations of pointer chasing)
```

With **10 reads per transaction** × **4 chain traversals** = **40 pointer dereferences** per transaction!

**Evidence in Code:**

In [multiversion.hh:118-130](file:///home/nimit/mako/src/mako/benchmarks/sto/multiversion.hh#L118-L130):
```cpp
while (header->data_size > 0) {  // ← This loop iterates through EVERY version
    time_term = reinterpret_cast<uint32_t*>(...);
    uint32_t version_ts = *time_term / 10;
    
    if (version_ts <= snapshot_id) {  // ← Only matches after many iterations if watermark is stale
        val.assign(header->data, (int)header->data_size);
        return !isDeleted(val);
    }
    header = reinterpret_cast<mako::Node *>(...);  // ← Pointer chasing = cache misses
}
```

---

### 2. **Cache-Unfriendly Memory Access**

**The Problem:**
Version chain traversal involves chasing pointers:

```
Latest version (CPU cache-friendly)
    ↓ pointer dereference (cache miss)
Older version (random heap location)
    ↓ pointer dereference (cache miss)
Even older version (random heap location)
    ↓ ...
```

Each `malloc()` in `mvInstall` allocates memory at arbitrary locations. The linked list is **not** contiguous.

**Comparison:**
- **Normal path**: Reads latest version directly (cache-friendly)
- **Fast path**: Traverses pointer chain (cache-unfriendly)

With a stale watermark, this dominates the cost.

---

### 3. **Atomic Watermark Reads**

**The Problem:**
Every transaction start reads the watermark:

```cpp
read_only_snapshot_id_ = sync_util::sync_logger::retrieveShardW_relaxed();
```

Which calls [sync_util.hh:196-199](file:///home/nimit/mako/src/mako/benchmarks/sto/sync_util.hh#L196-L199):
```cpp
static uint32_t retrieveShardW_relaxed() {
   return single_watermark_.load(memory_order_relaxed);
}
```

While `memory_order_relaxed` is fast, with **161k ops/sec**, this is still **161k atomic loads per second** from a **shared cache line**.

**Cache Line Contention:**
- 4 threads all reading `single_watermark_`
- The cache line bounces between CPU cores
- Not as bad as `memory_order_acquire`, but still measurable

---

### 4. **Single-Node Watermark Update Issues**

Looking at [Transaction.cc:512-519](file:///home/nimit/mako/src/mako/benchmarks/sto/Transaction.cc#L512-L519):

```cpp
#ifdef ENABLE_SINGLE_NODE_WATERMARK
    if (!BenchmarkConfig::getInstance().getIsReplicated()) {
        uint32_t current = sync_util::sync_logger::single_watermark_.load(std::memory_order_relaxed);
        if (tid_unique_ > current) {
            sync_util::sync_logger::single_watermark_.store(tid_unique_, std::memory_order_release);
        }
    }
#endif
```

**The Problem:**
This only updates the watermark for **write transactions**. But your workload is:
- 10% NewOrder (write)
- 90% OrderStatus (read-only)

So watermark advancement is **10x slower** than the transaction rate!

**Math:**
- Total: 161k txns/sec
- Writes: 16.1k txns/sec updating watermark
- Reads: 144.9k txns/sec NOT advancing watermark

Result: Watermark lags behind by ~10x in time.

---

### 5. **GC Not Keeping Up**

From [multiversion.hh:49-50](file:///home/nimit/mako/src/mako/benchmarks/sto/multiversion.hh#L49-L50):
```cpp
TThread::incr_counter();
if (TThread::counter() % 50 != 0) return;  // Only GC every 50 updates
```

**The Problem:**
- GC runs every **50 write transactions**  
- With 10% write rate: GC runs every **500 total transactions**
- At 161k txns/sec: GC runs **322 times/sec**
- But there are **4 threads** × **many keys**

If you have 10k hot keys:
- GC rate: 322 GC/sec
- Per-key GC rate: 0.032 GC/sec = **once per 31 seconds!**

Result: Long version chains accumulate.

---

## Troubleshooting Steps (In Priority Order)

### Step 1: Verify Watermark Lag ⭐ **START HERE**

Add instrumentation to check watermark freshness:

```cpp
// In Transaction.cc, in Transaction::start()
void Transaction::start() {
    read_only_snapshot_id_ = sync_util::sync_logger::retrieveShardW_relaxed();
    
    // DEBUG: Check lag
    static std::atomic<uint64_t> sample_count{0};
    if (sample_count.fetch_add(1) % 10000 == 0) {
        uint64_t current_tid = _TID;
        uint64_t watermark = read_only_snapshot_id_;
        uint64_t lag = (current_tid - watermark) / 10;  // Remove epoch bits
        std::cerr << "WATERMARK_LAG: current=" << current_tid/10 
                  << ", watermark=" << watermark/10
                  << ", lag=" << lag << std::endl;
    }
}
```

**Expected output:**
- **Good**: `lag < 100` (watermark is recent)
- **Bad**: `lag > 10000` (watermark is very stale)

If lag is high, **this is your smoking gun**.

---

### Step 2: Measure Version Chain Length

Add version chain statistics:

```cpp
// In multiversion.hh, in mvGET()
static bool mvGET(string& val, char *oldval_str, uint8_t current_term,
                  std::unordered_map<int, uint32_t> hist_timestamp,
                  uint64_t snapshot_id = 0) {
    
    if (snapshot_id > 0) {
        uint32_t current_ts = *time_term / 10;
        
        if (current_ts <= snapshot_id) {
            return !isDeleted(val);
        }

        // DEBUG: Count chain traversal
        static thread_local uint64_t total_traversals = 0;
        static thread_local uint64_t total_chain_length = 0;
        uint32_t chain_length = 1;  // Counted the latest version
        
        mako::Node *header = reinterpret_cast<mako::Node *>(...);
        while (header->data_size > 0) {
            chain_length++;
            time_term = reinterpret_cast<uint32_t*>(...);
            uint32_t version_ts = *time_term / 10;

            if (version_ts <= snapshot_id) {
                total_traversals++;
                total_chain_length += chain_length;
                
                if (total_traversals % 10000 == 0) {
                    std::cerr << "AVG_CHAIN_LENGTH: " 
                              << (double)total_chain_length / total_traversals 
                              << std::endl;
                }
                
                val.assign(header->data, (int)header->data_size);
                return !isDeleted(val);
            }
            header = reinterpret_cast<mako::Node *>(...);
        }
        return false;
    }
    // ... rest of function
}
```

**Expected output:**
- **Good**: `AVG_CHAIN_LENGTH < 2.0` (most versions are latest)
- **Bad**: `AVG_CHAIN_LENGTH > 5.0` (long chains = many iterations)

---

### Step 3: Profile with perf

Capture CPU cycles:

```bash
# Run with perf
sudo perf record -g --call-graph dwarf ../build/dbtest --num-threads 4 --shard-index 0 \
    --shard-config ../config/mako_single_node.yml -P localhost --workload-mix 10,0,0,90,0

# Generate report
sudo perf report --stdio | head -100

# Look for hot functions
```

**What to look for:**
- High % in `MultiVersionValue::mvGET` → version chain traversal is expensive
- High % in `retrieveShardW_relaxed` → watermark contention
- High % in `mvInstall` → write path overhead (unlikely with 10% writes)

---

### Step 4: Compare Opacity Checking Overhead

Normal path does opacity checking. Check if it's actually expensive:

```bash
# count opacity checks in normal path log
grep "txp_hco" examples/normal_path.log

# If very few, opacity checking isn't the issue
```

---

## Proposed Fixes (In Priority Order)

### Fix 1: ⭐ **Eager Watermark Advancement for Read-Only Transactions**

**The Root Problem:** Watermark only advances on write transactions (10% of workload).

**Solution:** Advance watermark on **every** transaction commit, not just writes.

**Code Change:**

In [Transaction.cc:395-401](file:///home/nimit/mako/src/mako/benchmarks/sto/Transaction.cc#L395-L401):

```cpp
// BEFORE (Current - BROKEN):
#ifdef ENABLE_RO_FAST_PATH
    if (!any_writes_) {
        fast_path_commits.fetch_add(1, std::memory_order_relaxed);
        stop(true, nullptr, 0);  // ← Commits immediately WITHOUT advancing watermark!
        return true;
    }
#endif
```

```cpp
// AFTER (Fixed):
#ifdef ENABLE_RO_FAST_PATH
    if (!any_writes_) {
        fast_path_commits.fetch_add(1, std::memory_order_relaxed);
        
        // FIX: Advance watermark even for RO transactions in single-node mode
        #ifdef ENABLE_SINGLE_NODE_WATERMARK
        if (!BenchmarkConfig::getInstance().getIsReplicated()) {
            // Even though RO txn has no tid_unique_, we can use its snapshot_id
            // as a lower bound for the watermark
            uint32_t snapshot_ts = read_only_snapshot_id_;
            uint32_t current = sync_util::sync_logger::single_watermark_.load(
                std::memory_order_relaxed);
            if (snapshot_ts > current) {
                sync_util::sync_logger::single_watermark_.store(
                    snapshot_ts, std::memory_order_release);
            }
        }
        #endif
        
        stop(true, nullptr, 0);
        return true;
    }
#endif
```

**Impact:** This should **dramatically** reduce watermark lag and version chain length.

---

###Fix 2: **Thread-Local Watermark Caching**

**Problem:** Every transaction start reads a shared atomic variable.

**Solution:** Cache the watermark locally and refresh periodically.

**Code Change:**

In [Transaction.cc](file:///home/nimit/mako/src/mako/benchmarks/sto/Transaction.cc):

```cpp
void Transaction::start() {
    // Thread-local cache to reduce atomic reads
    static thread_local uint32_t cached_watermark = 0;
    static thread_local uint64_t cache_timestamp = 0;
    
    uint64_t now = _TID;
    
    // Refresh cache every 1000 transactions (or time-based)
    if (now - cache_timestamp > 1000 * 10) {  // 1000 timestamps * 10 (encoding)
        cached_watermark = sync_util::sync_logger::retrieveShardW_relaxed();
        cache_timestamp = now;
    }
    
    read_only_snapshot_id_ = cached_watermark;
    // ... rest of start()
}
```

**Tradeoff:**
- **Pro**: Reduces atomic reads by 1000x
- **Con**: Snapshot may be slightly older (more stale)
- **Con**: Longer version chains (but GC will catch up)

**When to use:** If profiling shows `retrieveShardW_relaxed` is hot.

---

### Fix 3: **More Aggressive Garbage Collection**

**Problem:** GC runs every 50 updates, which is too infrequent.

**Solution:** Reduce the GC interval.

**Code Change:**

In [multiversion.hh:49-50](file:///home/nimit/mako/src/mako/benchmarks/sto/multiversion.hh#L49-L50):

```cpp
// BEFORE:
if (TThread::counter() % 50 != 0) return;

// AFTER:
if (TThread::counter() % 10 != 0) return;  // GC every 10 updates instead of 50
```

**Tradeoff:**
- **Pro**: Shorter version chains
- **Con**: More CPU spent on GC
- **Net**: Likely positive for read-heavy workloads

**Tuning:** Start with 10, then try 5, 20 to find the sweet spot.

---

### Fix 4: **Batch Watermark Updates (Advanced)**

For single-node mode, we can batch watermark updates:

```cpp
// Instead of updating on every write transaction:
static thread_local uint32_t pending_watermark_update = 0;

// In try_commit():
if (tid_unique_ > pending_watermark_update) {
    pending_watermark_update = tid_unique_;
}
    
// Flush every N transactions
if (TThread::counter() % 100 == 0) {
    uint32_t current = sync_util::sync_logger::single_watermark_.load(
        std::memory_order_relaxed);
    if (pending_watermark_update > current) {
        sync_util::sync_logger::single_watermark_.store(
            pending_watermark_update, std::memory_order_release);
    }
}
```

**Impact:** Reduces atomic stores, but increases watermark lag slightly.

---

## Quick Diagnosis Script

Create and run this to get instant insights:

```bash
#!/bin/bash
# Save as: diagnose_fast_path.sh

echo "=== Fast Path Diagnostics ==="
echo ""

# 1. Check if fast path is being used
echo "1. Fast Path Usage:"
TOTAL=$(grep "DEBUG: Commits - Total:" examples/fast_path.log | tail -1 | awk '{print $5}' | tr -d ',')
FAST=$(grep "DEBUG: Commits - Total:" examples/fast_path.log | tail -1 | awk '{print $7}')
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
FP_TPUT=$(grep "OrderStatus_local_throughput:" examples/fast_path.log | awk '{print $2}')
NP_TPUT=$(grep "OrderStatus_local_throughput:" examples/normal_path.log | awk '{print $2}')
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
EARLY=$(grep "DEBUG: Commits - Total: 50000" examples/fast_path.log | awk '{print $7}')
LATE=$(grep "DEBUG: Commits - Total: 500000" examples/fast_path.log | awk '{print $7}')
EARLY_RATIO=$(echo "scale=2; 100 * $EARLY / 50000" | bc)
LATE_RATIO=$(echo "scale=2; 100 * ($LATE - $EARLY) / 450000" | bc)
echo "   Early (first 50k):  $EARLY_RATIO%"
echo "   Later (50k-500k): $LATE_RATIO%"
if (( $(echo "$LATE_RATIO - $EARLY_RATIO > 10" | bc -l) )); then
    echo "   ⚠️  Fast path ratio increasing over time suggests watermark lag"
fi
echo ""

# 4. Configuration check
echo "4. Configuration:"
grep "read_only_snapshots" examples/fast_path.log
echo ""

echo "=== Recommendations ==="
if (( $(echo "$DIFF < -10" | bc -l) )); then
    echo "❌ Fast path is significantly slower. Top suspects:"
    echo "   1. Watermark lag causing long version chain traversals"
    echo "   2. Check if ENABLE_SINGLE_NODE_WATERMARK is defined"
    echo "   3. Add instrumentation from 'Troubleshooting Step 1'"
fi
```

---

## Expected Results After Fixes

After applying **Fix 1** (eager watermark advancement):

| Metric | Before | After (Expected) |
|--------|--------|------------------|
| Throughput | 122,755 ops/sec | **200,000+ ops/sec** (25% better than normal) |
| Latency | 0.016895 ms | **0.008 ms** (50% lower than normal) |
| Fast path ratio | 87.7% (growing) | **90% (stable)** |
| Avg chain length | ~5-10 (estimated) | **~1.2** |
| Watermark lag | High (10000+) | **Low (<100)** |

---

## Summary

**Most Likely Culprit:** Watermark lag

**Why It Matters:** With a stale watermark, every read traverses a long version chain via cache-unfriendly pointer chasing.

**Quick Fix:** Apply **Fix 1** to advance watermark on read-only commits.

**Verification:** Add instrumentation from **Step 1** to measure lag before/after.

**Expected Outcome:** Fast path should be ~25% faster than normal path (matching theoretical expectations).
