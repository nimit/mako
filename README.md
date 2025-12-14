# Read-Only Transaction Fast Path

A performance optimization for Mako that allows read-only transactions to bypass the validation phase by reading from consistent database snapshots.

## Overview

The **Fast Path** optimization provides significant throughput improvements for read-heavy workloads in replicated deployments by:

1. **Eliminating coordination overhead**: Read-only transactions skip the validation phase entirely
2. **Snapshot isolation**: Transactions read from a consistent point-in-time snapshot using MVCC
3. **Enabling follower reads**: Allows follower replicas to serve read-only transactions, scaling read capacity

## Key Results

### Replicated Environment (1 Shard, 3 Replicas)

**Workload**: TPC-C with 90% OrderStatus (read-only), 10% NewOrder (read-write)

| Metric                    | Normal Path         | Fast Path           | Improvement |
| ------------------------- | ------------------- | ------------------- | ----------- |
| **Leader Throughput**     | 212,020 ops/sec     | 139,388 ops/sec     | -34.3%      |
| **Follower 1 Throughput** | 0 ops/sec           | 282,732 ops/sec     | N/A         |
| **Follower 2 Throughput** | 0 ops/sec           | 293,852 ops/sec     | N/A         |
| **Total Throughput**      | **212,020 ops/sec** | **715,972 ops/sec** | **+237.7%** |
| **Leader Latency**        | 0.00972 ms          | 0.01464 ms          | +50.6%      |

> The leader throughput and latency appears worse with the fast path enabled because follower-reads and repeated watermark retrievals lead to resource contention.

### Key Insights

- **Linear read scaling** with additional follower replicas
- **Zero coordination** for read-only transactions (no validation)
- **3.4× total throughput improvement** by distributing reads across replicas

## How It Works

### 1. Snapshot Capture (Transaction Start)

```cpp
read_only_snapshot_id_ = sync_util::sync_logger::retrieveShardW_relaxed();
```

Each transaction captures the current stable watermark as its snapshot ID.

### 2. Version Traversal (Data Access)

Read operations traverse the MVCC version chain to find the version visible at the snapshot:

```cpp
if (version_timestamp <= snapshot_id) {
    return version;  // Found visible version
}
```

### 3. Fast Commit (No Validation)

```cpp
if (!any_writes_) {
    stop(true, nullptr, 0);  // Commit immediately
    return true;
}
```

### 4. Follower Reads (Replicated Mode)

With `--allow-follower-workload`, follower replicas execute the entire read-only workload locally while the leader handles write transactions.

## Running the Benchmark

### Prerequisites

```bash
# Ensure the project is built
make -j12 dbtest
```

### Execute Benchmark

```bash
bash examples/benchmark_ro_fast_path_replicated.sh
```

### What the Benchmark Does

1. **Builds** the project twice:

   - With `ENABLE_RO_FAST_PATH=ON` (fast path enabled)
   - With `ENABLE_RO_FAST_PATH=OFF` (normal path)

2. **Runs** a replicated TPC-C workload with:

   - **Topology**: 1 Leader + 2 Followers + 1 Learner
   - **Workload Mix**: 10% NewOrder, 90% OrderStatus (`--workload-mix 10,0,0,90,0`)
   - **Threads**: 4 per node
   - **Runtime**: ~30 seconds per run

3. **Reports** throughput and latency for:
   - Leader node
   - Each follower node (fast path only)
   - Total aggregate throughput

### Output Example

```
fast_path_replicated Results (Read-Only Transactions):
  Leader Throughput:     139388 ops/sec
  Follower 1 Throughput: 282732 ops/sec
  Follower 2 Throughput: 293852 ops/sec
  Total Throughput:      715972 ops/sec
  Leader Latency:        0.0146378 ms
```

## Implementation Details

### Compile-Time Flags

| Flag                           | Description                                            |
| ------------------------------ | ------------------------------------------------------ |
| `ENABLE_RO_FAST_PATH`          | Enable the fast path optimization                      |
| `ENABLE_SINGLE_NODE_WATERMARK` | Enable watermark updates in single-node mode (testing) |

### Key Files Modified

| File                | Changes                                         |
| ------------------- | ----------------------------------------------- |
| `Transaction.hh/cc` | Snapshot ID management, fast commit logic       |
| `MassTrans.hh`      | Pass snapshot ID to MVCC layer                  |
| `multiversion.hh`   | Version chain traversal with snapshot filtering |
| `sync_util.hh`      | Watermark computation and management            |
| `tpcc.cc`           | Follower workload distribution                  |

<!-- ### Commit History

| Commit    | Description                                      |
| --------- | ------------------------------------------------ |
| `c24ad14` | Follower read TPC-C example                      |
| `d805344` | Added follower read functionality                |
| `ca5c2f0` | RO fast path flag + benchmark script changes     |
| `d19d499` | Fast path issues diagnosing                      |
| `ea0f90d` | Fast path implementation detail + evaluation     |
| `4f3fb5a` | Watermark tracking fix + replicated server tests |
| `bee31f6` | Fast path addition and read consistency checks   | -->

## When to Use

| Scenario                             | Recommendation                                     |
| ------------------------------------ | -------------------------------------------------- |
| **Replicated, read-heavy workloads** | ✅ Enable fast path                                |
| **Geo-replicated deployments**       | ✅ Enable fast path (reduced cross-region traffic) |
| **Single-node deployments**          | ❌ Use normal path (fast path adds overhead)       |
| **Write-heavy workloads**            | ⚠️ Limited benefit (few read-only transactions)    |

## Trade-offs

- **Memory**: Stores multiple versions per key (typically 2-3 in high-update workloads)
- **Leader Latency**: Slightly higher due to watermark management overhead
- **Eventual Staleness**: Reads may lag behind the latest committed writes by watermark delay (~1ms)
