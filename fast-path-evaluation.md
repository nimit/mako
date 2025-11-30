# Fast Path Evaluation

This document summarizes the performance evaluation of the Read-Only Fast Path optimization in Mako.

## 1. Replicated Benchmark (Primary Target)

```bash
bash examples/benchmark_ro_fast_path_replicated.sh && grep "OrderStatus_local_throughput" examples/fast_path.log examples/normal_path.log && grep "OrderStatus_local_commit_latency" examples/fast_path.log examples/normal_path.log
```

This benchmark represents the target deployment scenario: a distributed, replicated environment with a read-heavy workload.

### Configuration
- **Topology**: 1 Shard, 3 Replicas (1 Leader, 2 Followers), 1 Learner (Paxos).
- **Workload**: TPC-C Mixed
    - **90% OrderStatus** (Read-Only)
    - **10% NewOrder** (Read-Write)
- **Concurrency**: 4 Threads per node.

### Results

| Metric | Fast Path | Normal Path | Improvement |
| :--- | :--- | :--- | :--- |
| **Throughput** | **149,802 ops/sec** | 141,931 ops/sec | **+5.55%** |
| **Latency** | **0.014 ms** | 0.016 ms | **-9.7%** |

### Analysis
The Fast Path delivers a **5.5% throughput improvement** and nearly **10% latency reduction** in this replicated setting.
*   **Why**: In a replicated system, the "Normal Path" for read-only transactions still requires participation in the commit protocol (or at least validation) which involves coordination and potential blocking. The Fast Path completely bypasses this by reading from a consistent snapshot, freeing up leader resources and avoiding network round-trips for validation.
*   **Significance**: This confirms the optimization is effective for its intended use case (distributed, read-heavy workloads).

---

## 2. Single Node Benchmark (Baseline/Validation)

This benchmark was conducted on a single node to validate correctness and understand the overheads in a low-contention, non-distributed environment.

### Configuration
- **Topology**: Single Node (Localhost), No Replication.
- **Workload**: TPC-C Mixed
    - **50% OrderStatus** (Read-Only)
    - **50% NewOrder** (Read-Write)
- **Concurrency**: 4 Threads.

### Results

| Metric | Fast Path | Normal Path | Difference |
| :--- | :--- | :--- | :--- |
| **Throughput** | 90,918 ops/sec | **135,444 ops/sec** | -32.8% |
| **Latency** | 0.043 ms | **0.029 ms** | +48.2% |

### Analysis
In a single-node, low-contention environment, the Fast Path performed **worse** than the Normal Path.
*   **Overhead**: The Fast Path introduces overhead for managing snapshot IDs (atomic updates) and traversing version chains in `mvGET`.
*   **Lack of Contention**: With only 4 threads and no network latency, the "Normal Path" is extremely fast because it rarely aborts or blocks. The cost of validation is negligible compared to the cost of multi-version traversal.
*   **Conclusion**: The Fast Path is not beneficial for single-node, low-contention deployments. Its benefits are realized when the cost of coordination (replication/consensus) or contention (blocking) is high.

---

## 3. Overall Conclusion

The Read-Only Fast Path is a **successful optimization for distributed deployments**.

*   **Effective in Production Scenarios**: It provides tangible throughput and latency gains (5-10%) in replicated environments where coordination costs are non-trivial.
*   **Trade-off**: It incurs a CPU overhead for version traversal, which makes it less suitable for single-node or extremely low-contention scenarios.
*   **Recommendation**: Enable the Fast Path for replicated clusters, especially those serving read-heavy workloads. For standalone testing or single-node deployments, the Normal Path may be preferred.
