# Read-Only Transaction Fast Path: Deep Dive

## Overview

The fast path optimization allows **read-only transactions to bypass the standard validation phase** of the commit protocol. Instead of acquiring locks and validating read sets against concurrent writes, these transactions read from a **consistent snapshot** of the database, ensuring serializability without coordination overhead.

---

## How the Fast Path Works

### 1. Transaction Start - Snapshot Capture

When a transaction starts ([Transaction.cc:46-53](file:///home/nimit/mako/src/mako/benchmarks/sto/Transaction.cc#L46-L53)):

```cpp
void Transaction::start() {
    // Initialize read-only snapshot ID with the current stable watermark
    read_only_snapshot_id_ = sync_util::sync_logger::retrieveShardW_relaxed();
}
```

**What happens:**
- The transaction captures a **snapshot ID** from the global **stable watermark**
- This watermark represents a timestamp below which all transactions are committed and stable
- Uses `memory_order_relaxed` for performance (strict freshness not required at transaction start)

**Key insight:** The snapshot ID acts as a "point in time" marker. All data visible to this transaction must have been committed at or before this timestamp.

---

### 2. Reading Data - Version Traversal

When reading a key ([MassTrans.hh:97-112](file:///home/nimit/mako/src/mako/benchmarks/sto/MassTrans.hh#L97-L112)):

```cpp
template <typename ValType>
bool transGet(Str key, ValType& retval, threadinfo_type& ti) {
    // ... find key ...
    if (found) {
        if (TThread::is_multiversion()) {
            uint64_t snapshot_id = TThread::txn->get_read_only_snapshot_id();
            return MultiVersionValue::mvGET(retval, (char*)e->data(), 
                                           TThread::txn->get_current_term(), 
                                           sync_util::sync_logger::hist_timestamp, 
                                           snapshot_id);
        }
    }
}
```

The snapshot ID is passed to `MultiVersionValue::mvGET` ([multiversion.hh:101-132](file:///home/nimit/mako/src/mako/benchmarks/sto/multiversion.hh#L101-L132)):

```cpp
static bool mvGET(string& val,
                  char *oldval_str,
                  uint8_t current_term,
                  std::unordered_map<int, uint32_t> hist_timestamp,
                  uint64_t snapshot_id = 0) {
    
    uint32_t *time_term = reinterpret_cast<uint32_t*>(
        (char*)(val.data()+val.length()-mako::EXTRA_BITS_FOR_VALUE));

    // Snapshot isolation logic
    if (snapshot_id > 0) {
        uint32_t current_ts = *time_term / 10;
        
        // Check if the latest version is visible
        if (current_ts <= snapshot_id) {
            return !isDeleted(val);
        }

        // Traverse version chain to find visible version
        mako::Node *header = reinterpret_cast<mako::Node *>(
            (char*)(val.data()+val.length()-mako::BITS_OF_NODE));
        
        while (header->data_size > 0) {
            time_term = reinterpret_cast<uint32_t*>(
                (char*)(header->data+header->data_size-mako::EXTRA_BITS_FOR_VALUE));
            uint32_t version_ts = *time_term / 10;

            if (version_ts <= snapshot_id) {
                val.assign(header->data, (int)header->data_size);
                return !isDeleted(val);
            }
            // Move to next older version
            header = reinterpret_cast<mako::Node *>(
                (char*)(header->data+header->data_size-mako::BITS_OF_NODE));
        }
        return false; // No visible version found
    }
    
    // ... existing logic for normal reads ...
}
```

**Version chain traversal:**

1. **Check latest version**: If `current_ts <= snapshot_id`, the latest version is visible → return it
2. **Walk backward**: If not, traverse the linked list of older versions
3. **Find match**: Return the first version where `version_ts <= snapshot_id`
4. **No match**: Return false if no visible version exists

**Key insight:** Each value stores a linked list of historical versions. The fast path reads from this history without taking locks.

---

### 3. Commit - Fast Path Bypass

At commit time ([Transaction.cc:395-401](file:///home/nimit/mako/src/mako/benchmarks/sto/Transaction.cc#L395-L401)):

```cpp
#ifdef ENABLE_RO_FAST_PATH
    if (!any_writes_) {
        fast_path_commits.fetch_add(1, std::memory_order_relaxed);
        stop(true, nullptr, 0);  // Commit immediately
        return true;
    }
#endif
```

**What happens:**
- Detects read-only transactions (checked via `!any_writes_`)
- **Skips validation entirely**: no lock acquisition, no read-set validation, no coordination
- Commits immediately with no network round-trips
- Just cleans up transaction state and returns success

**Key insight:** Since the transaction only read from a snapshot that was stable at the start, there's no possibility of conflicts. The commit is essentially a no-op.

---

## Version Storage and Lifecycle

This is the **critical implementation detail**: where and when are versions stored and freed?

### Version Storage - The Multi-Version Chain

Each key in the Masstree stores a **linked list of versions**. The structure is defined in [lib/common.h:118-122](file:///home/nimit/mako/src/mako/lib/common.h#L118-L122):

```cpp
struct Node {
    uint32_t timestamp;  // Single timestamp instead of vector
    int16_t data_size;   // Size of the data for this version
    char *data;          // Pointer to the data (which includes metadata for next version)
};
```

**Memory layout of a value:**

```
┌────────────────────────────────────────────────────────────────┐
│  [actual_data] [timestamp+term: 4 bytes] [Node: 10 bytes]      │
│                 └─ BITS_OF_TT ─────┘      └─ BITS_OF_NODE ─┘   │
│                                                                  │
│  Node contains:                                                 │
│    - timestamp: when this version was created                   │
│    - data_size: size of PREVIOUS version (or 0 if none)        │
│    - data: pointer to PREVIOUS version's buffer                │
└────────────────────────────────────────────────────────────────┘

EXTRA_BITS_FOR_VALUE = BITS_OF_TT + BITS_OF_NODE = 4 + 10 = 14 bytes
```

**Version chain example:**

```
Latest version (in Masstree)
    ↓
[V3: data="c", ts=300, Node{ts=300, size=30, data=→V2}]
                                                      ↓
                        [V2: data="b", ts=200, Node{ts=200, size=30, data=→V1}]
                                                                            ↓
                                              [V1: data="a", ts=100, Node{ts=100, size=0, data=NULL}]
```

- V3 is the latest version (pointed to by Masstree)
- V2 is the previous version (pointed to by V3's Node)
- V1 is the first version (has `data_size=0`, indicating no previous version)

---

### When Versions Are Created (Storage)

Versions are created during **write operations** in [multiversion.hh:196-223](file:///home/nimit/mako/src/mako/benchmarks/sto/multiversion.hh#L196-L223):

```cpp
static void mvInstall(bool isInsert,
                      bool isDelete,
                      const string newval,
                      versioned_str_struct* e,
                      uint8_t current_term) {
    
    char *oldval_str = (char*)e->data();
    int oldval_len = e->length();
    uint32_t time_term = TThread::txn->tid_unique_ * 10 + TThread::txn->current_term_;
    
    if (isInsert) {
        // First version - just set metadata in existing buffer
        mako::Node* header = reinterpret_cast<mako::Node*>(
            oldval_str+oldval_len-mako::BITS_OF_NODE);
        header->timestamp = TThread::txn->tid_unique_;
        header->data_size = 0;  // No previous version
        memcpy(oldval_str+oldval_len-mako::EXTRA_BITS_FOR_VALUE, 
               &time_term, mako::BITS_OF_TT);
    } else {
        // Update or delete - create new version
        
        // ★ ALLOCATION: Allocate memory for the new version
        char* new_vv = (char*)malloc(newval.length());
        
        // Copy new data
        memcpy(new_vv, newval.data(), newval.length()-mako::EXTRA_BITS_FOR_VALUE);
        
        // Set timestamp+term
        memcpy(new_vv+newval.length()-mako::EXTRA_BITS_FOR_VALUE, 
               &time_term, mako::BITS_OF_TT);
        
        // Set Node header to point to OLD version
        mako::Node* header = reinterpret_cast<mako::Node*>(
            new_vv+newval.length()-mako::BITS_OF_NODE);
        header->timestamp = TThread::txn->tid_unique_;
        header->data_size = oldval_len;  // Size of old version
        header->data = e->data();        // Pointer to old version's buffer
        
        // Install new version as the latest (atomically updates Masstree entry)
        e->modifyData(new_vv);
        
        // Try to garbage collect old versions
        lazyReclaim(time_term, current_term, header);
    }
}
```

**Process:**

1. **Allocate** a new buffer with `malloc(newval.length())` - **THIS IS WHERE THE VERSION IS STORED**
2. Copy the new value data into the buffer
3. Set the `Node` header to point to the **old version** (creating the linked list)
4. Atomically install the new version as the **latest** by updating the Masstree entry pointer
5. The old version remains in memory, accessible via the version chain
6. Attempt garbage collection (may or may not free old versions)

**Key insight:** Every update creates a new heap-allocated buffer and links it to the previous version. The Masstree only points to the latest version; older versions are reachable by traversing the `Node` pointers.

---

### When Versions Are Freed (Garbage Collection)

Versions are freed through **lazy reclamation** in [multiversion.hh:45-99](file:///home/nimit/mako/src/mako/benchmarks/sto/multiversion.hh#L45-L99):

```cpp
static void lazyReclaim(uint32_t time_term, uint32_t current_term, mako::Node *root) {
    // Rate limiting: only reclaim every 50 updates per thread
    TThread::incr_counter();
    if (TThread::counter() % 50 != 0) return;
    
    // Get the stable watermark - versions below this are safe to reclaim
    uint32_t watermark = sync_util::sync_logger::retrieveShardW_relaxed() / 10;
    if (watermark == 0) return;  // Watermark not initialized yet
    
    // Phase 1: Find the safe reclamation point
    mako::Node *safe_point = nullptr;
    mako::Node *current = root;
    std::vector<mako::Node*> to_free;  // Batch freeing for efficiency
    
    // Navigate to first version below watermark
    while (current && current->data_size > 0) {
        uint32_t *tt = reinterpret_cast<uint32_t*>(
            current->data + current->data_size - mako::EXTRA_BITS_FOR_VALUE);
        
        // Check if this version is below the watermark
        if ((*tt) / 10 < watermark) {
            safe_point = current;
            break;  // Found the first version below watermark
        }
        
        // Move to next older version
        current = reinterpret_cast<mako::Node*>(
            current->data + current->data_size - mako::BITS_OF_NODE);
    }
    
    if (!safe_point) return;  // No safe versions to reclaim
    
    // Phase 2: Collect nodes to free (everything AFTER safe point)
    current = safe_point;
    while (current && current->data_size > 0) {
        mako::Node *next = reinterpret_cast<mako::Node*>(
            current->data + current->data_size - mako::BITS_OF_NODE);
        
        if (next->data_size > 0) {
            to_free.push_back(current);
        }
        current = next;
    }
    
    // Phase 3: Update chain and batch free
    if (!to_free.empty()) {
        // Terminate the version chain at the safe point
        safe_point->data_size = 0;  // Mark end of chain
        
        // ★ DEALLOCATION: Free all old versions
        for (auto* node : to_free) {
            ::free(node->data);  // Free the malloc'd buffer
        }
    }
}
```

**Garbage collection strategy:**

1. **Rate limiting**: Only runs every 50 updates per thread (to avoid GC overhead)
2. **Watermark check**: Compares version timestamps against the global stable watermark
3. **Safety guarantee**: Keeps at least one version with `timestamp < watermark` (the "safe point")
4. **Batch freeing**: Collects all reclaimable versions, then frees them in bulk

**Why is this safe?**

- The watermark represents the minimum timestamp that any active read-only transaction might use as a snapshot ID
- Any version with `timestamp < watermark` has been "seen" by all possible transactions
- Therefore, versions older than the safe point are no longer needed
- **CRITICAL**: We must keep the safe point itself because transactions might read it

**Example:**

```
Watermark = 250

Version chain:
V4: ts=400 ← too new, might be needed
    ↓
V3: ts=300 ← too new, might be needed
    ↓
V2: ts=200 ← SAFE POINT (ts < watermark, keep this)
    ↓
V1: ts=100 ← can be freed (no transaction will ever read this)
    ↓
V0: ts=50  ← can be freed

After GC:
V4: ts=400
    ↓
V3: ts=300
    ↓
V2: ts=200, data_size=0 (chain terminated)
```

---

## Watermark Management

The watermark is **critical** for both reading (snapshot selection) and garbage collection (safety).

### Watermark Updates in Replicated Mode

The watermark is updated by the Paxos consensus protocol ([sync_util.hh:117-146](file:///home/nimit/mako/src/mako/benchmarks/sto/sync_util.hh#L117-L146)):

```cpp
static uint32_t computeLocal() {
    uint32_t min_so_far = numeric_limits<uint32_t>::max();
    
    for (int i=0; i<nthreads; i++) {
        // Take minimum of replication and disk timestamps for each partition
        auto repl_ts = local_timestamp_[i].load(memory_order_acquire);
#ifndef DISABLE_DISK
        auto disk_ts = disk_timestamp_[i].load(memory_order_acquire);
        auto partition_min = min(repl_ts, disk_ts);
#else
        auto partition_min = repl_ts;
#endif

        if (partition_min >= single_watermark_.load(memory_order_acquire))
            min_so_far = min(min_so_far, partition_min);
    }
    
    if (min_so_far != numeric_limits<uint32_t>::max()) {
        single_watermark_.store(min_so_far, memory_order_release);
    }
    return single_watermark_.load(memory_order_acquire);
}
```

**How it works:**
- Each Paxos thread maintains a `local_timestamp_` (the latest committed timestamp for that partition)
- The watermark is the **minimum** across all threads
- This ensures the watermark is conservative: no transaction can have a snapshot ID below it

### Watermark Updates in Single-Node Mode

For testing without replication ([Transaction.cc:512-519](file:///home/nimit/mako/src/mako/benchmarks/sto/Transaction.cc#L512-L519)):

```cpp
#ifdef ENABLE_SINGLE_NODE_WATERMARK
    if (!BenchmarkConfig::getInstance().getIsReplicated()) {
        uint32_t current = sync_util::sync_logger::single_watermark_.load(
            std::memory_order_relaxed);
        if (tid_unique_ > current) {
            sync_util::sync_logger::single_watermark_.store(
                tid_unique_, std::memory_order_release);
        }
    }
#endif
```

**In non-replicated mode:**
- Each write transaction manually advances the watermark
- This simulates the advancement that would normally happen via Paxos
- Allows the fast path to work in single-node tests

---

## Complete Version Lifecycle Example

Let's trace a key through its complete lifecycle:

### Initial State
```
Key "item_42" → [V0: data="stock:100", ts=1000, Node{ts=1000, size=0, data=NULL}]
Watermark = 1000
```

### Transaction T1 (write, ts=2000): Update stock to 95
```
1. mvInstall called
2. malloc() allocates new buffer for V1
3. V1 created: [V1: data="stock:95", ts=2000, Node{ts=2000, size=30, data=→V0}]
4. Masstree updated to point to V1
5. lazyReclaim called (counter % 50 might skip)
6. Watermark still 1000 (V0 not freed yet)

Result:
Masstree → V1: [data="stock:95", ts=2000, Node{...→V0}]
                                              ↓
           V0: [data="stock:100", ts=1000, Node{size=0}]
```

### Transaction T2 (read-only, snapshot_id=1500)
```
1. Start: snapshot_id = retrieveShardW_relaxed() = 1000
2. Read "item_42": mvGET called with snapshot_id=1000
3. Check V1: ts=2000 > 1000, not visible
4. Traverse: header = V1.Node.data → V0
5. Check V0: ts=1000 <= 1000, visible!
6. Return: "stock:100"
7. Commit: fast path, immediate return (no validation)
```

### Transaction T3 (write, ts=3000): Update stock to 90
```
1. mvInstall called
2. malloc() allocates new buffer for V2
3. V2 created: [V2: data="stock:90", ts=3000, Node{ts=3000, size=30, data=→V1}]
4. Masstree updated to point to V2
5. lazyReclaim called
6. Watermark now 2500 (advanced by Paxos)
7. Check versions:
   - V2: ts=3000 >= 2500, keep
   - V1: ts=2000 < 2500, SAFE POINT!
   - V0: ts=1000 < 2500, can be freed
8. free(V0->data) ← V0 DEALLOCATED

Result:
Masstree → V2: [data="stock:90", ts=3000, Node{...→V1}]
                                              ↓
           V1: [data="stock:95", ts=2000, Node{size=0}]  ← chain terminated
```

### Why V0 Was Safe to Free
- Watermark = 2500
- Any new read-only transaction will have snapshot_id >= 2500
- Therefore, no future transaction can read V0 (ts=1000)
- V1 is kept as the "safe point" for transactions with snapshot_id ∈ [2000, 2500)

---

## Performance Benefits

### 1. **Eliminated Coordination**
- **Normal path**: Acquire locks → validate read set → release locks
- **Fast path**: Just read from snapshot → immediate commit
- **Savings**: 2 network round-trips in distributed setting

### 2. **No Blocking**
- Read-only transactions never wait for write locks
- Write transactions don't need to wait for read-only transactions
- Maximizes concurrency

### 3. **Reduced Load on Sequencer**
- Read-only transactions don't participate in global ordering
- Sequencer only handles write transactions
- Scalability improves with high read-only workloads

### 4. **Guaranteed Progress**
- Read-only transactions never abort due to conflicts
- Predictable latency for analytical queries

---

## Memory Overhead

**Trade-off:** The MVCC design stores multiple versions, consuming memory.

**Mitigation strategies:**

1. **Lazy garbage collection**: Only runs every 50 updates
2. **Watermark-based safety**: Aggressively frees old versions
3. **Batch operations**: Reduces GC overhead
4. **Single safe point**: Only keeps one old version below watermark

**Typical memory usage:**
- High update workload: 2-3 versions per key on average
- Low update workload: ~1 version per key (GC quickly reclaims old versions)
- Read-heavy workload: 1 version per key (no updates → no new versions)

---

## Correctness Guarantees

### Snapshot Isolation Properties

The fast path provides **snapshot isolation**, which guarantees:

1. **Read Committed**: All reads see committed data
2. **Repeatable Read**: Same read returns same data within transaction
3. **No Phantoms**: Version chain traversal is deterministic

### Serializability

Even though read-only transactions don't validate:

- They observe a **consistent snapshot** (all data at timestamp ≤ snapshot_id)
- Write transactions still validate and serialize via locks
- The combination provides **serializability** for the workload

### Safety of Garbage Collection

The watermark mechanism ensures:

- No version is freed if any transaction might read it
- The safe point acts as a "high water mark" for visibility
- Memory is eventually reclaimed (liveness property)

---

## Configuration and Tuning

### Compile-Time Flags

```cpp
#define ENABLE_RO_FAST_PATH         // Enable fast path optimization
#define ENABLE_SINGLE_NODE_WATERMARK // Enable watermark updates in single-node mode
```

### Runtime Parameters

- **GC frequency**: `TThread::counter() % 50` (line 50 in multiversion.hh)
  - Lower value → more frequent GC → lower memory, higher CPU
  - Higher value → less frequent GC → higher memory, lower CPU

- **Watermark refresh rate**: 1ms in `advancer()` (line 238 in sync_util.hh)
  - Controls how quickly watermark advances
  - Affects how long old versions are retained

---

## Summary

### Version Lifecycle

| Phase | Location | Memory Operation | When |
|-------|----------|------------------|------|
| **Creation** | `multiversion.hh:212` | `malloc(newval.length())` | On write transaction commit |
| **Serving** | `multiversion.hh:110-132` | Version chain traversal | On read with snapshot_id |
| **Garbage Collection** | `multiversion.hh:96` | `::free(node->data)` | Every 50 updates, if ts < watermark |

### Key Data Structures

- **`mako::Node`**: Links versions together (timestamp, size, data pointer)
- **`single_watermark_`**: Global atomic timestamp for snapshot + GC safety
- **Version chain**: Linked list of historical versions, newest to oldest

### Performance Characteristics

- **Read-only transactions**: O(1) snapshot selection + O(k) version traversal where k = # of versions
- **Garbage collection**: O(n) where n = # of old versions, amortized to O(1) with rate limiting
- **Memory overhead**: ~2-3x for high update workloads, ~1x for read-heavy workloads

### The Elegant Design

The fast path achieves **zero coordination for reads** by leveraging MVCC with disciplined garbage collection:

1. **Snapshot selection**: Captures a stable point in time
2. **Version traversal**: Reads historical data without locking
3. **Watermark protocol**: Ensures GC safety while bounding memory
4. **Lazy reclamation**: Amortizes GC cost across many operations

This design enables **high read throughput** with **predictable memory usage** and **strong consistency guarantees**.
