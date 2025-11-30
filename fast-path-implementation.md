# Fast Path Implementation for Read-Only Transactions

This document details the implementation of the "Fast Path" optimization for read-only transactions in the Mako distributed transaction system.

## Overview

The Fast Path optimization improves the performance of read-only transactions by allowing them to bypass the standard commit protocol (specifically the validation phase). Instead of validating read sets against concurrent writes, read-only transactions read from a consistent snapshot of the database, ensuring serializability without the overhead of locking or validation.

## Key Components

The implementation involves changes to the following components:
1.  **Transaction Management (`Transaction.hh`, `Transaction.cc`)**: Managing snapshot IDs and skipping validation.
2.  **Data Access (`MassTrans.hh`)**: Passing snapshot IDs to the storage layer.
3.  **Multi-Version Storage (`multiversion.hh`)**: Traversing version chains to find snapshot-visible data.
4.  **Watermark Management (`sync_util`)**: Maintaining a global stable watermark.

## Detailed Implementation

### 1. Transaction Class Modifications

We extended the `Transaction` class to support read-only snapshots.

**`src/mako/benchmarks/sto/Transaction.hh`**

Added a member variable to store the snapshot ID for the current transaction:

```cpp
private:
    uint64_t read_only_snapshot_id_;

public:
    void set_read_only_snapshot_id(uint64_t id) {
        read_only_snapshot_id_ = id;
    }

    uint64_t get_read_only_snapshot_id() const {
        return read_only_snapshot_id_;
    }
```

**`src/mako/benchmarks/sto/Transaction.cc`**

In `Transaction::start()`, we initialize the snapshot ID using the globally stable watermark. This watermark represents a timestamp below which all transactions are committed and stable.

```cpp
void Transaction::start() {
    // ... existing initialization ...
    
    // Initialize read-only snapshot ID with the current stable watermark
    // We use relaxed ordering because strict freshness isn't required for the start of the transaction,
    // and it avoids a more expensive barrier.
    read_only_snapshot_id_ = sync_util::sync_logger::retrieveShardW_relaxed();
}
```

In `Transaction::try_commit()`, we added logic to:
1.  **Skip Validation**: If the transaction is read-only (no writes) and opacity is preserved, we skip the validation phase and commit immediately.
2.  **Update Watermark (Single Node)**: For testing purposes in single-node environments (where Paxos is disabled), we manually update the watermark to ensure the snapshot ID advances.

```cpp
bool Transaction::try_commit(bool no_paxos) {
    // ...
    
    // commit immediately if read-only transaction with opacity
    if (!any_writes_ && !any_nonopaque_) {
        stop(true, nullptr, 0);
        return true;
    }

    // ... existing commit logic ...

    if (!no_paxos){
        // ...
        
#ifdef ENABLE_SINGLE_NODE_WATERMARK
        if (!BenchmarkConfig::getInstance().getIsReplicated()) {
            uint32_t current = sync_util::sync_logger::single_watermark_.load(std::memory_order_relaxed);
            if (tid_unique_ > current) {
                sync_util::sync_logger::single_watermark_.store(tid_unique_, std::memory_order_release);
            }
        }
#endif
    }
    // ...
}
```

### 2. Data Access Layer (`MassTrans`)

The `MassTrans` class (which handles Masstree operations) was updated to use the snapshot ID when reading data.

**`src/mako/benchmarks/sto/MassTrans.hh`**

In `transGet` (point lookup) and `transRQuery` (range query), we check if the system is running in multi-version mode. If so, we retrieve the transaction's snapshot ID and pass it to `MultiVersionValue::mvGET`.

```cpp
template <typename ValType>
bool transGet(Str key, ValType& retval, threadinfo_type& ti = mythreadinfo) {
    // ... find key ...
    if (found) {
        // ...
        if (TThread::is_multiversion()) {
            uint64_t snapshot_id = TThread::txn->get_read_only_snapshot_id();
            return MultiVersionValue::mvGET(retval, (char*)e->data(), 
                                          TThread::txn->get_current_term(), 
                                          sync_util::sync_logger::hist_timestamp, 
                                          snapshot_id);
        }
    }
    // ...
}
```

### 3. Multi-Version Storage Logic

The core logic for snapshot isolation resides in `MultiVersionValue::mvGET`.

**`src/mako/benchmarks/sto/multiversion.hh`**

We modified `mvGET` to accept an optional `snapshot_id`. If provided, it traverses the version chain to find the latest version that is visible to the snapshot (i.e., `version_timestamp <= snapshot_id`).

```cpp
static bool mvGET(string& val,
                  char *oldval_str,
                  uint8_t current_term,
                  std::unordered_map<int, uint32_t> hist_timestamp,
                  uint64_t snapshot_id = 0) {
    
    uint32_t *time_term = reinterpret_cast<uint32_t*>((char*)(val.data()+val.length()-mako::EXTRA_BITS_FOR_VALUE));

    // Snapshot isolation logic
    if (snapshot_id > 0) {
        uint32_t current_ts = *time_term / 10;
        
        // Check if the latest version is visible
        if (current_ts <= snapshot_id) {
            return !isDeleted(val);
        }

        // Traverse version chain
        mako::Node *header = reinterpret_cast<mako::Node *>((char*)(val.data()+val.length()-mako::BITS_OF_NODE));
        while (header->data_size > 0) {
            // Get timestamp of the older version
            time_term = reinterpret_cast<uint32_t*>((char*)(header->data+header->data_size-mako::EXTRA_BITS_FOR_VALUE));
            uint32_t version_ts = *time_term / 10;

            if (version_ts <= snapshot_id) {
                val.assign(header->data, (int)header->data_size);
                return !isDeleted(val);
            }
            // Move to next older version
            header = reinterpret_cast<mako::Node *>((char*)(header->data+header->data_size-mako::BITS_OF_NODE));
        }
        return false; // No visible version found
    }

    // ... existing logic for normal reads ...
}
```

### 4. Watermark Management

The global watermark (`single_watermark_`) is critical for determining the snapshot ID.

*   **Replicated Mode**: The watermark is updated by the Paxos consensus protocol (via `remoteValidate` and `remoteInstall`).
*   **Single Node Mode**: We added the `ENABLE_SINGLE_NODE_WATERMARK` flag to allow `Transaction::try_commit` to update the watermark locally, enabling the fast path to function in non-replicated tests.

## Workflow Summary

1.  **Start**: Transaction starts and captures `read_only_snapshot_id_` from the global watermark.
2.  **Read**: When reading a key, `mvGET` uses `read_only_snapshot_id_` to find the correct version.
    *   It walks down the version chain until it finds a version with `timestamp <= snapshot_id`.
    *   This ensures the transaction sees a consistent state of the database as of the snapshot time.
3.  **Commit**:
    *   If the transaction is read-only, `try_commit` detects this (`!any_writes_`).
    *   It skips the validation phase (which would normally check for read-write conflicts).
    *   It returns `true` immediately, committing the transaction.

## Benefits

*   **Reduced Latency**: Skipping the validation phase removes network round-trips (in distributed mode) and lock contention.
*   **Higher Throughput**: Read-only transactions do not block or abort due to concurrent writes, as they read from a stable snapshot.
*   **Scalability**: The load on the leader/sequencer is reduced as read-only transactions don't need to participate in the global ordering for validation.
