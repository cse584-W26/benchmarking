# Benchmarking

Benchmarks for Jaseci's object-spatial graph runtime, focusing on traversal performance with and without the **SAM + GTI (Graph Topology Index)** optimization layers.

**Repository:** [cse584-W26/benchmarking](https://github.com/cse584-W26/benchmarking.git)

## Contents

### `graph-query-bench/`

End-to-end benchmark comparing walker traversal strategies against a SQLite-backed persistent store. Measures wall-clock time for type-filtered traversals (`[-->(?:Type)]`) with the GTI index **disabled**, **enabled (cold)**, and **enabled (warm)**.

**Scenarios covered:**
1. **Node-type filter** — `[-->(?:TargetNode)]` across various fan-out and selectivity combinations
2. **Inheritance query** — `[-->(?:BaseContent)]` using MRO-aware indexes
3. **Wildcard traversal** — `[-->]` (verifies zero overhead when no filter is active)
4. **Edge-type filter** — `[-[FollowEdge]->]` via SAM column lookup
5. **Combined filter** — `[-[FollowEdge]->(?:PostNode)]` using SAM intersection

**Starting the server (local — SQLite):**
```bash
cd graph-query-bench
jac start
```

**Starting the server (Kubernetes):**
```bash
cd graph-query-bench
./deploy.sh      # deploys to k8s cluster
./teardown.sh    # removes the deployment
```

See [FINDINGS.md](graph-query-bench/FINDINGS.md) for benchmark results and [DISCUSSION.md](graph-query-bench/DISCUSSION.md) for the design discussion behind the topology index approach.

### `becnhmarking_with_jac_run/`

Standalone Jac benchmark (`bench_gt_am.jac`) that exercises the GTI + SAM layers directly via `jac run`.

```bash
cd becnhmarking_with_jac_run
jac run bench_gt_am.jac
```
