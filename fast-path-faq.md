# Fast Path FAQ

## 1. Is snapshot isolation guarantee tested thoroughly? Do I need more tests/cases?

**No, it is not tested thoroughly.**

The current tests (`test_ro_fast_path.cc` and `test_ro_fast_path_rep.cc`) are basic "smoke tests". They follow a simple pattern:
1. Write a value.
2. **Sleep** (e.g., 2 seconds) to allow the system to stabilize.
3. Read the value using a read-only transaction.

**What is missing:**
*   **Concurrent Operations:** There are no tests for race conditions where reads happen simultaneously with writes.
*   **Snapshot Validity:** There are no tests verifying that a transaction sees an *old* version if it starts before a new write commits. The current tests always expect the *latest* value.
*   **Watermark Lag:** The `sleep` hides any potential issues with watermark propagation delay.
*   **Multi-shard Atomicity:** There are no tests verifying that a multi-shard read sees a consistent snapshot across shards (i.e., no "torn reads").

**Recommendation:** You need rigorous tests that:
*   Remove `sleep` calls to test immediate visibility.
*   Validate that RO transactions read the correct *historical* version when concurrent writes exist.
*   Run high-concurrency workloads to stress the watermark synchronization.

## 2. Can snapshot isolation be broken in a multi-shard setup because the latest version is returned?

**Yes, Snapshot Isolation can be broken.**

The issue is not that the "latest version is returned" per se (MVCC handles version selection correctly), but rather that the **Snapshot ID (Watermark) might be inconsistent across shards**.

In `sync_util.hh`, the `client_watermark_exchange` function updates the local watermark based on remote values:

```cpp
// sync_util.hh
sclient->remoteExchangeWatermark(watermark, dstShardIndex);
// Update single watermark if received value is higher
if (watermark > currentWatermark) {
    setSingleWatermark(watermark);
}
```

**The Vulnerability (Even on Leader):**
You might think this only affects followers running the exchange thread. However, **Leaders are also vulnerable** because they import watermarks during **Read-Write transactions**.

1.  **Shard A (Leader)** coordinates a distributed RW transaction that touches Shard B.
2.  Shard A calls `remoteValidate` on Shard B.
3.  **Shard B** returns its watermark (e.g., 200).
4.  **Shard A** updates its local `single_watermark_` to 200 (see `Transaction.cc:551`).
5.  **Shard A** is lagging locally (e.g., `local_timestamp_` = 100).
6.  A **Read-Only Transaction** starts on Shard A. It reads `single_watermark_` (200) as its Snapshot ID.
7.  It reads a local key. The latest version is 100.
8.  **Violation:** The transaction returns version 100, missing any globally committed writes between 100 and 200. This is a stale read.

So, even though the "exchange thread" runs on followers, the **RW transaction commit path** acts as a vector to infect the Leader with an aggressive watermark.

## 3. How is the watermark (relaxed) calculated?

The "relaxed" watermark (`retrieveShardW_relaxed`) simply performs an atomic load with `memory_order_relaxed` on the `single_watermark_` variable.

The `single_watermark_` itself is calculated as the **maximum of local progress and remote watermarks**:

1.  **Local Progress:** `computeLocal()` and `advancer()` calculate the minimum timestamp across all local Paxos partitions (`local_timestamp_`).
    *   *Note:* The logic `if (partition_min >= current_watermark)` in `advancer` implies it ignores partitions that are lagging behind the current watermark, which is risky.
2.  **Remote Progress:** `client_watermark_exchange()` fetches watermarks from other shards and updates the local watermark if the remote value is *higher* (`MAX` logic).

This "Ratchet-up" (MAX) logic is intended to propagate the global stable time, but as noted in Q2, it assumes the local node is caught up, which may not always be true.

## 4. Is the relaxed watermark local per shard or local per replica?

The watermark (`single_watermark_`) is **Local per Replica (Process)**, but critically, it is a **Scalar, not a Vector**.

*   **User Intuition:** You asked if Shard B should be unable to update Shard A's watermark because of vector clocks. You are correct that a **Vector Watermark** `[Watermark_A, Watermark_B]` would prevent this isolation violation.
*   **Actual Implementation:** The codebase explicitly implements a **"Single Timestamp System"** (see comments in `sync_util.hh` and `Transaction.cc`).
    *   The vector `local_timestamp_` exists but is collapsed into a scalar `single_watermark_` via a `MIN` operation.
    *   Remote updates via `remoteValidate` overwrite this scalar with a `MAX` operation.
    *   **Consequence:** Because it's a scalar, Shard A cannot distinguish "Time for Shard A" from "Time for Shard B". When Shard B says "Time is 200", Shard A accepts "Time is 200" for *everything*, including its own data, even if Shard A is only at 150. This "Scalar Collapse" is the root cause of the vulnerability.

## 5. I repeatedly see that a linear scan of the version chain isn't used in the fast path. Is this because the workload mix doesn't produce concurrent writes so the latest version is usually the one indicated in the watermark?

**Yes, exactly.**

If you observe that linear scans are rare, it means that for most reads:
`Latest_Version_Timestamp <= Snapshot_ID`

This happens when:
1.  **Read-Heavy Workload:** Your workload is 90% `OrderStatus` (Read-Only). Writes are infrequent, so the "latest version" doesn't change often.
2.  **Fresh Watermark:** The watermark (`Snapshot_ID`) is keeping up reasonably well with the *committed* writes. Even if it lags slightly, as long as no *new* writes have happened in that lag window, the `Snapshot_ID` will still be greater than or equal to the timestamp of the data on disk.

**Why this matters:**
The "Watermark Lag" performance issue described in `fast-path-performance-analysis.md` only triggers a linear scan if there are **new writes** that are *ahead* of the lagging watermark. If there are no new writes, you just read the old (and only) version, which is fast (O(1)).

## 6. Is get watermark non-blocking?

**Yes.**

`retrieveShardW_relaxed` is implemented as:
```cpp
return single_watermark_.load(memory_order_relaxed);
```
This is a **wait-free atomic load**. It compiles to a single CPU instruction (like `MOV` on x86) and never blocks, waits for locks, or waits for network I/O.
