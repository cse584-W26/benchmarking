"""
Graph Query Benchmark
=====================
Directly benchmarks the SAM/GTI topology index optimization in the Jaseci runtime
by toggling JAC_INDEX_ENABLED between runs on the same graph.

No simulation — uses the real runtime (SqliteMemory topology tables + sam_gti).

Three paths measured per scenario:
  OFF      JAC_INDEX_ENABLED=false  edge-list loop, load ALL neighbors, filter in memory
  ON cold  JAC_INDEX_ENABLED=true   first traversal after SAM eviction: SAM miss → GTI → warms SAM
  ON warm  JAC_INDEX_ENABLED=true   subsequent traversals: SAM hit → bulk fetch only

Scenarios:
  1. Single-hop     root –BenchRoot→ [TargetNode | OtherNode],  query (?:TargetNode)
  2. Inheritance    root –BenchRoot→ [PostNode | CommentNode | OtherNode], query (?:BaseContent)
  3. Multi-hop      root –BenchRoot→ MidNode → [TargetNode | OtherNode],  2-hop query
  4. Edge filter    root –[FollowEdge|LikeEdge]→ [PostNode | OtherNode],
                    query edge-only [-[FollowEdge]->] and combined [-[FollowEdge]->(?:PostNode)]

Each walker creates an isolated BenchRoot container, benchmarks, then deletes it,
so repeated runs do not accumulate stale graph state on root.

Run:
  cd benchmarking/graph-query-bench
  jac install
  jac start main.jac --dev
"""

import os;
import from time { perf_counter }
import from jaclang.jac0core.runtime { JacRuntimeInterface }
import from jaclang.runtimelib.sam_gti {
    sam_clear,
    sam_invalidate,
    reset_stats,
    _stats
}

# ============================================================================
# GRAPH NODES
# ============================================================================

# Container for isolated benchmark subgraphs — never queried, just a root scope.
node BenchRoot {}

# Single-hop & multi-hop
node TargetNode { has val: int = 0; }
node OtherNode  { has val: int = 0; }

# Inheritance: PostNode and CommentNode both inherit BaseContent.
# am_put fans out to ["PostNode","BaseContent"] and ["CommentNode","BaseContent"]
# so [bench-->(?:BaseContent)] resolves both subtypes via a single AM/GT lookup.
node BaseContent             { has val: int = 0; }
node PostNode(BaseContent)   { has val: int = 0; }
node CommentNode(BaseContent){ has val: int = 0; }

# Multi-hop intermediate layer
node MidNode { has val: int = 0; }

# Edge-filter scenario: two distinct edge types to demonstrate e: SAM columns
edge FollowEdge {}
edge LikeEdge   {}

# ============================================================================
# SHARED HELPERS (inline, no import from am_store)
# ============================================================================

def _avg(times: list) -> float {
    return sum(times) / len(times) if times else 0.0;
}

def _speedup(baseline: float, fast: float) -> float {
    return round(baseline / fast, 1) if fast > 0 else 0.0;
}

# Collect node IDs from a result list.
def _ids(nodes: list) -> set {
    s: set = set();
    for n in nodes { s.add(n.__jac__.id); }
    return s;
}

# Compare expected IDs (set) against a query result list.
# Returns a dict with ok flag + counts of missing/extra nodes.
def _check(expected: set, actual: list) -> dict {
    actual_ids = _ids(actual);
    missing    = len(expected - actual_ids);
    extra      = len(actual_ids - expected);
    return {
        "ok":             missing == 0 and extra == 0,
        "expected_count": len(expected),
        "actual_count":   len(actual_ids),
        "missing_count":  missing,
        "extra_count":    extra
    };
}

# ============================================================================
# SCENARIO 1 — SINGLE-HOP
# Graph:  BenchRoot → [TargetNode × n_targets | OtherNode × n_others]
# OFF:    edge-list loop, loads all n_targets+n_others, filters by type
# ON:     index resolves TargetNode IDs → bulk-fetch only n_targets
# ============================================================================

walker:pub bench_single_hop {
    has n_targets: int = 5,
        n_others:  int = 45,
        iterations: int = 5;

    can run with Root entry {
        import os;

        # ---- Build isolated subgraph ----
        bench = (here ++> BenchRoot())[0];
        for i in range(self.n_targets) { bench ++> TargetNode(val=i); }
        for i in range(self.n_others)  { bench ++> OtherNode(val=i); }

        ctx = JacRuntimeInterface.get_context();
        fan_out = self.n_targets + self.n_others;
        sel     = self.n_targets / fan_out if fan_out > 0 else 0.0;

        # ---- OFF path: index disabled ----
        os.environ["JAC_INDEX_ENABLED"] = "false";
        off_times: list = [];
        for _ in range(self.iterations) {
            # Re-stub before every iteration: populate() mutates stubs in-place,
            # so without this each iteration after the first would use live objects.
            bench.__jac__.edges = [e.make_stub() for e in bench.__jac__.edges];
            ctx.mem.__mem__.clear();
            t0 = perf_counter();
            off_results = [bench-->(?:TargetNode)];
            t1 = perf_counter();
            off_times.append((t1 - t0) * 1000.0);
        }

        # ---- Correctness baseline: OFF results are the ground truth ----
        # Verify the non-indexed full-scan returned exactly n_targets nodes.
        expected_ids = _ids(off_results);
        off_correct  = {
            "ok":             len(off_results) == self.n_targets,
            "expected_count": self.n_targets,
            "actual_count":   len(off_results),
            "missing_count":  max(0, self.n_targets - len(off_results)),
            "extra_count":    max(0, len(off_results) - self.n_targets)
        };

        # ---- ON cold path: SAM miss → GTI → warms SAM ----
        os.environ["JAC_INDEX_ENABLED"] = "true";
        cold_times: list = [];
        for _ in range(self.iterations) {
            sam_clear();
            reset_stats();
            ctx.mem.__mem__.clear();
            t0 = perf_counter();
            [bench-->(?:TargetNode)];
            t1 = perf_counter();
            cold_times.append((t1 - t0) * 1000.0);
        }
        cold_stats  = dict(_stats);
        on_cold_ms  = _avg(cold_times[1:] if len(cold_times) > 1 else cold_times);

        # Correctness: ON cold must return the same nodes as OFF.
        ctx.mem.__mem__.clear();
        cold_correct = _check(expected_ids, [bench-->(?:TargetNode)]);

        # ---- ON warm path: SAM hit ----
        on_warm_times: list = [];
        for _ in range(self.iterations) {
            ctx.mem.__mem__.clear();   # evict L1, keep AM warm
            reset_stats();
            t0 = perf_counter();
            [bench-->(?:TargetNode)];
            t1 = perf_counter();
            on_warm_times.append((t1 - t0) * 1000.0);
        }

        # Correctness: ON warm must return the same nodes as OFF.
        ctx.mem.__mem__.clear();
        warm_correct = _check(expected_ids, [bench-->(?:TargetNode)]);

        # ---- Cleanup: delete subgraph ----
        bench_id = bench.__jac__.id;
        for child in [bench-->] { del child; }
        del bench;
        sam_invalidate(bench_id);
        os.environ["JAC_INDEX_ENABLED"] = "true";

        avg_off  = _avg(off_times[1:] if len(off_times) > 1 else off_times);
        avg_warm = _avg(on_warm_times[1:] if len(on_warm_times) > 1 else on_warm_times);

        report {
            "scenario":       "single-hop",
            "fan_out":        fan_out,
            "selectivity":    round(sel, 2),
            "off_avg_ms":     round(avg_off, 3),
            "on_cold_ms":     round(on_cold_ms, 3),
            "on_warm_avg_ms": round(avg_warm, 3),
            "speedup_cold":   _speedup(avg_off, on_cold_ms),
            "speedup_warm":   _speedup(avg_off, avg_warm),
            "n_results":      len(off_results),
            "cold_stats":     cold_stats,
            "iterations":     self.iterations,
            "correctness": {
                "off":     off_correct,
                "on_cold": cold_correct,
                "on_warm": warm_correct,
                "all_ok":  off_correct["ok"] and cold_correct["ok"] and warm_correct["ok"]
            }
        };
    }
}

# ============================================================================
# SCENARIO 2 — INHERITANCE  (MRO fan-out)
# Graph:  BenchRoot → [PostNode × n_post | CommentNode × n_comment | OtherNode × n_other]
# Query:  [bench-->(?:BaseContent)]
# am_put writes each PostNode under ["PostNode","BaseContent"] at ++> time,
# and each CommentNode under ["CommentNode","BaseContent"].
# So AM/GT resolve the "BaseContent" bucket at O(1) without subtype enumeration.
# ============================================================================

walker:pub bench_inheritance {
    has n_post:    int = 8,
        n_comment: int = 8,
        n_other:   int = 34,
        iterations: int = 5;

    can run with Root entry {
        import os;

        # ---- Build isolated subgraph ----
        bench = (here ++> BenchRoot())[0];
        for i in range(self.n_post)    { bench ++> PostNode(val=i); }
        for i in range(self.n_comment) { bench ++> CommentNode(val=i); }
        for i in range(self.n_other)   { bench ++> OtherNode(val=i); }

        ctx     = JacRuntimeInterface.get_context();
        fan_out = self.n_post + self.n_comment + self.n_other;
        sel     = (self.n_post + self.n_comment) / fan_out if fan_out > 0 else 0.0;

        # ---- OFF path ----
        os.environ["JAC_INDEX_ENABLED"] = "false";
        off_times: list = [];
        for _ in range(self.iterations) {
            # Re-stub before every iteration: populate() mutates stubs in-place,
            # so without this each iteration after the first would use live objects.
            bench.__jac__.edges = [e.make_stub() for e in bench.__jac__.edges];
            ctx.mem.__mem__.clear();
            t0 = perf_counter();
            off_results = [bench-->(?:BaseContent)];
            t1 = perf_counter();
            off_times.append((t1 - t0) * 1000.0);
        }

        # ---- Correctness baseline: OFF results are the ground truth ----
        # Expected: all PostNode + CommentNode instances (both inherit BaseContent).
        n_expected   = self.n_post + self.n_comment;
        expected_ids = _ids(off_results);
        off_correct  = {
            "ok":             len(off_results) == n_expected,
            "expected_count": n_expected,
            "actual_count":   len(off_results),
            "missing_count":  max(0, n_expected - len(off_results)),
            "extra_count":    max(0, len(off_results) - n_expected)
        };

        # ---- ON cold path ----
        os.environ["JAC_INDEX_ENABLED"] = "true";
        cold_times: list = [];
        for _ in range(self.iterations) {
            sam_clear();
            reset_stats();
            ctx.mem.__mem__.clear();
            t0 = perf_counter();
            [bench-->(?:BaseContent)];
            t1 = perf_counter();
            cold_times.append((t1 - t0) * 1000.0);
        }
        cold_stats = dict(_stats);
        on_cold_ms = _avg(cold_times[1:] if len(cold_times) > 1 else cold_times);

        # Correctness: ON cold must return the same nodes as OFF.
        ctx.mem.__mem__.clear();
        cold_correct = _check(expected_ids, [bench-->(?:BaseContent)]);

        # ---- ON warm path ----
        on_warm_times: list = [];
        for _ in range(self.iterations) {
            ctx.mem.__mem__.clear();
            reset_stats();
            t0 = perf_counter();
            [bench-->(?:BaseContent)];
            t1 = perf_counter();
            on_warm_times.append((t1 - t0) * 1000.0);
        }

        # Correctness: ON warm must return the same nodes as OFF.
        ctx.mem.__mem__.clear();
        warm_correct = _check(expected_ids, [bench-->(?:BaseContent)]);

        # ---- Cleanup ----
        bench_id = bench.__jac__.id;
        for child in [bench-->] { del child; }
        del bench;
        sam_invalidate(bench_id);
        os.environ["JAC_INDEX_ENABLED"] = "true";

        avg_off  = _avg(off_times[1:] if len(off_times) > 1 else off_times);
        avg_warm = _avg(on_warm_times[1:] if len(on_warm_times) > 1 else on_warm_times);

        report {
            "scenario":       "inheritance",
            "fan_out":        fan_out,
            "selectivity":    round(sel, 2),
            "off_avg_ms":     round(avg_off, 3),
            "on_cold_ms":     round(on_cold_ms, 3),
            "on_warm_avg_ms": round(avg_warm, 3),
            "speedup_cold":   _speedup(avg_off, on_cold_ms),
            "speedup_warm":   _speedup(avg_off, avg_warm),
            "n_results":      len(off_results),
            "cold_stats":     cold_stats,
            "iterations":     self.iterations,
            "correctness": {
                "off":     off_correct,
                "on_cold": cold_correct,
                "on_warm": warm_correct,
                "all_ok":  off_correct["ok"] and cold_correct["ok"] and warm_correct["ok"]
            }
        };
    }
}

# ============================================================================
# SCENARIO 3 — MULTI-HOP  (2-hop)
# Graph:  BenchRoot → MidNode[i] → [TargetNode × n_bt | OtherNode × n_bo]
# OFF:    hop1=[bench-->(?:MidNode)], hop2=for each mid: [mid-->(?:TargetNode)]
#         → loads all mid bodies + all children of each mid, filters in memory
# ON:     same expression; index resolves at each hop:
#         hop1: bench_id "MidNode" → mid_ids
#         hop2: mid_id   "TargetNode" → target_ids (per mid)
# Total ON warm fetches = n_mid × n_bt  vs  OFF = n_mid + n_mid×(n_bt+n_bo)
# ============================================================================

walker:pub bench_multihop {
    has n_mid:    int = 15,
        n_bt:     int = 6,    # branch TargetNodes per MidNode
        n_bo:     int = 14,   # branch OtherNodes per MidNode
        iterations: int = 5;

    can run with Root entry {
        import os;

        # ---- Build isolated subgraph ----
        bench = (here ++> BenchRoot())[0];
        for i in range(self.n_mid) {
            mid = (bench ++> MidNode(val=i))[0];
            for j in range(self.n_bt) { mid ++> TargetNode(val=j); }
            for j in range(self.n_bo) { mid ++> OtherNode(val=j); }
        }

        ctx          = JacRuntimeInterface.get_context();
        branch_total = self.n_bt + self.n_bo;
        sel          = self.n_bt / branch_total if branch_total > 0 else 0.0;

        def _run_2hop -> list {
            mids = [bench-->(?:MidNode)];
            targets: list = [];
            for mid in mids { targets += [mid-->(?:TargetNode)]; }
            return targets;
        }

        # ---- OFF path ----
        os.environ["JAC_INDEX_ENABLED"] = "false";
        off_times: list = [];
        for _ in range(self.iterations) {
            # Re-stub before every iteration: populate() mutates stubs in-place,
            # so without this each iteration after the first would use live objects.
            # MidNode anchors from SQLite already carry stub edges (via __getstate__),
            # so the second hop also goes cold automatically.
            bench.__jac__.edges = [e.make_stub() for e in bench.__jac__.edges];
            ctx.mem.__mem__.clear();
            t0 = perf_counter();
            off_results = _run_2hop();
            t1 = perf_counter();
            off_times.append((t1 - t0) * 1000.0);
        }

        # ---- Correctness baseline: OFF results are the ground truth ----
        # Expected: n_mid × n_bt TargetNodes across all branches.
        n_expected   = self.n_mid * self.n_bt;
        expected_ids = _ids(off_results);
        off_correct  = {
            "ok":             len(off_results) == n_expected,
            "expected_count": n_expected,
            "actual_count":   len(off_results),
            "missing_count":  max(0, n_expected - len(off_results)),
            "extra_count":    max(0, len(off_results) - n_expected)
        };

        # ---- ON cold path ----
        os.environ["JAC_INDEX_ENABLED"] = "true";
        cold_times: list = [];
        for _ in range(self.iterations) {
            sam_clear();
            reset_stats();
            ctx.mem.__mem__.clear();
            t0 = perf_counter();
            _run_2hop();
            t1 = perf_counter();
            cold_times.append((t1 - t0) * 1000.0);
        }
        cold_stats = dict(_stats);
        on_cold_ms = _avg(cold_times[1:] if len(cold_times) > 1 else cold_times);

        # Correctness: ON cold must return the same nodes as OFF.
        ctx.mem.__mem__.clear();
        cold_correct = _check(expected_ids, _run_2hop());

        # ---- ON warm path ----
        on_warm_times: list = [];
        for _ in range(self.iterations) {
            ctx.mem.__mem__.clear();
            reset_stats();
            t0 = perf_counter();
            _run_2hop();
            t1 = perf_counter();
            on_warm_times.append((t1 - t0) * 1000.0);
        }

        # Correctness: ON warm must return the same nodes as OFF.
        ctx.mem.__mem__.clear();
        warm_correct = _check(expected_ids, _run_2hop());

        # ---- Cleanup ----
        bench_id = bench.__jac__.id;
        for mid in [bench-->(?:MidNode)] {
            mid_id = mid.__jac__.id;
            for child in [mid-->] { del child; }
            del mid;
            sam_invalidate(mid_id);
        }
        del bench;
        sam_invalidate(bench_id);
        os.environ["JAC_INDEX_ENABLED"] = "true";

        avg_off  = _avg(off_times[1:] if len(off_times) > 1 else off_times);
        avg_warm = _avg(on_warm_times[1:] if len(on_warm_times) > 1 else on_warm_times);

        report {
            "scenario":       "multi-hop",
            "n_mid":          self.n_mid,
            "branch_factor":  branch_total,
            "selectivity":    round(sel, 2),
            "off_avg_ms":     round(avg_off, 3),
            "on_cold_ms":     round(on_cold_ms, 3),
            "on_warm_avg_ms": round(avg_warm, 3),
            "speedup_cold":   _speedup(avg_off, on_cold_ms),
            "speedup_warm":   _speedup(avg_off, avg_warm),
            "n_results":      len(off_results),
            "cold_stats":     cold_stats,
            "iterations":     self.iterations,
            "correctness": {
                "off":     off_correct,
                "on_cold": cold_correct,
                "on_warm": warm_correct,
                "all_ok":  off_correct["ok"] and cold_correct["ok"] and warm_correct["ok"]
            }
        };
    }
}

# ============================================================================
# SCENARIO 4 — EDGE FILTER
# Graph:  BenchRoot –[FollowEdge]→ [PostNode × n_follow_post | OtherNode × n_follow_other]
#                  –[LikeEdge]→   PostNode × n_like_post
# Queries measured:
#   A. edge-only:   [-[FollowEdge]->]              → SAM "e:FollowEdge" column
#   B. combined:    [-[FollowEdge]->(?:PostNode)]  → intersect(sam["e:FollowEdge"], sam["n:PostNode"])
# OFF: full edge-list loop — iterates all edges, checks isinstance + edge type in Python
# ON:  SAM resolves each query in O(1) / O(intersection), then bulk-fetches only matches
# ============================================================================

walker:pub bench_edge_filter {
    has n_follow_post:  int = 20,   # FollowEdge → PostNode  (matches both queries)
        n_follow_other: int = 30,   # FollowEdge → OtherNode (matches edge-only, not combined)
        n_like_post:    int = 50,   # LikeEdge   → PostNode  (matches neither FollowEdge query)
        iterations:     int = 5;

    can run with Root entry {
        import os;

        # ---- Build isolated subgraph ----
        bench = (here ++> BenchRoot())[0];
        for i in range(self.n_follow_post)  { bench +>: FollowEdge() :+> PostNode(val=i);  }
        for i in range(self.n_follow_other) { bench +>: FollowEdge() :+> OtherNode(val=i); }
        for i in range(self.n_like_post)    { bench +>: LikeEdge()   :+> PostNode(val=i);  }

        ctx      = JacRuntimeInterface.get_context();
        fan_out  = self.n_follow_post + self.n_follow_other + self.n_like_post;
        n_edge   = self.n_follow_post + self.n_follow_other;  # matches edge-only query
        n_comb   = self.n_follow_post;                        # matches combined query

        def _run_edge -> list { return [bench ->:FollowEdge:->]; }
        def _run_comb -> list { return [bench ->:FollowEdge:-> (?:PostNode)]; }

        # ---- OFF: edge-only ----
        os.environ["JAC_INDEX_ENABLED"] = "false";
        off_edge_times: list = [];
        off_edge_results: list = [];
        for _ in range(self.iterations) {
            bench.__jac__.edges = [e.make_stub() for e in bench.__jac__.edges];
            ctx.mem.__mem__.clear();
            t0 = perf_counter();
            off_edge_results = _run_edge();
            t1 = perf_counter();
            off_edge_times.append((t1 - t0) * 1000.0);
        }

        # ---- OFF: combined ----
        off_comb_times: list = [];
        off_comb_results: list = [];
        for _ in range(self.iterations) {
            bench.__jac__.edges = [e.make_stub() for e in bench.__jac__.edges];
            ctx.mem.__mem__.clear();
            t0 = perf_counter();
            off_comb_results = _run_comb();
            t1 = perf_counter();
            off_comb_times.append((t1 - t0) * 1000.0);
        }

        # ---- Correctness baseline: OFF results are the ground truth ----
        expected_edge_ids = _ids(off_edge_results);
        expected_comb_ids = _ids(off_comb_results);
        off_edge_correct  = {
            "ok":             len(off_edge_results) == n_edge,
            "expected_count": n_edge,
            "actual_count":   len(off_edge_results),
            "missing_count":  max(0, n_edge - len(off_edge_results)),
            "extra_count":    max(0, len(off_edge_results) - n_edge)
        };
        off_comb_correct  = {
            "ok":             len(off_comb_results) == n_comb,
            "expected_count": n_comb,
            "actual_count":   len(off_comb_results),
            "missing_count":  max(0, n_comb - len(off_comb_results)),
            "extra_count":    max(0, len(off_comb_results) - n_comb)
        };

        # ---- ON cold: edge-only ----
        os.environ["JAC_INDEX_ENABLED"] = "true";
        cold_edge_times: list = [];
        for _ in range(self.iterations) {
            sam_clear();
            reset_stats();
            ctx.mem.__mem__.clear();
            t0 = perf_counter();
            _run_edge();
            t1 = perf_counter();
            cold_edge_times.append((t1 - t0) * 1000.0);
        }
        cold_edge_stats = dict(_stats);

        # Correctness: ON cold edge-only must match OFF.
        ctx.mem.__mem__.clear();
        cold_edge_correct = _check(expected_edge_ids, _run_edge());

        # ---- ON cold: combined ----
        cold_comb_times: list = [];
        for _ in range(self.iterations) {
            sam_clear();
            reset_stats();
            ctx.mem.__mem__.clear();
            t0 = perf_counter();
            _run_comb();
            t1 = perf_counter();
            cold_comb_times.append((t1 - t0) * 1000.0);
        }
        cold_comb_stats = dict(_stats);

        # Correctness: ON cold combined must match OFF.
        ctx.mem.__mem__.clear();
        cold_comb_correct = _check(expected_comb_ids, _run_comb());

        # ---- ON warm: edge-only (SAM already populated from cold runs) ----
        warm_edge_times: list = [];
        for _ in range(self.iterations) {
            ctx.mem.__mem__.clear();
            reset_stats();
            t0 = perf_counter();
            _run_edge();
            t1 = perf_counter();
            warm_edge_times.append((t1 - t0) * 1000.0);
        }

        # Correctness: ON warm edge-only must match OFF.
        ctx.mem.__mem__.clear();
        warm_edge_correct = _check(expected_edge_ids, _run_edge());

        # ---- ON warm: combined ----
        warm_comb_times: list = [];
        for _ in range(self.iterations) {
            ctx.mem.__mem__.clear();
            reset_stats();
            t0 = perf_counter();
            _run_comb();
            t1 = perf_counter();
            warm_comb_times.append((t1 - t0) * 1000.0);
        }

        # Correctness: ON warm combined must match OFF.
        ctx.mem.__mem__.clear();
        warm_comb_correct = _check(expected_comb_ids, _run_comb());

        # ---- Cleanup ----
        bench_id = bench.__jac__.id;
        for child in [bench-->] { del child; }
        del bench;
        sam_invalidate(bench_id);
        os.environ["JAC_INDEX_ENABLED"] = "true";

        avg_off_edge  = _avg(off_edge_times[1:] if len(off_edge_times) > 1 else off_edge_times);
        avg_off_comb  = _avg(off_comb_times[1:] if len(off_comb_times) > 1 else off_comb_times);
        avg_warm_edge = _avg(warm_edge_times[1:] if len(warm_edge_times) > 1 else warm_edge_times);
        avg_warm_comb = _avg(warm_comb_times[1:] if len(warm_comb_times) > 1 else warm_comb_times);
        on_cold_edge  = _avg(cold_edge_times[1:] if len(cold_edge_times) > 1 else cold_edge_times);
        on_cold_comb  = _avg(cold_comb_times[1:] if len(cold_comb_times) > 1 else cold_comb_times);

        report {
            "scenario":         "edge-filter",
            "fan_out":          fan_out,
            "n_follow":         n_edge,
            "n_combined":       n_comb,
            # edge-only sub-result
            "edge_off_ms":      round(avg_off_edge, 3),
            "edge_cold_ms":     round(on_cold_edge, 3),
            "edge_warm_ms":     round(avg_warm_edge, 3),
            "edge_speedup_cold": _speedup(avg_off_edge, on_cold_edge),
            "edge_speedup_warm": _speedup(avg_off_edge, avg_warm_edge),
            "edge_cold_stats":  cold_edge_stats,
            # combined sub-result
            "comb_off_ms":      round(avg_off_comb, 3),
            "comb_cold_ms":     round(on_cold_comb, 3),
            "comb_warm_ms":     round(avg_warm_comb, 3),
            "comb_speedup_cold": _speedup(avg_off_comb, on_cold_comb),
            "comb_speedup_warm": _speedup(avg_off_comb, avg_warm_comb),
            "comb_cold_stats":  cold_comb_stats,
            "iterations":       self.iterations,
            "correctness": {
                "off_edge":        off_edge_correct,
                "off_comb":        off_comb_correct,
                "cold_edge":       cold_edge_correct,
                "cold_comb":       cold_comb_correct,
                "warm_edge":       warm_edge_correct,
                "warm_comb":       warm_comb_correct,
                "all_ok": (
                    off_edge_correct["ok"] and off_comb_correct["ok"] and
                    cold_edge_correct["ok"] and cold_comb_correct["ok"] and
                    warm_edge_correct["ok"] and warm_comb_correct["ok"]
                )
            }
        };
    }
}

# ============================================================================
# RUN ALL — full fan_out × selectivity grid for heatmap
# ============================================================================

walker:pub run_all_scenarios {
    has iterations: int = 5;

    can run_all with Root entry {
        import os;
        ctx         = JacRuntimeInterface.get_context();
        fan_outs    = [5, 50, 200, 500, 1000];
        selectivities = [0.1, 0.25, 0.5, 0.75, 0.9];
        all_results: list = [];
        heatmap:     dict = {};

        for fan_out in fan_outs {
            for sel in selectivities {
                n_targets = int(fan_out * sel);
                n_others  = fan_out - n_targets;

                bench = (here ++> BenchRoot())[0];
                for i in range(n_targets) { bench ++> TargetNode(val=i); }
                for i in range(n_others)  { bench ++> OtherNode(val=i); }

                # OFF
                os.environ["JAC_INDEX_ENABLED"] = "false";
                off_times: list = [];
                for _ in range(self.iterations) {
                    bench.__jac__.edges = [e.make_stub() for e in bench.__jac__.edges];
                    ctx.mem.__mem__.clear();
                    t0 = perf_counter();
                    [bench-->(?:TargetNode)];
                    t1 = perf_counter();
                    off_times.append((t1 - t0) * 1000.0);
                }

                # ON cold
                os.environ["JAC_INDEX_ENABLED"] = "true";
                cold_times: list = [];
                for _ in range(self.iterations) {
                    sam_clear();
                    reset_stats();
                    ctx.mem.__mem__.clear();
                    t0 = perf_counter();
                    [bench-->(?:TargetNode)];
                    t1 = perf_counter();
                    cold_times.append((t1 - t0) * 1000.0);
                }
                on_cold_ms = _avg(cold_times[1:] if len(cold_times) > 1 else cold_times);

                # ON warm
                on_warm_times: list = [];
                for _ in range(self.iterations) {
                    ctx.mem.__mem__.clear();
                    reset_stats();
                    t0 = perf_counter();
                    [bench-->(?:TargetNode)];
                    t1 = perf_counter();
                    on_warm_times.append((t1 - t0) * 1000.0);
                }

                # ---- Correctness checks (before cleanup) ----
                os.environ["JAC_INDEX_ENABLED"] = "false";
                ctx.mem.__mem__.clear();
                off_results  = [bench-->(?:TargetNode)];
                expected_ids = _ids(off_results);
                off_correct  = {
                    "ok":             len(off_results) == n_targets,
                    "expected_count": n_targets,
                    "actual_count":   len(off_results),
                    "missing_count":  max(0, n_targets - len(off_results)),
                    "extra_count":    max(0, len(off_results) - n_targets)
                };
                os.environ["JAC_INDEX_ENABLED"] = "true";
                sam_clear();
                ctx.mem.__mem__.clear();
                cold_correct = _check(expected_ids, [bench-->(?:TargetNode)]);
                ctx.mem.__mem__.clear();
                warm_correct = _check(expected_ids, [bench-->(?:TargetNode)]);

                # Cleanup
                bench_id = bench.__jac__.id;
                for child in [bench-->] { del child; }
                del bench;
                sam_invalidate(bench_id);
                os.environ["JAC_INDEX_ENABLED"] = "true";
                sam_clear();
                ctx.mem.__mem__.clear();

                avg_off  = _avg(off_times[1:] if len(off_times) > 1 else off_times);
                avg_warm = _avg(on_warm_times[1:] if len(on_warm_times) > 1 else on_warm_times);
                sp_cold  = _speedup(avg_off, on_cold_ms);
                sp_warm  = _speedup(avg_off, avg_warm);

                result = {
                    "scenario":       "single-hop",
                    "fan_out":        fan_out,
                    "selectivity":    round(sel, 2),
                    "off_avg_ms":     round(avg_off, 3),
                    "on_cold_ms":     round(on_cold_ms, 3),
                    "on_warm_avg_ms": round(avg_warm, 3),
                    "speedup_cold":   sp_cold,
                    "speedup_warm":   sp_warm,
                    "iterations":     self.iterations,
                    "correctness": {
                        "off":     off_correct,
                        "on_cold": cold_correct,
                        "on_warm": warm_correct,
                        "all_ok":  off_correct["ok"] and cold_correct["ok"] and warm_correct["ok"]
                    }
                };
                all_results.append(result);

                sel_key = str(int(sel * 100));
                fo_key  = str(fan_out);
                if sel_key not in heatmap { heatmap[sel_key] = {}; }
                heatmap[sel_key][fo_key] = {
                    "speedup_cold": sp_cold,
                    "speedup_warm": sp_warm
                };
            }
        }

        report {"results": all_results, "heatmap": heatmap};
    }
}

# ============================================================================
# CLEAR — remove any leftover BenchRoot containers from interrupted runs
# ============================================================================

walker:pub clear_graph {
    can clear with Root entry {
        for bench in [here-->(?:BenchRoot)] {
            bench_id = bench.__jac__.id;
            for mid in [bench-->(?:MidNode)] {
                mid_id = mid.__jac__.id;
                for child in [mid-->] { del child; }
                del mid;
                sam_invalidate(mid_id);
            }
            for child in [bench-->] { del child; }
            del bench;
            sam_invalidate(bench_id);
        }
        sam_clear();
        report {"status": "cleared"};
    }
}

# ============================================================================
# FRONTEND
# ============================================================================

cl {
    def:pub app -> JsxElement {
        # Shared
        has activeTab: str = "singlehop";

        # Single-hop tab
        has fanOut: int = 50,
            selectivity: float = 0.1,
            iterations: int = 5,
            shLoading: bool = False,
            shStatus: str = "",
            shError: str = "",
            shResults: list = [],
            shHeatmap: dict = {},
            showHeatmap: bool = False,
            runningAll: bool = False;

        # Inheritance tab
        has inhFanOut: int = 50,
            inhSel: float = 0.32,
            inhIters: int = 5,
            inhLoading: bool = False,
            inhStatus: str = "",
            inhError: str = "",
            inhResults: list = [];

        # Multi-hop tab
        has mhMid: int = 15,
            mhBt: int = 6,
            mhBo: int = 14,
            mhIters: int = 5,
            mhLoading: bool = False,
            mhStatus: str = "",
            mhError: str = "",
            mhResults: list = [];

        # Edge filter tab
        has efFollowPost: int = 20,
            efFollowOther: int = 30,
            efLikePost: int = 50,
            efIters: int = 5,
            efLoading: bool = False,
            efStatus: str = "",
            efError: str = "",
            efResults: list = [];

        # ---- Single-hop handlers ----
        async def handleBenchSingleHop -> None {
            shLoading = True;
            shStatus = "Running...";
            shError = "";
            try {
                n_targets = int(fanOut * selectivity);
                n_others  = fanOut - n_targets;
                resp = root spawn bench_single_hop(
                    n_targets=n_targets, n_others=n_others, iterations=iterations
                );
                r = resp.reports[0];
                shResults = shResults + [r];
                shStatus = f"Done — OFF {r['off_avg_ms']} ms  |  ON cold {r['on_cold_ms']} ms  |  ON warm {r['on_warm_avg_ms']} ms  |  warm speedup {r['speedup_warm']}×";
            } except Exception as e {
                shError = str(e);
                shStatus = "";
            }
            shLoading = False;
        }

        async def handleRunAll -> None {
            runningAll = True;
            shLoading = True;
            shStatus = "Running full grid (4 fan-outs × 5 selectivities = 20 scenarios)…";
            shError = "";
            try {
                resp = root spawn run_all_scenarios(iterations=iterations);
                r = resp.reports[0];
                shResults = shResults + r["results"];
                shHeatmap = r["heatmap"];
                showHeatmap = True;
                shStatus = f"Grid complete — {len(r['results'])} scenarios added.";
            } except Exception as e {
                shError = str(e);
                shStatus = "";
            }
            shLoading = False;
            runningAll = False;
        }

        # ---- Inheritance handler ----
        async def handleBenchInheritance -> None {
            inhLoading = True;
            inhStatus = "Running...";
            inhError = "";
            try {
                base_count = int(inhFanOut * inhSel);
                n_post     = base_count // 2;
                n_comment  = base_count - n_post;
                n_other    = inhFanOut - base_count;
                resp = root spawn bench_inheritance(
                    n_post=n_post, n_comment=n_comment, n_other=n_other, iterations=inhIters
                );
                r = resp.reports[0];
                inhResults = inhResults + [r];
                inhStatus = f"Done — OFF {r['off_avg_ms']} ms  |  ON warm {r['on_warm_avg_ms']} ms  |  warm speedup {r['speedup_warm']}×";
            } except Exception as e {
                inhError = str(e);
                inhStatus = "";
            }
            inhLoading = False;
        }

        # ---- Multi-hop handler ----
        async def handleBenchMultihop -> None {
            mhLoading = True;
            mhStatus = "Running...";
            mhError = "";
            try {
                resp = root spawn bench_multihop(
                    n_mid=mhMid, n_bt=mhBt, n_bo=mhBo, iterations=mhIters
                );
                r = resp.reports[0];
                mhResults = mhResults + [r];
                mhStatus = f"Done — OFF {r['off_avg_ms']} ms  |  ON warm {r['on_warm_avg_ms']} ms  |  warm speedup {r['speedup_warm']}×";
            } except Exception as e {
                mhError = str(e);
                mhStatus = "";
            }
            mhLoading = False;
        }

        # ---- Edge filter handler ----
        async def handleBenchEdgeFilter -> None {
            efLoading = True;
            efStatus = "Running...";
            efError = "";
            try {
                resp = root spawn bench_edge_filter(
                    n_follow_post=efFollowPost,
                    n_follow_other=efFollowOther,
                    n_like_post=efLikePost,
                    iterations=efIters
                );
                r = resp.reports[0];
                efResults = efResults + [r];
                efStatus = (
                    f"Edge-only: OFF {r['edge_off_ms']} ms | ON warm {r['edge_warm_ms']} ms | "
                    f"{r['edge_speedup_warm']}×   ·   "
                    f"Combined: OFF {r['comb_off_ms']} ms | ON warm {r['comb_warm_ms']} ms | "
                    f"{r['comb_speedup_warm']}×"
                );
            } except Exception as e {
                efError = str(e);
                efStatus = "";
            }
            efLoading = False;
        }

        # ---- Clear handler ----
        async def handleClear -> None {
            try {
                root spawn clear_graph();
                shResults = [];
                shHeatmap = {};
                showHeatmap = False;
                inhResults = [];
                mhResults = [];
                efResults = [];
                shStatus = "Cleared.";
            } except Exception as e {
                shError = str(e);
            }
        }

        # ---- Style helpers ----
        btnStyle = lambda bg: Any -> dict {
            return {
                "padding": "8px 18px", "background": bg, "color": "#fff",
                "border": "none", "borderRadius": "6px", "cursor": "pointer",
                "fontWeight": "600", "fontSize": "14px"
            };
        };

        labelStyle = {
            "display": "block", "marginBottom": "5px", "fontSize": "12px",
            "color": "#64748b", "fontWeight": "600",
            "textTransform": "uppercase", "letterSpacing": "0.05em"
        };

        selectStyle = {
            "padding": "7px 12px", "border": "1px solid #cbd5e1",
            "borderRadius": "6px", "fontSize": "14px", "background": "#fff"
        };

        tabStyle = lambda active: Any -> dict {
            return {
                "padding": "10px 20px", "cursor": "pointer", "border": "none",
                "borderBottom": ("3px solid #0ea5e9" if active else "3px solid transparent"),
                "background": "none", "fontSize": "14px",
                "fontWeight": ("700" if active else "400"),
                "color": ("#0ea5e9" if active else "#64748b")
            };
        };

        # ---- Bar chart helper: 3 bars per result ----
        def barRow(label: str, color: str, val: float, maxVal: float) -> JsxElement {
            return
                <div style={{"display": "flex", "alignItems": "center", "gap": "8px", "marginBottom": "4px"}}>
                    <span style={{"width": "72px", "fontSize": "12px", "color": color, "textAlign": "right", "fontWeight": "600"}}>{label}</span>
                    <div style={{
                        "height": "20px", "background": color, "borderRadius": "3px",
                        "width": f"{min(val / max(maxVal, 0.001) * 380, 380)}px",
                        "minWidth": "2px"
                    }}/>
                    <span style={{"fontSize": "12px", "fontFamily": "monospace", "color": color}}>{round(val, 3)} ms</span>
                </div>;
        }

        # ---- Results table ----
        def resultsTable(rows: list) -> JsxElement {
            cols = ["Scenario", "Fan Out", "Selectivity", "OFF avg (ms)", "ON cold (ms)", "ON warm avg (ms)", "Speedup cold", "Speedup warm", "Results"];
            return
                <div style={{"overflowX": "auto"}}>
                    <table style={{"width": "100%", "borderCollapse": "collapse", "fontSize": "13px"}}>
                        <thead>
                            <tr style={{"background": "#f8fafc"}}>
                                {[
                                    <th key={col} style={{"padding": "10px 14px", "textAlign": "left", "borderBottom": "2px solid #e2e8f0", "fontWeight": "600", "color": "#374151", "whiteSpace": "nowrap"}}>{col}</th>
                                    for col in cols
                                ]}
                            </tr>
                        </thead>
                        <tbody>
                            {[
                                <tr key={i} style={{"borderBottom": "1px solid #f1f5f9"}}>
                                    <td style={{"padding": "10px 14px", "fontSize": "12px", "color": "#64748b"}}>{r["scenario"] or "—"}</td>
                                    <td style={{"padding": "10px 14px", "fontFamily": "monospace"}}>{r["fan_out"] or r["n_mid"] or "—"}</td>
                                    <td style={{"padding": "10px 14px", "fontFamily": "monospace"}}>{f"{int((r['selectivity'] or 0)*100)}%"}</td>
                                    <td style={{"padding": "10px 14px", "fontFamily": "monospace", "color": "#7c3aed"}}>{r["off_avg_ms"]}</td>
                                    <td style={{"padding": "10px 14px", "fontFamily": "monospace", "color": "#0369a1"}}>{r["on_cold_ms"]}</td>
                                    <td style={{"padding": "10px 14px", "fontFamily": "monospace", "color": "#065f46"}}>{r["on_warm_avg_ms"]}</td>
                                    <td style={{"padding": "10px 14px", "fontFamily": "monospace"}}>{r["speedup_cold"]}×</td>
                                    <td style={{"padding": "10px 14px", "fontFamily": "monospace", "fontWeight": "700", "color": "#0369a1"}}>{r["speedup_warm"]}×</td>
                                    <td style={{"padding": "10px 14px", "color": "#64748b"}}>{r["n_results"] or "—"}</td>
                                </tr>
                                for (i, r) in enumerate(rows)
                            ]}
                        </tbody>
                    </table>
                </div>;
        }

        # ---- Stats pill helper ----
        def statsPill(label: str, val: int, color: str) -> JsxElement {
            return
                <span style={{
                    "display": "inline-block", "padding": "2px 10px",
                    "borderRadius": "12px", "background": color,
                    "color": "#fff", "fontSize": "11px", "fontWeight": "600",
                    "marginRight": "6px"
                }}>{label}: {val}</span>;
        }

        # ---- Interpretation badge: warm speedup ratio → colored label ----
        # Thresholds reflect realistic AM/GT speedup range observed in practice.
        def interpBadge(sp: float) -> JsxElement {
            label: str = "";
            bg: str = "";
            col: str = "";
            if sp >= 2.0    { label = "Strong win";      bg = "#dcfce7"; col = "#166534"; }
            elif sp >= 1.3  { label = "Moderate win";    bg = "#d1fae5"; col = "#065f46"; }
            elif sp >= 1.1  { label = "Slight win";      bg = "#ccfbf1"; col = "#0f766e"; }
            elif sp >= 0.95 { label = "Roughly equal";   bg = "#f1f5f9"; col = "#475569"; }
            elif sp >= 0.8  { label = "Slight overhead"; bg = "#fef3c7"; col = "#b45309"; }
            else            { label = "Index slower";    bg = "#fee2e2"; col = "#991b1b"; }
            # Pre-compute text before JSX return: {sp} inside a JSX f-string resolves
            # in component scope (undefined), not the function parameter scope.
            text: str = f"{label} ({sp}×)";
            return <span style={{
                "display": "inline-block", "padding": "2px 10px", "borderRadius": "20px",
                "background": bg, "color": col, "fontSize": "11px", "fontWeight": "700",
                "whiteSpace": "nowrap"
            }}>{text}</span>;
        }

        # ---- Correctness badge: compact pass/fail pill ----
        def correctnessBadge(c: dict) -> JsxElement {
            all_ok = c["all_ok"];
            bg  = "#d1fae5" if all_ok else "#fee2e2";
            col = "#065f46" if all_ok else "#991b1b";
            txt = "✓ correct" if all_ok else "✗ wrong";
            return <span style={{
                "display": "inline-block", "padding": "2px 8px", "borderRadius": "12px",
                "background": bg, "color": col, "fontSize": "11px", "fontWeight": "700"
            }}>{txt}</span>;
        }

        # ---- Single correctness row: label + ok/fail + expected/actual/missing/extra ----
        def correctnessRow(label: str, chk: dict) -> JsxElement {
            chk_data   = chk or {};
            ok         = chk_data["ok"] if chk_data else True;
            ok_col     = "#065f46" if ok else "#dc2626";
            ok_sym     = "✓" if ok else "✗";
            miss_part  = f"  missing={chk_data['missing_count']}" if (chk_data and chk_data["missing_count"] > 0) else "";
            extra_part = f"  extra={chk_data['extra_count']}"     if (chk_data and chk_data["extra_count"]   > 0) else "";
            detail     = f"expected={chk_data['expected_count'] or 0}  got={chk_data['actual_count'] or 0}{miss_part}{extra_part}" if chk_data else "no data";
            return
                <div style={{"display": "flex", "gap": "8px", "alignItems": "center", "marginBottom": "2px"}}>
                    <span style={{"width": "52px", "fontSize": "10px", "fontWeight": "600", "color": "#64748b"}}>{label}</span>
                    <span style={{"color": ok_col, "fontWeight": "700", "fontSize": "12px"}}>{ok_sym}</span>
                    <span style={{"fontSize": "10px", "color": "#64748b", "fontFamily": "monospace"}}>{detail}</span>
                </div>;
        }

        # ---- Correctness panel for single-hop / inheritance / multi-hop ----
        # Expects c with keys: all_ok, off, on_cold, on_warm
        def correctnessPanel(c: dict) -> JsxElement {
            all_ok     = c["all_ok"];
            hdr_bg     = "#f0fdf4" if all_ok else "#fef2f2";
            hdr_border = "#bbf7d0" if all_ok else "#fca5a5";
            hdr_col    = "#065f46" if all_ok else "#dc2626";
            hdr_text   = "✓ Correctness: PASS" if all_ok else "✗ Correctness: FAIL";
            return
                <div style={{"border": f"1px solid {hdr_border}", "background": hdr_bg, "borderRadius": "6px", "padding": "8px 12px", "marginTop": "8px"}}>
                    <div style={{"fontWeight": "700", "marginBottom": "5px", "fontSize": "11px", "color": hdr_col}}>{hdr_text}</div>
                    {correctnessRow({"label": "OFF",     "chk": c["off"]     or {}})}
                    {correctnessRow({"label": "ON cold", "chk": c["on_cold"] or {}})}
                    {correctnessRow({"label": "ON warm", "chk": c["on_warm"] or {}})}
                </div>;
        }

        # ---- Correctness panel for edge-filter edge-only sub-query ----
        # Expects c = full edge-filter correctness dict (keys: off_edge, cold_edge, warm_edge, …)
        def correctnessPanelEdge(c: dict) -> JsxElement {
            all_ok     = c["off_edge"]["ok"] and c["cold_edge"]["ok"] and c["warm_edge"]["ok"];
            hdr_bg     = "#f0fdf4" if all_ok else "#fef2f2";
            hdr_border = "#bbf7d0" if all_ok else "#fca5a5";
            hdr_col    = "#065f46" if all_ok else "#dc2626";
            hdr_text   = "✓ Correctness: PASS" if all_ok else "✗ Correctness: FAIL";
            return
                <div style={{"border": f"1px solid {hdr_border}", "background": hdr_bg, "borderRadius": "6px", "padding": "8px 12px", "marginTop": "8px"}}>
                    <div style={{"fontWeight": "700", "marginBottom": "5px", "fontSize": "11px", "color": hdr_col}}>{hdr_text}</div>
                    {correctnessRow({"label": "OFF",     "chk": c["off_edge"]  or {}})}
                    {correctnessRow({"label": "ON cold", "chk": c["cold_edge"] or {}})}
                    {correctnessRow({"label": "ON warm", "chk": c["warm_edge"] or {}})}
                </div>;
        }

        # ---- Correctness panel for edge-filter combined sub-query ----
        # Expects c = full edge-filter correctness dict (keys: off_comb, cold_comb, warm_comb, …)
        def correctnessPanelComb(c: dict) -> JsxElement {
            all_ok     = c["off_comb"]["ok"] and c["cold_comb"]["ok"] and c["warm_comb"]["ok"];
            hdr_bg     = "#f0fdf4" if all_ok else "#fef2f2";
            hdr_border = "#bbf7d0" if all_ok else "#fca5a5";
            hdr_col    = "#065f46" if all_ok else "#dc2626";
            hdr_text   = "✓ Correctness: PASS" if all_ok else "✗ Correctness: FAIL";
            return
                <div style={{"border": f"1px solid {hdr_border}", "background": hdr_bg, "borderRadius": "6px", "padding": "8px 12px", "marginTop": "8px"}}>
                    <div style={{"fontWeight": "700", "marginBottom": "5px", "fontSize": "11px", "color": hdr_col}}>{hdr_text}</div>
                    {correctnessRow({"label": "OFF",     "chk": c["off_comb"]})}
                    {correctnessRow({"label": "ON cold", "chk": c["cold_comb"]})}
                    {correctnessRow({"label": "ON warm", "chk": c["warm_comb"]})}
                </div>;
        }

        # ---- Aggregated summary panel: shown when > 1 run accumulated ----
        def summaryPanel(rows: list, group_key: str) -> JsxElement {
            if len(rows) < 2 { return <span/>; }
            all_warm = [r["speedup_warm"] or 0.0 for r in rows];
            all_cold = [r["speedup_cold"] or 0.0 for r in rows];
            n        = len(rows);
            avg_warm = round(sum(all_warm) / n, 2);
            avg_cold = round(sum(all_cold) / n, 2);
            wins     = len([x for x in all_warm if x >= 1.1]);
            losses   = len([x for x in all_warm if x < 0.9]);
            # Use reduce (not max(list)) — max(list) compiles to Math.max(array) in JS → NaN
            best_warm  = all_warm[0];
            worst_warm = all_warm[0];
            best_cold  = all_cold[0];
            for x in all_warm { best_warm  = max(best_warm,  x); }
            for x in all_warm { worst_warm = min(worst_warm, x); }
            for x in all_cold { best_cold  = max(best_cold,  x); }

            fo_groups: dict = {};
            for r in rows {
                k = str(r[group_key] or "?");
                if k not in fo_groups { fo_groups[k] = []; }
                fo_groups[k] = fo_groups[k] + [r["speedup_warm"] or 0.0];
            }
            sel_groups: dict = {};
            for r in rows {
                k = f"{int((r['selectivity'] or 0.0) * 100)}%";
                if k not in sel_groups { sel_groups[k] = []; }
                sel_groups[k] = sel_groups[k] + [r["speedup_warm"] or 0.0];
            }

            def cellBg(avg: float) -> str {
                if avg >= 1.3   { return "#d1fae5"; }
                elif avg >= 1.1 { return "#ccfbf1"; }
                elif avg >= 0.9 { return "#f1f5f9"; }
                else            { return "#fee2e2"; }
            }
            def cellCol(avg: float) -> str {
                return "#065f46" if avg >= 1.0 else "#dc2626";
            }

            return
                <div style={{"background": "#f8fafc", "border": "1px solid #e2e8f0", "borderRadius": "8px", "padding": "18px", "marginTop": "20px"}}>
                    <h3 style={{"margin": "0 0 14px 0", "fontSize": "13px", "fontWeight": "700", "color": "#1e293b"}}>{f"Aggregated Summary — {n} runs"}</h3>
                    <div style={{"display": "flex", "gap": "28px", "flexWrap": "wrap", "paddingBottom": "14px", "marginBottom": "14px", "borderBottom": "1px solid #e2e8f0"}}>
                        <div style={{"textAlign": "center"}}>
                            <div style={{"fontSize": "10px", "color": "#64748b", "textTransform": "uppercase", "fontWeight": "600", "marginBottom": "3px"}}>Avg warm speedup</div>
                            <div style={{"fontSize": "22px", "fontWeight": "800", "color": cellCol(avg_warm)}}>{avg_warm}×</div>
                            <div style={{"fontSize": "9px", "color": "#94a3b8"}}>steady-state (SAM hit)</div>
                        </div>
                        <div style={{"textAlign": "center"}}>
                            <div style={{"fontSize": "10px", "color": "#64748b", "textTransform": "uppercase", "fontWeight": "600", "marginBottom": "3px"}}>Avg cold speedup</div>
                            <div style={{"fontSize": "22px", "fontWeight": "800", "color": cellCol(avg_cold)}}>{avg_cold}×</div>
                            <div style={{"fontSize": "9px", "color": "#94a3b8"}}>SAM-miss path (GTI SQL)</div>
                        </div>
                        <div style={{"textAlign": "center"}}>
                            <div style={{"fontSize": "10px", "color": "#64748b", "textTransform": "uppercase", "fontWeight": "600", "marginBottom": "3px"}}>Best warm</div>
                            <div style={{"fontSize": "22px", "fontWeight": "800", "color": "#065f46"}}>{best_warm}×</div>
                        </div>
                        <div style={{"textAlign": "center"}}>
                            <div style={{"fontSize": "10px", "color": "#64748b", "textTransform": "uppercase", "fontWeight": "600", "marginBottom": "3px"}}>Worst warm</div>
                            <div style={{"fontSize": "22px", "fontWeight": "800", "color": ("#dc2626" if worst_warm < 1.0 else "#64748b")}}>{worst_warm}×</div>
                        </div>
                        <div style={{"textAlign": "center"}}>
                            <div style={{"fontSize": "10px", "color": "#64748b", "textTransform": "uppercase", "fontWeight": "600", "marginBottom": "3px"}}>Index wins / losses</div>
                            <div style={{"fontSize": "20px", "fontWeight": "800"}}>
                                <span style={{"color": "#065f46"}}>{wins}</span>
                                <span style={{"color": "#94a3b8"}}> / </span>
                                <span style={{"color": "#dc2626"}}>{losses}</span>
                            </div>
                            <div style={{"fontSize": "9px", "color": "#94a3b8"}}>of {n} runs</div>
                        </div>
                    </div>
                    {(len(fo_groups) > 1 and
                        <div style={{"marginBottom": "14px"}}>
                            <div style={{"fontSize": "10px", "color": "#64748b", "textTransform": "uppercase", "fontWeight": "600", "marginBottom": "8px"}}>Warm speedup by {group_key} (avg over runs)</div>
                            <div style={{"display": "flex", "gap": "8px", "flexWrap": "wrap"}}>
                                {[
                                    <div key={k} style={{"background": cellBg(sum(vs)/len(vs)), "border": "1px solid #e2e8f0", "borderRadius": "6px", "padding": "8px 14px", "textAlign": "center", "minWidth": "72px"}}>
                                        <div style={{"fontSize": "10px", "color": "#64748b", "marginBottom": "2px"}}>{group_key}={k}</div>
                                        <div style={{"fontSize": "15px", "fontWeight": "700", "color": cellCol(sum(vs)/len(vs))}}>{round(sum(vs)/len(vs), 2)}×</div>
                                        <div style={{"fontSize": "9px", "color": "#94a3b8"}}>{len(vs)} run(s)</div>
                                    </div>
                                    for (k, vs) in fo_groups.items()
                                ]}
                            </div>
                        </div>
                    )}
                    {(len(sel_groups) > 1 and
                        <div>
                            <div style={{"fontSize": "10px", "color": "#64748b", "textTransform": "uppercase", "fontWeight": "600", "marginBottom": "8px"}}>Warm speedup by selectivity (avg over runs)</div>
                            <div style={{"display": "flex", "gap": "8px", "flexWrap": "wrap"}}>
                                {[
                                    <div key={k} style={{"background": cellBg(sum(vs)/len(vs)), "border": "1px solid #e2e8f0", "borderRadius": "6px", "padding": "8px 14px", "textAlign": "center", "minWidth": "72px"}}>
                                        <div style={{"fontSize": "10px", "color": "#64748b", "marginBottom": "2px"}}>sel={k}</div>
                                        <div style={{"fontSize": "15px", "fontWeight": "700", "color": cellCol(sum(vs)/len(vs))}}>{round(sum(vs)/len(vs), 2)}×</div>
                                        <div style={{"fontSize": "9px", "color": "#94a3b8"}}>{len(vs)} run(s)</div>
                                    </div>
                                    for (k, vs) in sel_groups.items()
                                ]}
                            </div>
                        </div>
                    )}
                </div>;
        }

        return
            <div style={{"fontFamily": "system-ui, -apple-system, sans-serif", "minHeight": "100vh", "background": "#f8fafc"}}>

                <div style={{"background": "#1e293b", "color": "#f1f5f9", "padding": "16px 32px"}}>
                    <h1 style={{"margin": "0", "fontSize": "1.2rem", "fontWeight": "700"}}>Graph Index Benchmark</h1>
                    <p style={{"margin": "4px 0 0 0", "fontSize": "13px", "color": "#94a3b8"}}>
                        Direct runtime benchmark — <code>JAC_INDEX_ENABLED</code> OFF vs ON cold vs ON warm · no simulation
                    </p>
                </div>

                <div style={{"background": "#fff", "borderBottom": "1px solid #e2e8f0", "paddingLeft": "32px", "display": "flex", "alignItems": "center"}}>
                    <button style={tabStyle(activeTab == "singlehop")}  onClick={lambda _: Any -> None { activeTab = "singlehop";}}>Single-hop</button>
                    <button style={tabStyle(activeTab == "inheritance")} onClick={lambda _: Any -> None { activeTab = "inheritance";}}>Inheritance</button>
                    <button style={tabStyle(activeTab == "multihop")}    onClick={lambda _: Any -> None { activeTab = "multihop";}}>Multi-hop</button>
                    <button style={tabStyle(activeTab == "edgefilter")}  onClick={lambda _: Any -> None { activeTab = "edgefilter";}}>Edge Filter</button>
                    <button
                        onClick={handleClear}
                        style={{"marginLeft": "auto", "marginRight": "24px", "padding": "7px 14px", "background": "#ef4444", "color": "#fff", "border": "none", "borderRadius": "6px", "cursor": "pointer", "fontSize": "13px"}}
                    >Clear All</button>
                </div>

                <div style={{"maxWidth": "1140px", "margin": "0 auto", "padding": "28px 24px"}}>

                    {(activeTab == "singlehop" and
                        <div>
                            <div style={{"background": "#fff", "border": "1px solid #e2e8f0", "borderRadius": "10px", "padding": "22px", "marginBottom": "24px"}}>
                                <h2 style={{"margin": "0 0 4px 0", "fontSize": "15px", "fontWeight": "700", "color": "#1e293b"}}>Single-hop</h2>
                                <p style={{"margin": "0 0 18px 0", "fontSize": "12px", "color": "#64748b"}}>
                                    Graph: BenchRoot → [TargetNode | OtherNode].
                                    Query: <code>[bench-->(?:TargetNode)]</code>
                                </p>

                                <div style={{"background": "#f0f9ff", "border": "1px solid #bae6fd", "borderRadius": "6px", "padding": "12px 14px", "marginBottom": "18px", "fontSize": "12px", "color": "#0369a1", "lineHeight": "2.0"}}>
                                    <div><span style={{"background": "#8b5cf6", "color": "#fff", "borderRadius": "4px", "padding": "1px 7px", "fontWeight": "700", "marginRight": "6px"}}>OFF</span> <code>JAC_INDEX_ENABLED=false</code> — walks the full edge list, loads all {fanOut} neighbor stubs from SQLite, then filters in Python. Cost scales with total fan-out regardless of selectivity.</div>
                                    <div><span style={{"background": "#f59e0b", "color": "#fff", "borderRadius": "4px", "padding": "1px 7px", "fontWeight": "700", "marginRight": "6px"}}>ON cold</span> SAM evicted before each iteration — SAM miss triggers 1 GTI SQL <code>SELECT WHERE type=TargetNode</code>, result warms SAM. Avg of N−1 cold runs (first discarded). Higher overhead than OFF when fan-out is moderate and the SQL query cost dominates the savings.</div>
                                    <div><span style={{"background": "#10b981", "color": "#fff", "borderRadius": "4px", "padding": "1px 7px", "fontWeight": "700", "marginRight": "6px"}}>ON warm</span> SAM already populated — direct dict lookup returns {int(fanOut * selectivity)} matching IDs, then bulk-fetch only those nodes. L1 cleared each iteration so node fetches still go to SQLite. <strong>This is the steady-state server path.</strong></div>
                                </div>

                                <div style={{"display": "flex", "gap": "24px", "flexWrap": "wrap", "alignItems": "flex-end"}}>
                                    <div>
                                        <label style={labelStyle}>Fan Out</label>
                                        <select value={fanOut} onChange={lambda e: Any -> None { fanOut = int(e.target.value);}} style={selectStyle}>
                                            <option value={5}>5 nodes</option>
                                            <option value={50}>50 nodes</option>
                                            <option value={200}>200 nodes</option>
                                            <option value={500}>500 nodes</option>
                                            <option value={1000}>1000 nodes</option>
                                        </select>
                                    </div>
                                    <div>
                                        <label style={labelStyle}>Selectivity (TargetNode %)</label>
                                        <select value={selectivity} onChange={lambda e: Any -> None { selectivity = float(e.target.value);}} style={selectStyle}>
                                            <option value={0.1}>10%</option>
                                            <option value={0.25}>25%</option>
                                            <option value={0.5}>50%</option>
                                            <option value={0.75}>75%</option>
                                            <option value={0.9}>90%</option>
                                        </select>
                                    </div>
                                    <div>
                                        <label style={labelStyle}>Iterations</label>
                                        <select value={iterations} onChange={lambda e: Any -> None { iterations = int(e.target.value);}} style={selectStyle}>
                                            <option value={1}>1</option>
                                            <option value={5}>5</option>
                                            <option value={10}>10</option>
                                        </select>
                                    </div>
                                    <div style={{"display": "flex", "gap": "8px"}}>
                                        <button onClick={handleBenchSingleHop} disabled={shLoading or runningAll} style={btnStyle("#8b5cf6")}>
                                            {("Running..." if shLoading and not runningAll else "Run Benchmark")}
                                        </button>
                                        <button onClick={handleRunAll} disabled={shLoading or runningAll} style={btnStyle("#0d9488")}>
                                            {("Running grid..." if runningAll else "Run Full Grid")}
                                        </button>
                                    </div>
                                </div>
                                {(shStatus and <p style={{"margin": "14px 0 0 0", "color": "#0f766e", "fontSize": "13px"}}>{shStatus}</p>)}
                                {(shError  and <p style={{"margin": "14px 0 0 0", "color": "#dc2626", "fontSize": "13px"}}>Error: {shError}</p>)}
                            </div>

                            {(len(shResults) > 0 and
                                <div style={{"background": "#fff", "border": "1px solid #e2e8f0", "borderRadius": "10px", "padding": "22px", "marginBottom": "24px"}}>
                                    <h2 style={{"margin": "0 0 18px 0", "fontSize": "15px", "fontWeight": "700"}}>Results</h2>
                                    {[
                                        <div key={i} style={{"marginBottom": "20px", "paddingBottom": "16px", "borderBottom": "1px solid #f1f5f9"}}>
                                            <div style={{"display": "flex", "alignItems": "center", "flexWrap": "wrap", "gap": "6px", "marginBottom": "5px"}}>
                                                <span style={{"fontSize": "12px", "color": "#374151", "fontWeight": "700"}}>{f"fan={r['fan_out'] or '?'}  sel={int((r['selectivity'] or 0)*100)}%  iter={r['iterations'] or '?'}  results={r['n_results'] or '?'}"}</span>
                                                {interpBadge({"sp": r["speedup_warm"] or 0.0})}
                                                {(r["correctness"] and correctnessBadge({"c": r["correctness"]}))}
                                                {(r["cold_stats"] and
                                                    <span style={{"display": "flex", "gap": "4px", "marginLeft": "4px"}}>
                                                        {statsPill({"label": "SAM hits",   "val": r["cold_stats"]["sam_hits"]   or 0, "color": "#0d9488"})}
                                                        {statsPill({"label": "SAM misses", "val": r["cold_stats"]["sam_misses"] or 0, "color": "#f59e0b"})}
                                                        {statsPill({"label": "GTI hits",   "val": r["cold_stats"]["gti_hits"]   or 0, "color": "#0369a1"})}
                                                    </span>
                                                )}
                                            </div>
                                            <div style={{"fontSize": "10px", "color": "#94a3b8", "marginBottom": "8px", "lineHeight": "1.6"}}>
                                                <span style={{"color": "#8b5cf6", "fontWeight": "600"}}>OFF</span>: loads all {r["fan_out"] or "?"} neighbors → filter {r["n_results"] or "?"} in Python &nbsp;·&nbsp;
                                                <span style={{"color": "#f59e0b", "fontWeight": "600"}}>ON cold</span>: SAM miss → 1 GTI SQL query ({r["cold_stats"]["gti_hits"] or 0 if r["cold_stats"] else 0} GTI hit(s)) → warms SAM &nbsp;·&nbsp;
                                                <span style={{"color": "#10b981", "fontWeight": "600"}}>ON warm</span>: SAM hit → fetch only {r["n_results"] or "?"} matching nodes (skips {(r["fan_out"] or 0) - (r["n_results"] or 0)} unnecessary loads)
                                            </div>
                                            {barRow({"label": "OFF",     "color": "#8b5cf6", "val": r["off_avg_ms"],     "maxVal": max(r["off_avg_ms"], r["on_cold_ms"], r["on_warm_avg_ms"])})}
                                            {barRow({"label": "ON cold", "color": "#f59e0b", "val": r["on_cold_ms"],     "maxVal": max(r["off_avg_ms"], r["on_cold_ms"], r["on_warm_avg_ms"])})}
                                            {barRow({"label": "ON warm", "color": "#10b981", "val": r["on_warm_avg_ms"], "maxVal": max(r["off_avg_ms"], r["on_cold_ms"], r["on_warm_avg_ms"])})}
                                            <div style={{"marginTop": "6px", "fontSize": "11px", "color": "#64748b"}}>
                                                {f"Warm {r['speedup_warm']}× · Cold {r['speedup_cold']}×  —  {'' if (r['speedup_warm'] or 0) >= 1.0 else 'index adds overhead at this fan/selectivity; '}{'index saves ' + str((r['fan_out'] or 0) - (r['n_results'] or 0)) + ' node fetches per warm query' if (r['speedup_warm'] or 0) >= 1.0 else ''}"}
                                            </div>
                                            {(r["correctness"] and correctnessPanel({"c": r["correctness"]}))}
                                        </div>
                                        for (i, r) in enumerate(shResults)
                                    ]}
                                    {resultsTable({"rows": shResults})}
                                    {summaryPanel({"rows": shResults, "group_key": "fan_out"})}
                                </div>
                            )}

                            {(showHeatmap and
                                <div style={{"background": "#fff", "border": "1px solid #e2e8f0", "borderRadius": "10px", "padding": "22px"}}>
                                    <h2 style={{"margin": "0 0 4px 0", "fontSize": "15px", "fontWeight": "700"}}>Speedup Heatmap — ON warm vs OFF</h2>
                                    <p style={{"margin": "0 0 8px 0", "fontSize": "12px", "color": "#64748b"}}>
                                        Each cell shows <span style={{"color": "#0369a1", "fontWeight": "600"}}>cold speedup</span> (top) and <span style={{"color": "#065f46", "fontWeight": "600"}}>warm speedup</span> (bottom). Cell color reflects warm speedup only — this is the steady-state production path.
                                    </p>
                                    <div style={{"display": "flex", "gap": "8px", "marginBottom": "14px", "flexWrap": "wrap", "fontSize": "11px"}}>
                                        <span style={{"background": "#d1fae5", "padding": "2px 10px", "borderRadius": "4px", "fontWeight": "600", "color": "#065f46"}}>≥ 1.3× Strong win</span>
                                        <span style={{"background": "#ccfbf1", "padding": "2px 10px", "borderRadius": "4px", "fontWeight": "600", "color": "#0f766e"}}>≥ 1.1× Moderate win</span>
                                        <span style={{"background": "#f1f5f9", "padding": "2px 10px", "borderRadius": "4px", "fontWeight": "600", "color": "#475569"}}>≥ 0.9× Roughly equal</span>
                                        <span style={{"background": "#fee2e2", "padding": "2px 10px", "borderRadius": "4px", "fontWeight": "600", "color": "#991b1b"}}>&lt; 0.9× Index slower</span>
                                    </div>
                                    <div style={{"overflowX": "auto"}}>
                                        <table style={{"borderCollapse": "collapse", "fontSize": "12px"}}>
                                            <thead>
                                                <tr>
                                                    <th style={{"padding": "8px 14px", "background": "#f8fafc", "border": "1px solid #e2e8f0", "fontWeight": "700"}}>Selectivity</th>
                                                    {[
                                                        <th key={fo} style={{"padding": "8px 14px", "background": "#f8fafc", "border": "1px solid #e2e8f0", "fontWeight": "700", "textAlign": "center"}}>{f"fan={fo}"}</th>
                                                        for fo in [5, 50, 200, 500, 1000]
                                                    ]}
                                                </tr>
                                            </thead>
                                            <tbody>
                                                {[
                                                    <tr key={sel_pct}>
                                                        <td style={{"padding": "8px 14px", "border": "1px solid #e2e8f0", "fontWeight": "600"}}>{f"{sel_pct}% match"}</td>
                                                        {[
                                                            <td key={fo} style={{"padding": "8px 14px", "border": "1px solid #e2e8f0", "textAlign": "center",
                                                                "background": (
                                                                    "#d1fae5" if (shHeatmap[str(sel_pct)] and shHeatmap[str(sel_pct)][str(fo)] and shHeatmap[str(sel_pct)][str(fo)]["speedup_warm"] >= 1.3) else
                                                                    "#ccfbf1" if (shHeatmap[str(sel_pct)] and shHeatmap[str(sel_pct)][str(fo)] and shHeatmap[str(sel_pct)][str(fo)]["speedup_warm"] >= 1.1) else
                                                                    "#fee2e2" if (shHeatmap[str(sel_pct)] and shHeatmap[str(sel_pct)][str(fo)] and shHeatmap[str(sel_pct)][str(fo)]["speedup_warm"] < 0.9) else
                                                                    "#f1f5f9"
                                                                )}}>
                                                                {(
                                                                    <div>
                                                                        <div style={{"fontWeight": "600", "color": "#0369a1", "fontSize": "10px", "marginBottom": "1px"}}>cold: {str(shHeatmap[str(sel_pct)][str(fo)]["speedup_cold"]) + "×"}</div>
                                                                        <div style={{"fontWeight": "800", "color": "#065f46", "fontSize": "13px"}}>warm: {str(shHeatmap[str(sel_pct)][str(fo)]["speedup_warm"]) + "×"}</div>
                                                                    </div>
                                                                    if (shHeatmap[str(sel_pct)] and shHeatmap[str(sel_pct)][str(fo)])
                                                                    else <span style={{"color": "#94a3b8"}}>—</span>
                                                                )}
                                                            </td>
                                                            for fo in [5, 50, 200, 500, 1000]
                                                        ]}
                                                    </tr>
                                                    for sel_pct in [10, 25, 50, 75, 90]
                                                ]}
                                            </tbody>
                                        </table>
                                    </div>
                                </div>
                            )}
                        </div>
                    )}

                    {(activeTab == "inheritance" and
                        <div>
                            <div style={{"background": "#fff", "border": "1px solid #e2e8f0", "borderRadius": "10px", "padding": "22px", "marginBottom": "24px"}}>
                                <h2 style={{"margin": "0 0 4px 0", "fontSize": "15px", "fontWeight": "700", "color": "#1e293b"}}>Inheritance (MRO fan-out)</h2>
                                <p style={{"margin": "0 0 18px 0", "fontSize": "12px", "color": "#64748b"}}>
                                    Graph: BenchRoot → [PostNode | CommentNode | OtherNode].
                                    Query: <code>[bench-->(?:BaseContent)]</code> — returns PostNode + CommentNode via MRO.
                                    At <code>++></code> time, am_put indexes each node under every ancestor type, so "BaseContent" bucket already contains both subtypes.
                                </p>

                                <div style={{"background": "#f0fdf4", "border": "1px solid #bbf7d0", "borderRadius": "6px", "padding": "12px 14px", "marginBottom": "18px", "fontSize": "12px", "color": "#065f46", "lineHeight": "2.0"}}>
                                    <div><span style={{"background": "#8b5cf6", "color": "#fff", "borderRadius": "4px", "padding": "1px 7px", "fontWeight": "700", "marginRight": "6px"}}>OFF</span> Loads all {inhFanOut} neighbors, then filters with <code>isinstance(node, BaseContent)</code> in Python — pays for every OtherNode fetch even though they're discarded.</div>
                                    <div><span style={{"background": "#f59e0b", "color": "#fff", "borderRadius": "4px", "padding": "1px 7px", "fontWeight": "700", "marginRight": "6px"}}>ON cold</span> SAM evicted → 1 GTI SQL query on "BaseContent" bucket (resolves PostNode + CommentNode IDs via MRO fan-out at <code>++></code> time). Avg of N−1 cold runs.</div>
                                    <div><span style={{"background": "#10b981", "color": "#fff", "borderRadius": "4px", "padding": "1px 7px", "fontWeight": "700", "marginRight": "6px"}}>ON warm</span> "BaseContent" SAM hit → fetch only {int(inhFanOut * inhSel)} matching nodes (Post + Comment). OtherNodes never loaded. <strong>MRO fan-out is the key advantage here.</strong></div>
                                </div>

                                <div style={{"display": "flex", "gap": "24px", "flexWrap": "wrap", "alignItems": "flex-end"}}>
                                    <div>
                                        <label style={labelStyle}>Fan Out (total nodes)</label>
                                        <select value={inhFanOut} onChange={lambda e: Any -> None { inhFanOut = int(e.target.value);}} style={selectStyle}>
                                            <option value={20}>20 nodes</option>
                                            <option value={50}>50 nodes</option>
                                            <option value={200}>200 nodes</option>
                                            <option value={500}>500 nodes</option>
                                            <option value={1000}>1000 nodes</option>
                                        </select>
                                    </div>
                                    <div>
                                        <label style={labelStyle}>BaseContent fraction (Post+Comment)</label>
                                        <select value={inhSel} onChange={lambda e: Any -> None { inhSel = float(e.target.value);}} style={selectStyle}>
                                            <option value={0.2}>20%</option>
                                            <option value={0.32}>32%</option>
                                            <option value={0.5}>50%</option>
                                            <option value={0.8}>80%</option>
                                        </select>
                                    </div>
                                    <div>
                                        <label style={labelStyle}>Iterations</label>
                                        <select value={inhIters} onChange={lambda e: Any -> None { inhIters = int(e.target.value);}} style={selectStyle}>
                                            <option value={1}>1</option>
                                            <option value={5}>5</option>
                                            <option value={10}>10</option>
                                        </select>
                                    </div>
                                    <button onClick={handleBenchInheritance} disabled={inhLoading} style={btnStyle("#8b5cf6")}>
                                        {("Running..." if inhLoading else "Run Benchmark")}
                                    </button>
                                </div>
                                {(inhStatus and <p style={{"margin": "14px 0 0 0", "color": "#0f766e", "fontSize": "13px"}}>{inhStatus}</p>)}
                                {(inhError  and <p style={{"margin": "14px 0 0 0", "color": "#dc2626", "fontSize": "13px"}}>Error: {inhError}</p>)}
                            </div>

                            {(len(inhResults) > 0 and
                                <div style={{"background": "#fff", "border": "1px solid #e2e8f0", "borderRadius": "10px", "padding": "22px"}}>
                                    <h2 style={{"margin": "0 0 18px 0", "fontSize": "15px", "fontWeight": "700"}}>Results</h2>
                                    {[
                                        <div key={i} style={{"marginBottom": "20px", "paddingBottom": "16px", "borderBottom": "1px solid #f1f5f9"}}>
                                            <div style={{"display": "flex", "alignItems": "center", "flexWrap": "wrap", "gap": "6px", "marginBottom": "5px"}}>
                                                <span style={{"fontSize": "12px", "color": "#374151", "fontWeight": "700"}}>{f"fan={r['fan_out'] or '?'}  BaseContent={int((r['selectivity'] or 0)*100)}%  results={r['n_results'] or '?'}"}</span>
                                                {interpBadge({"sp": r["speedup_warm"] or 0.0})}
                                                {(r["correctness"] and correctnessBadge({"c": r["correctness"]}))}
                                                {(r["cold_stats"] and
                                                    <span style={{"display": "flex", "gap": "4px", "marginLeft": "4px"}}>
                                                        {statsPill({"label": "SAM hits",   "val": r["cold_stats"]["sam_hits"]   or 0, "color": "#0d9488"})}
                                                        {statsPill({"label": "SAM misses", "val": r["cold_stats"]["sam_misses"] or 0, "color": "#f59e0b"})}
                                                        {statsPill({"label": "GTI hits",   "val": r["cold_stats"]["gti_hits"]   or 0, "color": "#0369a1"})}
                                                    </span>
                                                )}
                                            </div>
                                            <div style={{"fontSize": "10px", "color": "#94a3b8", "marginBottom": "8px", "lineHeight": "1.6"}}>
                                                <span style={{"color": "#8b5cf6", "fontWeight": "600"}}>OFF</span>: fetches all {r["fan_out"] or "?"} nodes including OtherNodes, filters by isinstance(BaseContent) &nbsp;·&nbsp;
                                                <span style={{"color": "#f59e0b", "fontWeight": "600"}}>ON cold</span>: 1 GTI SQL on "BaseContent" bucket (MRO-indexed at edge-creation time) &nbsp;·&nbsp;
                                                <span style={{"color": "#10b981", "fontWeight": "600"}}>ON warm</span>: SAM hit → {r["n_results"] or "?"} fetches only (skips {(r["fan_out"] or 0) - (r["n_results"] or 0)} OtherNode loads)
                                            </div>
                                            {barRow({"label": "OFF",     "color": "#8b5cf6", "val": r["off_avg_ms"],     "maxVal": max(r["off_avg_ms"], r["on_cold_ms"], r["on_warm_avg_ms"])})}
                                            {barRow({"label": "ON cold", "color": "#f59e0b", "val": r["on_cold_ms"],     "maxVal": max(r["off_avg_ms"], r["on_cold_ms"], r["on_warm_avg_ms"])})}
                                            {barRow({"label": "ON warm", "color": "#10b981", "val": r["on_warm_avg_ms"], "maxVal": max(r["off_avg_ms"], r["on_cold_ms"], r["on_warm_avg_ms"])})}
                                            <div style={{"marginTop": "6px", "fontSize": "11px", "color": "#64748b"}}>
                                                {f"Warm {r['speedup_warm']}× · Cold {r['speedup_cold']}×  —  MRO fan-out at ++> time is what makes the 'BaseContent' bucket work for both PostNode and CommentNode"}
                                            </div>
                                            {(r["correctness"] and correctnessPanel({"c": r["correctness"]}))}
                                        </div>
                                        for (i, r) in enumerate(inhResults)
                                    ]}
                                    {resultsTable({"rows": inhResults})}
                                    {summaryPanel({"rows": inhResults, "group_key": "fan_out"})}
                                </div>
                            )}
                        </div>
                    )}

                    {(activeTab == "multihop" and
                        <div>
                            <div style={{"background": "#fff", "border": "1px solid #e2e8f0", "borderRadius": "10px", "padding": "22px", "marginBottom": "24px"}}>
                                <h2 style={{"margin": "0 0 4px 0", "fontSize": "15px", "fontWeight": "700", "color": "#1e293b"}}>Multi-hop (2-hop)</h2>
                                <p style={{"margin": "0 0 18px 0", "fontSize": "12px", "color": "#64748b"}}>
                                    Graph: BenchRoot → MidNode[i] → [TargetNode | OtherNode].
                                    Query: <code>[bench-->(?:MidNode)]</code> then <code>[mid-->(?:TargetNode)]</code> for each mid.
                                    OFF cost: {mhMid} mid fetches + {mhMid}×{mhBt+mhBo} child fetches.
                                    ON warm cost: index resolves mid IDs + {mhMid}×{mhBt} target fetches only.
                                </p>

                                <div style={{"display": "flex", "gap": "24px", "flexWrap": "wrap", "alignItems": "flex-end"}}>
                                    <div>
                                        <label style={labelStyle}>Mid Count</label>
                                        <select value={mhMid} onChange={lambda e: Any -> None { mhMid = int(e.target.value);}} style={selectStyle}>
                                            <option value={5}>5</option>
                                            <option value={15}>15</option>
                                            <option value={30}>30</option>
                                        </select>
                                    </div>
                                    <div>
                                        <label style={labelStyle}>Branch TargetNodes / mid</label>
                                        <select value={mhBt} onChange={lambda e: Any -> None { mhBt = int(e.target.value);}} style={selectStyle}>
                                            <option value={3}>3</option>
                                            <option value={6}>6</option>
                                            <option value={10}>10</option>
                                        </select>
                                    </div>
                                    <div>
                                        <label style={labelStyle}>Branch OtherNodes / mid</label>
                                        <select value={mhBo} onChange={lambda e: Any -> None { mhBo = int(e.target.value);}} style={selectStyle}>
                                            <option value={7}>7</option>
                                            <option value={14}>14</option>
                                            <option value={20}>20</option>
                                        </select>
                                    </div>
                                    <div>
                                        <label style={labelStyle}>Iterations</label>
                                        <select value={mhIters} onChange={lambda e: Any -> None { mhIters = int(e.target.value);}} style={selectStyle}>
                                            <option value={1}>1</option>
                                            <option value={5}>5</option>
                                            <option value={10}>10</option>
                                        </select>
                                    </div>
                                    <button onClick={handleBenchMultihop} disabled={mhLoading} style={btnStyle("#8b5cf6")}>
                                        {("Running..." if mhLoading else "Run Benchmark")}
                                    </button>
                                </div>
                                {(mhStatus and <p style={{"margin": "14px 0 0 0", "color": "#0f766e", "fontSize": "13px"}}>{mhStatus}</p>)}
                                {(mhError  and <p style={{"margin": "14px 0 0 0", "color": "#dc2626", "fontSize": "13px"}}>Error: {mhError}</p>)}
                            </div>

                            {(len(mhResults) > 0 and
                                <div style={{"background": "#fff", "border": "1px solid #e2e8f0", "borderRadius": "10px", "padding": "22px"}}>
                                    <h2 style={{"margin": "0 0 18px 0", "fontSize": "15px", "fontWeight": "700"}}>Results</h2>
                                    {[
                                        <div key={i} style={{"marginBottom": "20px", "paddingBottom": "16px", "borderBottom": "1px solid #f1f5f9"}}>
                                            <div style={{"display": "flex", "alignItems": "center", "flexWrap": "wrap", "gap": "6px", "marginBottom": "5px"}}>
                                                <span style={{"fontSize": "12px", "color": "#374151", "fontWeight": "700"}}>{f"mid={r['n_mid'] or '?'}  branch={r['branch_factor'] or '?'}  sel={int((r['selectivity'] or 0)*100)}%  results={r['n_results'] or '?'}"}</span>
                                                {interpBadge({"sp": r["speedup_warm"] or 0.0})}
                                                {(r["correctness"] and correctnessBadge({"c": r["correctness"]}))}
                                                {(r["cold_stats"] and
                                                    <span style={{"display": "flex", "gap": "4px", "marginLeft": "4px"}}>
                                                        {statsPill({"label": "SAM hits",   "val": r["cold_stats"]["sam_hits"]   or 0, "color": "#0d9488"})}
                                                        {statsPill({"label": "SAM misses", "val": r["cold_stats"]["sam_misses"] or 0, "color": "#f59e0b"})}
                                                        {statsPill({"label": "GTI hits",   "val": r["cold_stats"]["gti_hits"]   or 0, "color": "#0369a1"})}
                                                    </span>
                                                )}
                                            </div>
                                            <div style={{"fontSize": "10px", "color": "#94a3b8", "marginBottom": "8px", "lineHeight": "1.6"}}>
                                                <span style={{"color": "#8b5cf6", "fontWeight": "600"}}>OFF</span>: hop1 loads {r["n_mid"] or "?"} MidNodes + hop2 loads all {r["branch_factor"] or "?"} children per mid ({(r["n_mid"] or 0) * (r["branch_factor"] or 0)} total loads), filters in Python &nbsp;·&nbsp;
                                                <span style={{"color": "#f59e0b", "fontWeight": "600"}}>ON cold</span>: {r["cold_stats"]["sam_misses"] or 0 if r["cold_stats"] else 0} SAM miss(es) → {r["cold_stats"]["gti_hits"] or 0 if r["cold_stats"] else 0} GTI SQL queries (1 per source node) &nbsp;·&nbsp;
                                                <span style={{"color": "#10b981", "fontWeight": "600"}}>ON warm</span>: index resolves each hop in SAM → {r["n_results"] or "?"} target fetches only (avoids {(r["n_mid"] or 0) * ((r["branch_factor"] or 0) - int((r["selectivity"] or 0) * (r["branch_factor"] or 0)))} unnecessary loads)
                                            </div>
                                            {barRow({"label": "OFF",     "color": "#8b5cf6", "val": r["off_avg_ms"],     "maxVal": max(r["off_avg_ms"], r["on_cold_ms"], r["on_warm_avg_ms"])})}
                                            {barRow({"label": "ON cold", "color": "#f59e0b", "val": r["on_cold_ms"],     "maxVal": max(r["off_avg_ms"], r["on_cold_ms"], r["on_warm_avg_ms"])})}
                                            {barRow({"label": "ON warm", "color": "#10b981", "val": r["on_warm_avg_ms"], "maxVal": max(r["off_avg_ms"], r["on_cold_ms"], r["on_warm_avg_ms"])})}
                                            <div style={{"marginTop": "6px", "fontSize": "11px", "color": "#64748b"}}>
                                                {f"Warm {r['speedup_warm']}× · Cold {r['speedup_cold']}×  —  cold overhead scales with n_mid ({r['n_mid'] or '?'} GT queries, one per hop-1 source node)"}
                                            </div>
                                            {(r["correctness"] and correctnessPanel({"c": r["correctness"]}))}
                                        </div>
                                        for (i, r) in enumerate(mhResults)
                                    ]}
                                    {resultsTable({"rows": mhResults})}
                                    {summaryPanel({"rows": mhResults, "group_key": "n_mid"})}
                                </div>
                            )}
                        </div>
                    )}

                    {(activeTab == "edgefilter" and
                        <div>
                            <div style={{"background": "#fff", "border": "1px solid #e2e8f0", "borderRadius": "10px", "padding": "22px", "marginBottom": "24px"}}>
                                <h2 style={{"margin": "0 0 4px 0", "fontSize": "15px", "fontWeight": "700", "color": "#1e293b"}}>Edge-type Filter</h2>
                                <p style={{"margin": "0 0 6px 0", "fontSize": "12px", "color": "#64748b"}}>
                                    Graph: BenchRoot –[FollowEdge]→ [PostNode | OtherNode]  ·  BenchRoot –[LikeEdge]→ PostNode.
                                    Two queries benchmarked per run:
                                </p>
                                <ul style={{"margin": "0 0 18px 0", "paddingLeft": "18px", "fontSize": "12px", "color": "#64748b", "lineHeight": "2.0"}}>
                                    <li><code>[-[FollowEdge]->]</code> — edge-type filter only. SAM "e:FollowEdge" column. Matches FollowEdge targets regardless of node type.</li>
                                    <li><code>[-[FollowEdge]->(?:PostNode)]</code> — combined filter. SAM intersection of "e:FollowEdge" ∩ "n:PostNode". Only nodes that are both FollowEdge targets AND PostNode.</li>
                                </ul>

                                <div style={{"background": "#faf5ff", "border": "1px solid #e9d5ff", "borderRadius": "6px", "padding": "12px 14px", "marginBottom": "18px", "fontSize": "12px", "color": "#6b21a8", "lineHeight": "2.0"}}>
                                    <div><span style={{"background": "#8b5cf6", "color": "#fff", "borderRadius": "4px", "padding": "1px 7px", "fontWeight": "700", "marginRight": "6px"}}>OFF</span> Walks all edges, checks <code>isinstance(edge, FollowEdge)</code> and optionally <code>isinstance(node, PostNode)</code> in Python. Loads all {efFollowPost + efFollowOther + efLikePost} stubs regardless of match.</div>
                                    <div><span style={{"background": "#f59e0b", "color": "#fff", "borderRadius": "4px", "padding": "1px 7px", "fontWeight": "700", "marginRight": "6px"}}>ON cold</span> SAM miss → 1 GTI SQL query per sub-query. Edge-only: <code>WHERE edge_type='FollowEdge'</code>. Combined: two queries (node + edge columns), then Python set intersection. Warms SAM "e:" and "n:" columns separately.</div>
                                    <div><span style={{"background": "#10b981", "color": "#fff", "borderRadius": "4px", "padding": "1px 7px", "fontWeight": "700", "marginRight": "6px"}}>ON warm</span> SAM hit: edge-only → O(1) dict lookup of "e:FollowEdge". Combined → O(min(a,b)) set intersection in memory. Fetches only matching node anchors.</div>
                                </div>

                                <div style={{"display": "flex", "gap": "24px", "flexWrap": "wrap", "alignItems": "flex-end"}}>
                                    <div>
                                        <label style={labelStyle}>FollowEdge → PostNode</label>
                                        <select value={efFollowPost} onChange={lambda e: Any -> None { efFollowPost = int(e.target.value);}} style={selectStyle}>
                                            <option value={10}>10</option>
                                            <option value={20}>20</option>
                                            <option value={50}>50</option>
                                            <option value={100}>100</option>
                                        </select>
                                    </div>
                                    <div>
                                        <label style={labelStyle}>FollowEdge → OtherNode</label>
                                        <select value={efFollowOther} onChange={lambda e: Any -> None { efFollowOther = int(e.target.value);}} style={selectStyle}>
                                            <option value={10}>10</option>
                                            <option value={30}>30</option>
                                            <option value={80}>80</option>
                                            <option value={200}>200</option>
                                        </select>
                                    </div>
                                    <div>
                                        <label style={labelStyle}>LikeEdge → PostNode</label>
                                        <select value={efLikePost} onChange={lambda e: Any -> None { efLikePost = int(e.target.value);}} style={selectStyle}>
                                            <option value={20}>20</option>
                                            <option value={50}>50</option>
                                            <option value={100}>100</option>
                                            <option value={200}>200</option>
                                        </select>
                                    </div>
                                    <div>
                                        <label style={labelStyle}>Iterations</label>
                                        <select value={efIters} onChange={lambda e: Any -> None { efIters = int(e.target.value);}} style={selectStyle}>
                                            <option value={1}>1</option>
                                            <option value={5}>5</option>
                                            <option value={10}>10</option>
                                        </select>
                                    </div>
                                    <button onClick={handleBenchEdgeFilter} disabled={efLoading} style={btnStyle("#7c3aed")}>
                                        {("Running..." if efLoading else "Run Benchmark")}
                                    </button>
                                </div>
                                {(efStatus and <p style={{"margin": "14px 0 0 0", "color": "#0f766e", "fontSize": "13px"}}>{efStatus}</p>)}
                                {(efError  and <p style={{"margin": "14px 0 0 0", "color": "#dc2626", "fontSize": "13px"}}>Error: {efError}</p>)}
                            </div>

                            {(len(efResults) > 0 and
                                <div style={{"background": "#fff", "border": "1px solid #e2e8f0", "borderRadius": "10px", "padding": "22px"}}>
                                    <h2 style={{"margin": "0 0 18px 0", "fontSize": "15px", "fontWeight": "700"}}>Results</h2>
                                    {[
                                        <div key={i} style={{"marginBottom": "28px", "paddingBottom": "20px", "borderBottom": "1px solid #f1f5f9"}}>
                                            <div style={{"display": "flex", "alignItems": "center", "gap": "8px", "marginBottom": "10px"}}>
                                                <span style={{"fontSize": "12px", "color": "#374151", "fontWeight": "700"}}>
                                                    {f"fan={r['fan_out']}  follow={r['n_follow']}  combined_match={r['n_combined']}  iter={r['iterations']}"}
                                                </span>
                                                {(r["correctness"] and correctnessBadge({"c": r["correctness"]}))}
                                            </div>

                                            <div style={{"display": "grid", "gridTemplateColumns": "1fr 1fr", "gap": "16px"}}>

                                                <div style={{"background": "#f5f3ff", "borderRadius": "8px", "padding": "14px"}}>
                                                    <div style={{"fontSize": "11px", "fontWeight": "700", "color": "#6b21a8", "marginBottom": "6px", "textTransform": "uppercase", "letterSpacing": "0.05em"}}>
                                                        [-[FollowEdge]-&gt;]  (edge-type only)
                                                    </div>
                                                    <div style={{"fontSize": "10px", "color": "#94a3b8", "marginBottom": "8px"}}>
                                                        {f"Matches {r['n_follow']} of {r['fan_out']} — skips {r['fan_out'] - r['n_follow']} LikeEdge targets"}
                                                    </div>
                                                    {barRow({"label": "OFF",     "color": "#8b5cf6", "val": r["edge_off_ms"],  "maxVal": max(r["edge_off_ms"], r["edge_cold_ms"], r["edge_warm_ms"])})}
                                                    {barRow({"label": "ON cold", "color": "#f59e0b", "val": r["edge_cold_ms"], "maxVal": max(r["edge_off_ms"], r["edge_cold_ms"], r["edge_warm_ms"])})}
                                                    {barRow({"label": "ON warm", "color": "#10b981", "val": r["edge_warm_ms"], "maxVal": max(r["edge_off_ms"], r["edge_cold_ms"], r["edge_warm_ms"])})}
                                                    <div style={{"display": "flex", "alignItems": "center", "gap": "8px", "marginTop": "8px"}}>
                                                        {interpBadge({"sp": r["edge_speedup_warm"] or 0.0})}
                                                        {(r["edge_cold_stats"] and
                                                            <span style={{"display": "flex", "gap": "4px"}}>
                                                                {statsPill({"label": "SAM hits",   "val": r["edge_cold_stats"]["sam_hits"]   or 0, "color": "#0d9488"})}
                                                                {statsPill({"label": "SAM misses", "val": r["edge_cold_stats"]["sam_misses"] or 0, "color": "#f59e0b"})}
                                                                {statsPill({"label": "GTI hits",   "val": r["edge_cold_stats"]["gti_hits"]   or 0, "color": "#0369a1"})}
                                                            </span>
                                                        )}
                                                    </div>
                                                    {(r["correctness"] and correctnessPanelEdge({"c": r["correctness"]}))}
                                                </div>

                                                <div style={{"background": "#ecfdf5", "borderRadius": "8px", "padding": "14px"}}>
                                                    <div style={{"fontSize": "11px", "fontWeight": "700", "color": "#065f46", "marginBottom": "6px", "textTransform": "uppercase", "letterSpacing": "0.05em"}}>
                                                        [-[FollowEdge]-&gt;(?:PostNode)]  (combined)
                                                    </div>
                                                    <div style={{"fontSize": "10px", "color": "#94a3b8", "marginBottom": "8px"}}>
                                                        {f"Matches {r['n_combined']} of {r['fan_out']} — intersect(e:FollowEdge ∩ n:PostNode)"}
                                                    </div>
                                                    {barRow({"label": "OFF",     "color": "#8b5cf6", "val": r["comb_off_ms"],  "maxVal": max(r["comb_off_ms"], r["comb_cold_ms"], r["comb_warm_ms"])})}
                                                    {barRow({"label": "ON cold", "color": "#f59e0b", "val": r["comb_cold_ms"], "maxVal": max(r["comb_off_ms"], r["comb_cold_ms"], r["comb_warm_ms"])})}
                                                    {barRow({"label": "ON warm", "color": "#10b981", "val": r["comb_warm_ms"], "maxVal": max(r["comb_off_ms"], r["comb_cold_ms"], r["comb_warm_ms"])})}
                                                    <div style={{"display": "flex", "alignItems": "center", "gap": "8px", "marginTop": "8px"}}>
                                                        {interpBadge({"sp": r["comb_speedup_warm"] or 0.0})}
                                                        {(r["comb_cold_stats"] and
                                                            <span style={{"display": "flex", "gap": "4px"}}>
                                                                {statsPill({"label": "SAM hits",   "val": r["comb_cold_stats"]["sam_hits"]   or 0, "color": "#0d9088"})}
                                                                {statsPill({"label": "SAM misses", "val": r["comb_cold_stats"]["sam_misses"] or 0, "color": "#f59e0b"})}
                                                                {statsPill({"label": "GTI hits",   "val": r["comb_cold_stats"]["gti_hits"]   or 0, "color": "#0369a1"})}
                                                            </span>
                                                        )}
                                                    </div>
                                                    {(r["correctness"] and correctnessPanelComb({"c": r["correctness"]}))}
                                                </div>

                                            </div>
                                        </div>
                                        for (i, r) in enumerate(efResults)
                                    ]}
                                </div>
                            )}
                        </div>
                    )}

                </div>
            </div>;
    }
}
