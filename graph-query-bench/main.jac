"""
Graph Query Benchmark
=====================
Compares three query strategies for filtered walker traversals in Jaseci:

  Local path: [here-->](?:TargetNode)
    Loads ALL connected nodes from SQLite, filters by type in memory.

  GT path (simulated topology index):
    Looks up matching node IDs from a JSON sidecar index keyed by source node ID,
    then fetches only those nodes through the memory hierarchy.

  AM path (in-memory source-type adjacency matrix):
    Pure in-memory dict: { source_id: { node_type: [target_ids] } }
    O(1) dict lookup, no file I/O, volatile (lost on restart).
    Then fetches only matching nodes from SQLite.

Scenarios covered:
  1. Single-hop      root --> [TargetNode | OtherNode]
  2. Inheritance     root --> [PostNode | CommentNode | OtherNode]
                     query (?:BaseContent) returns PostNode + CommentNode via MRO
  3. Multi-hop       root --> MidNode --> [TargetNode | OtherNode]  (2-hop)
  4. Arbitrary start traverse from a non-root MidNode, not from root

GT index format (JSON, keyed by source node UUID string):
  { "src_uuid": { "TypeName": ["uuid", ...] } }
  Same structure as am_index — supports all four scenarios uniformly.

Run with:
  cd benchmarks/graph-query-bench
  jac install
  jac start main.jac --dev
"""

import from os.path { join, exists }
import from os { makedirs, getcwd }
import from time { perf_counter }
import from uuid { UUID }
import from json { dumps, loads }
import from jaclang.jac0core.runtime { JacRuntimeInterface }
import from am_store { am_index, get_type_mro }

# ============================================================================
# GRAPH NODES
# ============================================================================

# Single-hop benchmark
node TargetNode { has node_id: int; }
node OtherNode  { has node_id: int; }

# Inheritance benchmark
# get_type_mro(PostNode())    → ["PostNode", "BaseContent"]
# get_type_mro(CommentNode()) → ["CommentNode", "BaseContent"]
# Index fan-out at write time: both stored under "BaseContent" bucket.
# Query (?:BaseContent) hits that bucket → returns PostNode + CommentNode.
node BaseContent             { has node_id: int; }
node PostNode(BaseContent)   { has node_id: int; }
node CommentNode(BaseContent){ has node_id: int; }

# Multi-hop / arbitrary-start benchmark
node MidNode { has node_id: int; }

# ============================================================================
# TOPOLOGY INDEX HELPERS
# GT index: { "src_uuid_str": { "TypeName": ["uuid_str", ...] } }
# Keyed by source node ID so a single file serves all four scenarios.
# ============================================================================

def topo_path -> str {
    p = join(getcwd(), ".jac", "data");
    makedirs(p, exist_ok=True);
    return join(p, "bench_topo_index.json");
}

def load_topo -> dict {
    path = topo_path();
    if exists(path) {
        f = open(path, "r");
        data = loads(f.read());
        f.close();
        return data;
    }
    return {};
}

def save_topo(index: dict) -> None {
    f = open(topo_path(), "w");
    f.write(dumps(index));
    f.close();
}

# ============================================================================
# SCENARIO 1 — SINGLE-HOP
# seed_graph  : root -> [TargetNode, OtherNode]
# run_benchmark: [here-->(?:TargetNode)]
# ============================================================================

walker:pub seed_graph {
    has fan_out: int = 50,
        selectivity: float = 0.5;

    can seed with Root entry {
        target_count = int(self.fan_out * self.selectivity);
        source_key = str(here.__jac__.id);
        gt_full = load_topo();
        gt_full[source_key] = {};
        am_index[source_key] = {};

        for i in range(self.fan_out) {
            if i < target_count {
                n = (here ++> TargetNode(node_id=i))[0];
            } else {
                n = (here ++> OtherNode(node_id=i))[0];
            }
            tid = str(n.__jac__.id);
            for type_name in get_type_mro(n) {
                if type_name not in gt_full[source_key] { gt_full[source_key][type_name] = []; }
                gt_full[source_key][type_name].append(tid);
                if type_name not in am_index[source_key] { am_index[source_key][type_name] = []; }
                am_index[source_key][type_name].append(tid);
            }
        }
        save_topo(gt_full);
        report {
            "status": "seeded",
            "fan_out": self.fan_out,
            "selectivity": self.selectivity,
            "target_nodes": target_count,
            "other_nodes": self.fan_out - target_count
        };
    }
}

walker:pub run_benchmark {
    has fan_out: int = 50,
        selectivity: float = 0.5,
        iterations: int = 5;

    can bench with Root entry {
        if not [here-->(?:TargetNode)] and not [here-->(?:OtherNode)] {
            report {"error": "Graph not seeded. Run seed_graph first."};
            disengage;
        }
        ctx = JacRuntimeInterface.get_context();
        source_key = str(here.__jac__.id);
        gt_full = load_topo();
        target_ids    = gt_full.get(source_key, {}).get("TargetNode", []);
        am_target_ids = am_index.get(source_key, {}).get("TargetNode", []);

        local_times: list = [];
        gt_times: list = [];
        am_times: list = [];

        for _ in range(self.iterations) {
            ctx.mem.__mem__.clear();
            t0 = perf_counter();
            local_results = [here-->(?:TargetNode)];
            t1 = perf_counter();
            local_times.append((t1 - t0) * 1000.0);

            ctx.mem.__mem__.clear();
            t2 = perf_counter();
            gt_results = [];
            for tid in target_ids {
                anchor = ctx.mem.get(UUID(tid));
                if anchor { gt_results.append(anchor); }
            }
            t3 = perf_counter();
            gt_times.append((t3 - t2) * 1000.0);

            ctx.mem.__mem__.clear();
            t4 = perf_counter();
            am_results = [];
            for tid in am_target_ids {
                anchor = ctx.mem.get(UUID(tid));
                if anchor { am_results.append(anchor); }
            }
            t5 = perf_counter();
            am_times.append((t5 - t4) * 1000.0);
        }

        avg_local = sum(local_times) / len(local_times);
        avg_gt    = sum(gt_times) / len(gt_times);
        avg_am    = sum(am_times) / len(am_times);
        best_avg  = min(avg_local, avg_gt, avg_am);
        winner    = ("local" if best_avg == avg_local else ("gt" if best_avg == avg_gt else "am"));
        report {
            "local_latency_ms":  round(avg_local, 3),
            "gt_latency_ms":     round(avg_gt, 3),
            "am_latency_ms":     round(avg_am, 3),
            "local_times_ms":    [round(t, 3) for t in local_times],
            "gt_times_ms":       [round(t, 3) for t in gt_times],
            "am_times_ms":       [round(t, 3) for t in am_times],
            "nodes_loaded_local": self.fan_out,
            "nodes_loaded_gt":    len(target_ids),
            "nodes_loaded_am":    len(am_target_ids),
            "winner":     winner,
            "speedup_gt": round(avg_local / avg_gt, 2) if avg_gt > 0 else 0.0,
            "speedup_am": round(avg_local / avg_am, 2) if avg_am > 0 else 0.0,
            "fan_out":     self.fan_out,
            "selectivity": self.selectivity,
            "iterations":  self.iterations
        };
    }
}

walker:pub run_all_scenarios {
    has iterations: int = 5;

    can run_all with Root entry {
        fan_outs: list = [5, 50, 200, 500];
        selectivities: list = [0.1, 0.25, 0.5, 0.75, 0.9];
        all_results: list = [];
        heatmap: dict = {};
        ctx = JacRuntimeInterface.get_context();

        for fan_out in fan_outs {
            for sel in selectivities {
                target_count = int(fan_out * sel);
                source_key = str(here.__jac__.id);
                new_nodes: list = [];
                gt_iter: dict = {};
                am_index[source_key] = {};

                for i in range(fan_out) {
                    if i < target_count {
                        n = (here ++> TargetNode(node_id=i))[0];
                    } else {
                        n = (here ++> OtherNode(node_id=i))[0];
                    }
                    tid = str(n.__jac__.id);
                    new_nodes.append(n);
                    for type_name in get_type_mro(n) {
                        if type_name not in gt_iter { gt_iter[type_name] = []; }
                        gt_iter[type_name].append(tid);
                        if type_name not in am_index[source_key] { am_index[source_key][type_name] = []; }
                        am_index[source_key][type_name].append(tid);
                    }
                }
                save_topo({source_key: gt_iter});

                target_ids    = gt_iter.get("TargetNode", []);
                am_target_ids = am_index.get(source_key, {}).get("TargetNode", []);
                local_times: list = [];
                gt_times: list = [];
                am_times: list = [];

                for _ in range(self.iterations) {
                    ctx.mem.__mem__.clear();
                    t0 = perf_counter();
                    local_results = [here-->(?:TargetNode)];
                    t1 = perf_counter();
                    local_times.append((t1 - t0) * 1000.0);

                    ctx.mem.__mem__.clear();
                    t2 = perf_counter();
                    gt_res = [];
                    for tid in target_ids {
                        anchor = ctx.mem.get(UUID(tid));
                        if anchor { gt_res.append(anchor); }
                    }
                    t3 = perf_counter();
                    gt_times.append((t3 - t2) * 1000.0);

                    ctx.mem.__mem__.clear();
                    t4 = perf_counter();
                    am_res = [];
                    for tid in am_target_ids {
                        anchor = ctx.mem.get(UUID(tid));
                        if anchor { am_res.append(anchor); }
                    }
                    t5 = perf_counter();
                    am_times.append((t5 - t4) * 1000.0);
                }

                avg_local = sum(local_times) / len(local_times);
                avg_gt    = sum(gt_times) / len(gt_times);
                avg_am    = sum(am_times) / len(am_times);
                best_avg  = min(avg_local, avg_gt, avg_am);
                winner    = ("local" if best_avg == avg_local else ("gt" if best_avg == avg_gt else "am"));
                sp_gt = round(avg_local / avg_gt, 2) if avg_gt > 0 else 0.0;
                sp_am = round(avg_local / avg_am, 2) if avg_am > 0 else 0.0;

                result = {
                    "local_latency_ms":  round(avg_local, 3),
                    "gt_latency_ms":     round(avg_gt, 3),
                    "am_latency_ms":     round(avg_am, 3),
                    "nodes_loaded_local": fan_out,
                    "nodes_loaded_gt":    len(target_ids),
                    "nodes_loaded_am":    len(am_target_ids),
                    "winner":     winner,
                    "speedup_gt": sp_gt,
                    "speedup_am": sp_am,
                    "fan_out":     fan_out,
                    "selectivity": sel,
                    "iterations":  self.iterations
                };
                all_results.append(result);

                sel_key = str(int(sel * 100));
                fo_key  = str(fan_out);
                if sel_key not in heatmap { heatmap[sel_key] = {}; }
                heatmap[sel_key][fo_key] = {"speedup_gt": sp_gt, "speedup_am": sp_am, "winner": winner};

                for n in new_nodes { del n; }
                save_topo({});
                am_index.clear();
                ctx.mem.__mem__.clear();
            }
        }
        report {"results": all_results, "heatmap": heatmap};
    }
}

# ============================================================================
# SCENARIO 2 — INHERITANCE
# Graph:  root -> [PostNode, CommentNode, OtherNode]
# Seeding: index each node under all MRO types (fan-out at write time).
#          PostNode  → buckets "PostNode", "BaseContent"
#          CommentNode → buckets "CommentNode", "BaseContent"
# Query:  [here-->(?:BaseContent)] — GT/AM look up "BaseContent" bucket,
#          which already contains PostNode + CommentNode IDs.
#          Local loads ALL fan_out neighbors then filters by isinstance.
# ============================================================================

walker:pub seed_inheritance_graph {
    has fan_out: int = 50,
        selectivity: float = 0.6;   # fraction of nodes that are BaseContent subclasses

    can seed with Root entry {
        base_count    = int(self.fan_out * self.selectivity);
        post_count    = base_count // 2;
        comment_count = base_count - post_count;
        other_count   = self.fan_out - base_count;

        source_key = str(here.__jac__.id);
        gt_full = load_topo();
        gt_full[source_key] = {};
        am_index[source_key] = {};

        for i in range(post_count) {
            n = (here ++> PostNode(node_id=i))[0];
            tid = str(n.__jac__.id);
            for type_name in get_type_mro(n) {
                if type_name not in gt_full[source_key] { gt_full[source_key][type_name] = []; }
                gt_full[source_key][type_name].append(tid);
                if type_name not in am_index[source_key] { am_index[source_key][type_name] = []; }
                am_index[source_key][type_name].append(tid);
            }
        }
        for i in range(comment_count) {
            n = (here ++> CommentNode(node_id=i))[0];
            tid = str(n.__jac__.id);
            for type_name in get_type_mro(n) {
                if type_name not in gt_full[source_key] { gt_full[source_key][type_name] = []; }
                gt_full[source_key][type_name].append(tid);
                if type_name not in am_index[source_key] { am_index[source_key][type_name] = []; }
                am_index[source_key][type_name].append(tid);
            }
        }
        for i in range(other_count) {
            n = (here ++> OtherNode(node_id=i))[0];
            tid = str(n.__jac__.id);
            for type_name in get_type_mro(n) {
                if type_name not in gt_full[source_key] { gt_full[source_key][type_name] = []; }
                gt_full[source_key][type_name].append(tid);
                if type_name not in am_index[source_key] { am_index[source_key][type_name] = []; }
                am_index[source_key][type_name].append(tid);
            }
        }
        save_topo(gt_full);
        report {
            "status": "seeded",
            "fan_out": self.fan_out,
            "post_nodes": post_count,
            "comment_nodes": comment_count,
            "other_nodes": other_count,
            "base_content_total": base_count
        };
    }
}

walker:pub bench_inheritance {
    has fan_out: int = 50,
        selectivity: float = 0.6,
        iterations: int = 5;

    can bench with Root entry {
        ctx = JacRuntimeInterface.get_context();
        source_key = str(here.__jac__.id);
        gt_full = load_topo();
        base_ids_gt = gt_full.get(source_key, {}).get("BaseContent", []);
        base_ids_am = am_index.get(source_key, {}).get("BaseContent", []);

        if not base_ids_gt {
            report {"error": "Not seeded. Run seed_inheritance_graph first."};
            disengage;
        }

        local_times: list = [];
        gt_times: list = [];
        am_times: list = [];

        for _ in range(self.iterations) {
            # Local: loads ALL fan_out nodes, filters to BaseContent subclasses in memory
            ctx.mem.__mem__.clear();
            t0 = perf_counter();
            local_results = [here-->(?:BaseContent)];
            t1 = perf_counter();
            local_times.append((t1 - t0) * 1000.0);

            # GT: "BaseContent" bucket already contains PostNode + CommentNode IDs
            ctx.mem.__mem__.clear();
            t2 = perf_counter();
            gt_results = [];
            for tid in base_ids_gt {
                anchor = ctx.mem.get(UUID(tid));
                if anchor { gt_results.append(anchor); }
            }
            t3 = perf_counter();
            gt_times.append((t3 - t2) * 1000.0);

            # AM: same as GT but from in-memory dict
            ctx.mem.__mem__.clear();
            t4 = perf_counter();
            am_results = [];
            for tid in base_ids_am {
                anchor = ctx.mem.get(UUID(tid));
                if anchor { am_results.append(anchor); }
            }
            t5 = perf_counter();
            am_times.append((t5 - t4) * 1000.0);
        }

        avg_local = sum(local_times) / len(local_times);
        avg_gt    = sum(gt_times) / len(gt_times);
        avg_am    = sum(am_times) / len(am_times);
        best_avg  = min(avg_local, avg_gt, avg_am);
        winner    = ("local" if best_avg == avg_local else ("gt" if best_avg == avg_gt else "am"));
        report {
            "local_latency_ms":   round(avg_local, 3),
            "gt_latency_ms":      round(avg_gt, 3),
            "am_latency_ms":      round(avg_am, 3),
            "nodes_loaded_local": self.fan_out,
            "nodes_loaded_gt":    len(base_ids_gt),
            "nodes_loaded_am":    len(base_ids_am),
            "winner":     winner,
            "speedup_gt": round(avg_local / avg_gt, 2) if avg_gt > 0 else 0.0,
            "speedup_am": round(avg_local / avg_am, 2) if avg_am > 0 else 0.0,
            "fan_out":     self.fan_out,
            "selectivity": self.selectivity,
            "iterations":  self.iterations,
            "scenario":    "inheritance"
        };
    }
}

# ============================================================================
# SCENARIO 3 — MULTI-HOP  (2-hop)
# Graph:  root --> MidNode[i] --> [TargetNode, OtherNode]
# Index:  root source_key  → "MidNode": [mid_ids]
#         each mid_id      → "TargetNode": [target_ids], "OtherNode": [other_ids]
#
# Local:  hop1 = [here-->(?:MidNode)]
#         for each mid, iterate mid.__jac__.edges (outgoing), fetch targets, filter
#         Cost: mid_count + mid_count × branch_factor SQLite fetches
#
# GT/AM:  2 sequential index lookups → bulk fetch of TargetNodes only
#         Cost: mid_count × selectivity × branch_factor SQLite fetches
# ============================================================================

walker:pub seed_multihop_graph {
    has mid_count: int = 10,
        branch_factor: int = 20,
        selectivity: float = 0.3;

    can seed with Root entry {
        source_key = str(here.__jac__.id);
        gt_full = load_topo();
        gt_full[source_key] = {};
        am_index[source_key] = {};

        target_per_mid = int(self.branch_factor * self.selectivity);
        total_target = 0;

        for i in range(self.mid_count) {
            mid = (here ++> MidNode(node_id=i))[0];
            mid_id = str(mid.__jac__.id);

            # Layer 1: root → MidNode
            for type_name in get_type_mro(mid) {
                if type_name not in gt_full[source_key] { gt_full[source_key][type_name] = []; }
                gt_full[source_key][type_name].append(mid_id);
                if type_name not in am_index[source_key] { am_index[source_key][type_name] = []; }
                am_index[source_key][type_name].append(mid_id);
            }

            # Layer 2: MidNode → [TargetNode, OtherNode]
            gt_full[mid_id] = {};
            am_index[mid_id] = {};
            for j in range(self.branch_factor) {
                if j < target_per_mid {
                    child = (mid ++> TargetNode(node_id=j))[0];
                    total_target += 1;
                } else {
                    child = (mid ++> OtherNode(node_id=j))[0];
                }
                child_id = str(child.__jac__.id);
                for type_name in get_type_mro(child) {
                    if type_name not in gt_full[mid_id] { gt_full[mid_id][type_name] = []; }
                    gt_full[mid_id][type_name].append(child_id);
                    if type_name not in am_index[mid_id] { am_index[mid_id][type_name] = []; }
                    am_index[mid_id][type_name].append(child_id);
                }
            }
        }
        save_topo(gt_full);
        report {
            "status": "seeded",
            "mid_count": self.mid_count,
            "branch_factor": self.branch_factor,
            "selectivity": self.selectivity,
            "total_mid_nodes": self.mid_count,
            "total_target_nodes": total_target,
            "total_other_nodes": self.mid_count * self.branch_factor - total_target
        };
    }
}

walker:pub bench_multihop {
    has mid_count: int = 10,
        branch_factor: int = 20,
        selectivity: float = 0.3,
        iterations: int = 5;

    can bench with Root entry {
        ctx = JacRuntimeInterface.get_context();
        source_key = str(here.__jac__.id);
        gt_full = load_topo();

        mid_ids_gt = gt_full.get(source_key, {}).get("MidNode", []);
        if not mid_ids_gt {
            report {"error": "Not seeded. Run seed_multihop_graph first."};
            disengage;
        }

        # Pre-resolve 2-hop target IDs via index (no SQLite yet)
        target_ids_gt: list = [];
        for mid_id in mid_ids_gt {
            target_ids_gt += gt_full.get(mid_id, {}).get("TargetNode", []);
        }
        mid_ids_am = am_index.get(source_key, {}).get("MidNode", []);
        target_ids_am: list = [];
        for mid_id in mid_ids_am {
            target_ids_am += am_index.get(mid_id, {}).get("TargetNode", []);
        }

        local_times: list = [];
        gt_times: list = [];
        am_times: list = [];

        for _ in range(self.iterations) {
            # Local 2-hop: load MidNodes (hop 1), then for each mid scan its outgoing
            # edges and fetch+filter TargetNode children (hop 2).
            ctx.mem.__mem__.clear();
            t0 = perf_counter();
            hop1 = [here-->(?:MidNode)];
            local_2hop: list = [];
            for mid in hop1 {
                mid_id_str = str(mid.__jac__.id);
                for edge in mid.__jac__.edges {
                    if str(edge.source.id) == mid_id_str {      # outgoing edges only
                        target_anchor = ctx.mem.get(edge.target.id);
                        if target_anchor and isinstance(target_anchor.archetype, TargetNode) {
                            local_2hop.append(target_anchor);
                        }
                    }
                }
            }
            t1 = perf_counter();
            local_times.append((t1 - t0) * 1000.0);

            # GT 2-hop: index resolved target IDs → bulk fetch from SQLite
            ctx.mem.__mem__.clear();
            t2 = perf_counter();
            gt_2hop: list = [];
            for tid in target_ids_gt {
                anchor = ctx.mem.get(UUID(tid));
                if anchor { gt_2hop.append(anchor); }
            }
            t3 = perf_counter();
            gt_times.append((t3 - t2) * 1000.0);

            # AM 2-hop: same as GT but index lookup is pure in-memory
            ctx.mem.__mem__.clear();
            t4 = perf_counter();
            am_2hop: list = [];
            for tid in target_ids_am {
                anchor = ctx.mem.get(UUID(tid));
                if anchor { am_2hop.append(anchor); }
            }
            t5 = perf_counter();
            am_times.append((t5 - t4) * 1000.0);
        }

        avg_local = sum(local_times) / len(local_times);
        avg_gt    = sum(gt_times) / len(gt_times);
        avg_am    = sum(am_times) / len(am_times);
        best_avg  = min(avg_local, avg_gt, avg_am);
        winner    = ("local" if best_avg == avg_local else ("gt" if best_avg == avg_gt else "am"));
        total_local_fetches = self.mid_count + self.mid_count * self.branch_factor;
        report {
            "local_latency_ms":   round(avg_local, 3),
            "gt_latency_ms":      round(avg_gt, 3),
            "am_latency_ms":      round(avg_am, 3),
            "nodes_loaded_local": total_local_fetches,
            "nodes_loaded_gt":    len(target_ids_gt),
            "nodes_loaded_am":    len(target_ids_am),
            "winner":     winner,
            "speedup_gt": round(avg_local / avg_gt, 2) if avg_gt > 0 else 0.0,
            "speedup_am": round(avg_local / avg_am, 2) if avg_am > 0 else 0.0,
            "mid_count":    self.mid_count,
            "branch_factor": self.branch_factor,
            "selectivity":  self.selectivity,
            "iterations":   self.iterations,
            "scenario":     "multihop"
        };
    }
}

# ============================================================================
# SCENARIO 4 — ARBITRARY START NODE
# Uses the multi-hop graph (seed_multihop_graph must have run first).
# Picks the first MidNode as a non-root starting point and benchmarks
# [midnode-->(?:TargetNode)] from there.
#
# Local: fetch MidNode anchor from SQLite, iterate its outgoing edges,
#        fetch each child anchor, filter by type.
# GT:    gt_full[mid_id]["TargetNode"] — direct lookup by MidNode's own key.
# AM:    am_index[mid_id]["TargetNode"] — same but in-memory.
#
# This demonstrates that both indexes are source-agnostic: the index is keyed
# by source node ID, so any node in the graph (not just root) can be the
# starting point of an O(1) index lookup.
# ============================================================================

walker:pub bench_arbitrary_start {
    has iterations: int = 5;

    can bench with Root entry {
        ctx = JacRuntimeInterface.get_context();
        source_key = str(here.__jac__.id);
        gt_full = load_topo();

        mid_ids = gt_full.get(source_key, {}).get("MidNode", []);
        if not mid_ids {
            report {"error": "No multi-hop graph found. Run seed_multihop_graph first."};
            disengage;
        }

        # Use the first MidNode as our arbitrary non-root start point
        arb_mid_id        = mid_ids[0];
        arb_tgt_ids_gt    = gt_full.get(arb_mid_id, {}).get("TargetNode", []);
        arb_tgt_ids_am    = am_index.get(arb_mid_id, {}).get("TargetNode", []);
        branch_total      = (
            len(gt_full.get(arb_mid_id, {}).get("TargetNode", [])) +
            len(gt_full.get(arb_mid_id, {}).get("OtherNode", []))
        );

        local_times: list = [];
        gt_times: list = [];
        am_times: list = [];

        for _ in range(self.iterations) {
            # Local: fetch MidNode from SQLite, then scan its outgoing edges
            ctx.mem.__mem__.clear();
            t0 = perf_counter();
            mid_anchor = ctx.mem.get(UUID(arb_mid_id));
            local_arb: list = [];
            if mid_anchor {
                for edge in mid_anchor.edges {
                    if str(edge.source.id) == arb_mid_id {   # outgoing edges only
                        target_anchor = ctx.mem.get(edge.target.id);
                        if target_anchor and isinstance(target_anchor.archetype, TargetNode) {
                            local_arb.append(target_anchor);
                        }
                    }
                }
            }
            t1 = perf_counter();
            local_times.append((t1 - t0) * 1000.0);

            # GT: direct lookup using MidNode's ID as source key
            ctx.mem.__mem__.clear();
            t2 = perf_counter();
            gt_arb: list = [];
            for tid in arb_tgt_ids_gt {
                anchor = ctx.mem.get(UUID(tid));
                if anchor { gt_arb.append(anchor); }
            }
            t3 = perf_counter();
            gt_times.append((t3 - t2) * 1000.0);

            # AM: same as GT, but from in-process dict
            ctx.mem.__mem__.clear();
            t4 = perf_counter();
            am_arb: list = [];
            for tid in arb_tgt_ids_am {
                anchor = ctx.mem.get(UUID(tid));
                if anchor { am_arb.append(anchor); }
            }
            t5 = perf_counter();
            am_times.append((t5 - t4) * 1000.0);
        }

        avg_local = sum(local_times) / len(local_times);
        avg_gt    = sum(gt_times) / len(gt_times);
        avg_am    = sum(am_times) / len(am_times);
        best_avg  = min(avg_local, avg_gt, avg_am);
        winner    = ("local" if best_avg == avg_local else ("gt" if best_avg == avg_gt else "am"));
        report {
            "local_latency_ms":   round(avg_local, 3),
            "gt_latency_ms":      round(avg_gt, 3),
            "am_latency_ms":      round(avg_am, 3),
            "nodes_loaded_local": branch_total,
            "nodes_loaded_gt":    len(arb_tgt_ids_gt),
            "nodes_loaded_am":    len(arb_tgt_ids_am),
            "winner":      winner,
            "speedup_gt":  round(avg_local / avg_gt, 2) if avg_gt > 0 else 0.0,
            "speedup_am":  round(avg_local / avg_am, 2) if avg_am > 0 else 0.0,
            "start_node":  arb_mid_id,
            "iterations":  self.iterations,
            "scenario":    "arbitrary_start"
        };
    }
}

# ============================================================================
# WALKER: clear_graph
# Clears all node types from all four scenarios.
# ============================================================================

walker:pub clear_graph {
    can clear with Root entry {
        # Delete root's direct children (single-hop + inheritance scenarios)
        for n in [here-->(?:TargetNode)] { del n; }
        for n in [here-->(?:OtherNode)]  { del n; }
        for n in [here-->(?:PostNode)]   { del n; }
        for n in [here-->(?:CommentNode)] { del n; }
        # Delete MidNode children first, then the MidNodes themselves
        # (avoids nested visit-inside-handler recursion)
        for mid in [here-->(?:MidNode)] {
            for n in [mid-->(?:TargetNode)] { del n; }
            for n in [mid-->(?:OtherNode)]  { del n; }
            del mid;
        }
        save_topo({});
        am_index.clear();
        report {"status": "cleared"};
    }
}

# ============================================================================
# FRONTEND
# ============================================================================

cl {
    def:pub app -> JsxElement {
        # Shared
        has activeTab: str = "singlehop",
            error: str = "",
            status: str = "",
            loading: bool = False;

        # Single-hop tab state
        has fanOut: int = 50,
            selectivity: float = 0.5,
            iterations: int = 5,
            results: list = [],
            heatmap: dict = {},
            showHeatmap: bool = False,
            seeding: bool = False,
            runningAll: bool = False;

        # Inheritance tab state
        has inheritFanOut: int = 50,
            inheritSelectivity: float = 0.6,
            inheritIters: int = 5,
            inheritSeeding: bool = False,
            inheritBenching: bool = False,
            inheritResults: list = [],
            inheritStatus: str = "",
            inheritError: str = "";

        # Multi-hop tab state
        has midCount: int = 10,
            branchFactor: int = 20,
            multihopSel: float = 0.3,
            multihopIters: int = 5,
            multihopSeeding: bool = False,
            multihopBenching: bool = False,
            multihopResults: list = [],
            multihopStatus: str = "",
            multihopError: str = "";

        # Arbitrary start tab state (reuses multi-hop graph, no separate seeding)
        has arbIters: int = 5,
            arbBenching: bool = False,
            arbResults: list = [],
            arbStatus: str = "",
            arbError: str = "";

        # ---- Single-hop handlers ----
        async def handleSeed -> None {
            seeding = True;
            status = "Seeding graph...";
            error = "";
            try {
                resp = root spawn seed_graph(fan_out=fanOut, selectivity=selectivity);
                info = resp.reports[0];
                status = f"Seeded: {info['target_nodes']} TargetNodes + {info['other_nodes']} OtherNodes";
            } except Exception as e {
                error = str(e);
                status = "";
            }
            seeding = False;
        }

        async def handleBenchmark -> None {
            loading = True;
            status = "Running benchmark...";
            error = "";
            try {
                resp = root spawn run_benchmark(fan_out=fanOut, selectivity=selectivity, iterations=iterations);
                r = resp.reports[0];
                if "error" in r {
                    error = r["error"];
                    status = "";
                } else {
                    results = results + [r];
                    status = f"Done. Winner: {r['winner']} (GT {r['speedup_gt']}x, AM {r['speedup_am']}x vs local)";
                }
            } except Exception as e {
                error = str(e);
                status = "";
            }
            loading = False;
        }

        async def handleRunAll -> None {
            runningAll = True;
            loading = True;
            status = "Running all 20 scenarios (4 fan-outs × 5 selectivities)...";
            error = "";
            try {
                resp = root spawn run_all_scenarios(iterations=iterations);
                r = resp.reports[0];
                results = results + r["results"];
                heatmap = r["heatmap"];
                showHeatmap = True;
                status = f"All scenarios complete: {len(r['results'])} runs added.";
            } except Exception as e {
                error = str(e);
                status = "";
            }
            loading = False;
            runningAll = False;
        }

        async def handleClear -> None {
            status = "Clearing...";
            error = "";
            try {
                root spawn clear_graph();
                results = [];
                heatmap = {};
                showHeatmap = False;
                inheritResults = [];
                multihopResults = [];
                arbResults = [];
                status = "Cleared.";
            } except Exception as e {
                error = str(e);
            }
        }

        # ---- Inheritance handlers ----
        async def handleSeedInheritance -> None {
            inheritSeeding = True;
            inheritStatus = "Seeding...";
            inheritError = "";
            try {
                resp = root spawn seed_inheritance_graph(fan_out=inheritFanOut, selectivity=inheritSelectivity);
                info = resp.reports[0];
                inheritStatus = f"Seeded: {info['post_nodes']} PostNodes + {info['comment_nodes']} CommentNodes + {info['other_nodes']} OtherNodes (BaseContent total: {info['base_content_total']})";
            } except Exception as e {
                inheritError = str(e);
                inheritStatus = "";
            }
            inheritSeeding = False;
        }

        async def handleBenchInheritance -> None {
            inheritBenching = True;
            inheritStatus = "Running...";
            inheritError = "";
            try {
                resp = root spawn bench_inheritance(fan_out=inheritFanOut, selectivity=inheritSelectivity, iterations=inheritIters);
                r = resp.reports[0];
                if "error" in r {
                    inheritError = r["error"];
                    inheritStatus = "";
                } else {
                    inheritResults = inheritResults + [r];
                    inheritStatus = f"Done. Winner: {r['winner']} (GT {r['speedup_gt']}x, AM {r['speedup_am']}x vs local)";
                }
            } except Exception as e {
                inheritError = str(e);
                inheritStatus = "";
            }
            inheritBenching = False;
        }

        # ---- Multi-hop handlers ----
        async def handleSeedMultihop -> None {
            multihopSeeding = True;
            multihopStatus = "Seeding...";
            multihopError = "";
            try {
                resp = root spawn seed_multihop_graph(mid_count=midCount, branch_factor=branchFactor, selectivity=multihopSel);
                info = resp.reports[0];
                multihopStatus = f"Seeded: {info['total_mid_nodes']} MidNodes, each with {branchFactor} children ({info['total_target_nodes']} TargetNodes + {info['total_other_nodes']} OtherNodes)";
            } except Exception as e {
                multihopError = str(e);
                multihopStatus = "";
            }
            multihopSeeding = False;
        }

        async def handleBenchMultihop -> None {
            multihopBenching = True;
            multihopStatus = "Running...";
            multihopError = "";
            try {
                resp = root spawn bench_multihop(mid_count=midCount, branch_factor=branchFactor, selectivity=multihopSel, iterations=multihopIters);
                r = resp.reports[0];
                if "error" in r {
                    multihopError = r["error"];
                    multihopStatus = "";
                } else {
                    multihopResults = multihopResults + [r];
                    multihopStatus = f"Done. Winner: {r['winner']} (GT {r['speedup_gt']}x, AM {r['speedup_am']}x vs local)";
                }
            } except Exception as e {
                multihopError = str(e);
                multihopStatus = "";
            }
            multihopBenching = False;
        }

        # ---- Arbitrary start handlers ----
        async def handleBenchArbitrary -> None {
            arbBenching = True;
            arbStatus = "Running...";
            arbError = "";
            try {
                resp = root spawn bench_arbitrary_start(iterations=arbIters);
                r = resp.reports[0];
                if "error" in r {
                    arbError = r["error"];
                    arbStatus = "";
                } else {
                    arbResults = arbResults + [r];
                    arbStatus = f"Done from node {r['start_node'][:8]}…  Winner: {r['winner']} (GT {r['speedup_gt']}x, AM {r['speedup_am']}x vs local)";
                }
            } except Exception as e {
                arbError = str(e);
                arbStatus = "";
            }
            arbBenching = False;
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
                "background": "none", "fontSize": "14px", "fontWeight": ("700" if active else "400"),
                "color": ("#0ea5e9" if active else "#64748b")
            };
        };

        # ---- Results bar chart helper ----
        def barRow(label: str, color: str, val: float, maxVal: float, key: str) -> JsxElement {
            return
                <div key={key} style={{"display": "flex", "alignItems": "center", "gap": "8px", "marginBottom": "4px"}}>
                    <span style={{"width": "60px", "fontSize": "12px", "color": color, "textAlign": "right"}}>{label}</span>
                    <div style={{
                        "height": "20px", "background": color, "borderRadius": "3px",
                        "width": f"{min(val / max(maxVal, 0.001) * 400, 400)}px",
                        "minWidth": "2px"
                    }}/>
                    <span style={{"fontSize": "12px", "fontFamily": "monospace", "color": color}}>{round(val, 3)} ms</span>
                </div>;
        }

        # ---- Shared results table ----
        def resultsTable(rows: list, extraCols: list = []) -> JsxElement {
            baseCols = ["Scenario", "Local avg (ms)", "GT avg (ms)", "AM avg (ms)", "Nodes Local", "Nodes GT/AM", "Speedup GT", "Speedup AM", "Winner"];
            cols = baseCols;
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
                                    <td style={{"padding": "10px 14px", "fontSize": "12px", "color": "#64748b"}}>{r.get("scenario", f"fan={r.get('fan_out', r.get('mid_count','?'))}")}</td>
                                    <td style={{"padding": "10px 14px", "fontFamily": "monospace", "color": "#7c3aed"}}>{r["local_latency_ms"]}</td>
                                    <td style={{"padding": "10px 14px", "fontFamily": "monospace", "color": "#0369a1"}}>{r["gt_latency_ms"]}</td>
                                    <td style={{"padding": "10px 14px", "fontFamily": "monospace", "color": "#065f46"}}>{r["am_latency_ms"]}</td>
                                    <td style={{"padding": "10px 14px", "color": "#64748b"}}>{r["nodes_loaded_local"]}</td>
                                    <td style={{"padding": "10px 14px", "color": "#64748b"}}>{r["nodes_loaded_gt"]}</td>
                                    <td style={{"padding": "10px 14px", "fontFamily": "monospace"}}>{r["speedup_gt"]}x</td>
                                    <td style={{"padding": "10px 14px", "fontFamily": "monospace"}}>{r["speedup_am"]}x</td>
                                    <td style={{"padding": "10px 14px"}}>
                                        <span style={{
                                            "padding": "3px 10px", "borderRadius": "12px",
                                            "fontWeight": "600", "fontSize": "12px",
                                            "background": ("#d1fae5" if r["winner"] == "am" else ("#dbeafe" if r["winner"] == "gt" else "#ede9fe")),
                                            "color": ("#065f46" if r["winner"] == "am" else ("#1e40af" if r["winner"] == "gt" else "#5b21b6"))
                                        }}>{r["winner"]}</span>
                                    </td>
                                </tr>
                                for (i, r) in enumerate(rows)
                            ]}
                        </tbody>
                    </table>
                </div>;
        }

        return
            <div style={{"fontFamily": "system-ui, -apple-system, sans-serif", "minHeight": "100vh", "background": "#f8fafc"}}>
                <div style={{"background": "#1e293b", "color": "#f1f5f9", "padding": "16px 32px"}}>
                    <h1 style={{"margin": "0", "fontSize": "1.2rem", "fontWeight": "700"}}>Graph Query Benchmark</h1>
                    <p style={{"margin": "4px 0 0 0", "fontSize": "13px", "color": "#94a3b8"}}>
                        Local walker traversal vs GT topology index vs AM in-memory matrix — four scenarios
                    </p>
                </div>

                <div style={{"background": "#fff", "borderBottom": "1px solid #e2e8f0", "paddingLeft": "32px", "display": "flex"}}>
                    <button style={tabStyle(activeTab == "singlehop")} onClick={lambda _: Any -> None { activeTab = "singlehop";}}>Single-hop</button>
                    <button style={tabStyle(activeTab == "inheritance")} onClick={lambda _: Any -> None { activeTab = "inheritance";}}>Inheritance</button>
                    <button style={tabStyle(activeTab == "multihop")} onClick={lambda _: Any -> None { activeTab = "multihop";}}>Multi-hop</button>
                    <button style={tabStyle(activeTab == "arbitrary")} onClick={lambda _: Any -> None { activeTab = "arbitrary";}}>Arbitrary Start</button>
                    <button
                        onClick={handleClear}
                        style={{"marginLeft": "auto", "marginRight": "16px", "padding": "8px 14px", "background": "#ef4444", "color": "#fff", "border": "none", "borderRadius": "6px", "cursor": "pointer", "fontSize": "13px", "alignSelf": "center"}}
                    >Clear All</button>
                </div>

                <div style={{"maxWidth": "1100px", "margin": "0 auto", "padding": "28px 24px"}}>

                    {(activeTab == "singlehop" and
                        <div>
                            <div style={{"background": "#fff", "border": "1px solid #e2e8f0", "borderRadius": "10px", "padding": "22px", "marginBottom": "24px"}}>
                                <h2 style={{"margin": "0 0 6px 0", "fontSize": "15px", "fontWeight": "700", "color": "#1e293b"}}>Single-hop</h2>
                                <p style={{"margin": "0 0 18px 0", "fontSize": "12px", "color": "#64748b"}}>
                                    root → [TargetNode | OtherNode].  Query: <code>[here--&gt;(?:TargetNode)]</code>
                                </p>
                                <div style={{"display": "flex", "gap": "24px", "flexWrap": "wrap", "alignItems": "flex-end"}}>
                                    <div>
                                        <label style={labelStyle}>Fan Out</label>
                                        <select value={fanOut} onChange={lambda e: Any -> None { fanOut = int(e.target.value);}} style={selectStyle}>
                                            <option value={5}>5 nodes</option>
                                            <option value={50}>50 nodes</option>
                                            <option value={200}>200 nodes</option>
                                            <option value={500}>500 nodes</option>
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
                                        <button onClick={handleSeed} disabled={seeding or loading} style={btnStyle("#0ea5e9")}>
                                            {("Seeding..." if seeding else "1. Seed")}
                                        </button>
                                        <button onClick={handleBenchmark} disabled={loading or seeding} style={btnStyle("#8b5cf6")}>
                                            {("Running..." if loading else "2. Benchmark")}
                                        </button>
                                        <button onClick={handleRunAll} disabled={loading or seeding or runningAll} style={btnStyle("#0d9488")}>
                                            {("Running all..." if runningAll else "3. Run All Scenarios")}
                                        </button>
                                    </div>
                                </div>
                                {(status and <p style={{"margin": "14px 0 0 0", "color": "#0f766e", "fontSize": "13px"}}>{status}</p>)}
                                {(error and <p style={{"margin": "14px 0 0 0", "color": "#dc2626", "fontSize": "13px"}}>Error: {error}</p>)}
                            </div>

                            {(len(results) > 0 and
                                <div style={{"background": "#fff", "border": "1px solid #e2e8f0", "borderRadius": "10px", "padding": "22px", "marginBottom": "24px"}}>
                                    <h2 style={{"margin": "0 0 18px 0", "fontSize": "15px", "fontWeight": "700"}}>Results</h2>
                                    {[
                                        <div key={i} style={{"marginBottom": "16px"}}>
                                            <div style={{"fontSize": "12px", "color": "#64748b", "marginBottom": "6px", "fontWeight": "600"}}>
                                                {f"fan={r['fan_out']} sel={int(r['selectivity']*100)}% iter={r['iterations']}"}
                                            </div>
                                            {barRow("Local", "#8b5cf6", r["local_latency_ms"], max(r["local_latency_ms"], r["gt_latency_ms"], r["am_latency_ms"]), "local")}
                                            {barRow("GT",    "#0ea5e9", r["gt_latency_ms"],    max(r["local_latency_ms"], r["gt_latency_ms"], r["am_latency_ms"]), "gt")}
                                            {barRow("AM",    "#10b981", r["am_latency_ms"],    max(r["local_latency_ms"], r["gt_latency_ms"], r["am_latency_ms"]), "am")}
                                        </div>
                                        for (i, r) in enumerate(results)
                                    ]}
                                    {resultsTable(results)}
                                </div>
                            )}

                            {(showHeatmap and
                                <div style={{"background": "#fff", "border": "1px solid #e2e8f0", "borderRadius": "10px", "padding": "22px"}}>
                                    <h2 style={{"margin": "0 0 6px 0", "fontSize": "15px", "fontWeight": "700"}}>Speedup Heatmap</h2>
                                    <p style={{"margin": "0 0 16px 0", "fontSize": "12px", "color": "#64748b"}}>GT / AM speedup vs local. Color = AM speedup magnitude.</p>
                                    <div style={{"overflowX": "auto"}}>
                                        <table style={{"borderCollapse": "collapse", "fontSize": "12px", "width": "100%"}}>
                                            <thead>
                                                <tr>
                                                    <th style={{"padding": "8px 12px", "background": "#f8fafc", "border": "1px solid #e2e8f0", "fontWeight": "700"}}>Selectivity</th>
                                                    {[
                                                        <th key={fo} style={{"padding": "8px 12px", "background": "#f8fafc", "border": "1px solid #e2e8f0", "fontWeight": "700", "textAlign": "center"}}>{f"fan={fo}"}</th>
                                                        for fo in [5, 50, 200, 500]
                                                    ]}
                                                </tr>
                                            </thead>
                                            <tbody>
                                                {[
                                                    <tr key={sel_pct}>
                                                        <td style={{"padding": "8px 12px", "border": "1px solid #e2e8f0", "fontWeight": "600"}}>{f"{sel_pct}% match"}</td>
                                                        {[
                                                            <td key={fo} style={{"padding": "8px 12px", "border": "1px solid #e2e8f0", "textAlign": "center",
                                                                "background": (
                                                                    "#14532d" if (heatmap.get(str(sel_pct), {}).get(str(fo), {}).get("speedup_am", 0) > 100) else
                                                                    ("#22c55e" if (heatmap.get(str(sel_pct), {}).get(str(fo), {}).get("speedup_am", 0) > 20) else
                                                                    ("#86efac" if (heatmap.get(str(sel_pct), {}).get(str(fo), {}).get("speedup_am", 0) > 5) else
                                                                    ("#fde68a" if (heatmap.get(str(sel_pct), {}).get(str(fo), {}).get("speedup_am", 0) > 2) else
                                                                    "#f8fafc"))))}}>
                                                                {(
                                                                    <div>
                                                                        <div style={{"fontWeight": "700", "color": "#0369a1"}}>{f"GT {heatmap[str(sel_pct)][str(fo)]['speedup_gt']}x"}</div>
                                                                        <div style={{"fontWeight": "700", "color": "#065f46"}}>{f"AM {heatmap[str(sel_pct)][str(fo)]['speedup_am']}x"}</div>
                                                                    </div>
                                                                    if (heatmap.get(str(sel_pct), {}).get(str(fo)))
                                                                    else <span style={{"color": "#94a3b8"}}>—</span>
                                                                )}
                                                            </td>
                                                            for fo in [5, 50, 200, 500]
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
                                <h2 style={{"margin": "0 0 6px 0", "fontSize": "15px", "fontWeight": "700", "color": "#1e293b"}}>Inheritance</h2>
                                <p style={{"margin": "0 0 18px 0", "fontSize": "12px", "color": "#64748b"}}>
                                    root → [PostNode | CommentNode | OtherNode].  Query: <code>[here--&gt;(?:BaseContent)]</code> returns PostNode + CommentNode via MRO fan-out indexing.
                                    GT/AM pre-index each subclass node under all ancestor type buckets at write time.
                                </p>
                                <div style={{"display": "flex", "gap": "24px", "flexWrap": "wrap", "alignItems": "flex-end"}}>
                                    <div>
                                        <label style={labelStyle}>Fan Out (total nodes)</label>
                                        <select value={inheritFanOut} onChange={lambda e: Any -> None { inheritFanOut = int(e.target.value);}} style={selectStyle}>
                                            <option value={10}>10 nodes</option>
                                            <option value={50}>50 nodes</option>
                                            <option value={200}>200 nodes</option>
                                            <option value={500}>500 nodes</option>
                                        </select>
                                    </div>
                                    <div>
                                        <label style={labelStyle}>BaseContent fraction</label>
                                        <select value={inheritSelectivity} onChange={lambda e: Any -> None { inheritSelectivity = float(e.target.value);}} style={selectStyle}>
                                            <option value={0.2}>20% (PostNode+CommentNode)</option>
                                            <option value={0.4}>40%</option>
                                            <option value={0.6}>60%</option>
                                            <option value={0.8}>80%</option>
                                        </select>
                                    </div>
                                    <div>
                                        <label style={labelStyle}>Iterations</label>
                                        <select value={inheritIters} onChange={lambda e: Any -> None { inheritIters = int(e.target.value);}} style={selectStyle}>
                                            <option value={1}>1</option>
                                            <option value={5}>5</option>
                                            <option value={10}>10</option>
                                        </select>
                                    </div>
                                    <div style={{"display": "flex", "gap": "8px"}}>
                                        <button onClick={handleSeedInheritance} disabled={inheritSeeding or inheritBenching} style={btnStyle("#0ea5e9")}>
                                            {("Seeding..." if inheritSeeding else "1. Seed")}
                                        </button>
                                        <button onClick={handleBenchInheritance} disabled={inheritBenching or inheritSeeding} style={btnStyle("#8b5cf6")}>
                                            {("Running..." if inheritBenching else "2. Benchmark")}
                                        </button>
                                    </div>
                                </div>
                                {(inheritStatus and <p style={{"margin": "14px 0 0 0", "color": "#0f766e", "fontSize": "13px"}}>{inheritStatus}</p>)}
                                {(inheritError and <p style={{"margin": "14px 0 0 0", "color": "#dc2626", "fontSize": "13px"}}>Error: {inheritError}</p>)}
                                <div style={{"marginTop": "14px", "padding": "12px", "background": "#f8fafc", "borderRadius": "6px", "fontSize": "12px", "color": "#64748b", "lineHeight": "1.6"}}>
                                    <strong>Local:</strong> loads all {inheritFanOut} neighbors, filters by isinstance(node, BaseContent) — touches OtherNode too.
                                    &nbsp;&nbsp;
                                    <strong>GT/AM:</strong> looks up "BaseContent" bucket = PostNode + CommentNode IDs (pre-resolved at write via MRO) → fetches only {int(inheritFanOut * inheritSelectivity)} nodes.
                                </div>
                            </div>
                            {(len(inheritResults) > 0 and
                                <div style={{"background": "#fff", "border": "1px solid #e2e8f0", "borderRadius": "10px", "padding": "22px"}}>
                                    <h2 style={{"margin": "0 0 18px 0", "fontSize": "15px", "fontWeight": "700"}}>Results</h2>
                                    {[
                                        <div key={i} style={{"marginBottom": "16px"}}>
                                            <div style={{"fontSize": "12px", "color": "#64748b", "marginBottom": "6px", "fontWeight": "600"}}>
                                                {f"fan={r['fan_out']} BaseContent={int(r['selectivity']*100)}% iter={r['iterations']}"}
                                            </div>
                                            {barRow("Local", "#8b5cf6", r["local_latency_ms"], max(r["local_latency_ms"], r["gt_latency_ms"], r["am_latency_ms"]), "local")}
                                            {barRow("GT",    "#0ea5e9", r["gt_latency_ms"],    max(r["local_latency_ms"], r["gt_latency_ms"], r["am_latency_ms"]), "gt")}
                                            {barRow("AM",    "#10b981", r["am_latency_ms"],    max(r["local_latency_ms"], r["gt_latency_ms"], r["am_latency_ms"]), "am")}
                                        </div>
                                        for (i, r) in enumerate(inheritResults)
                                    ]}
                                    {resultsTable(inheritResults)}
                                </div>
                            )}
                        </div>
                    )}

                    {(activeTab == "multihop" and
                        <div>
                            <div style={{"background": "#fff", "border": "1px solid #e2e8f0", "borderRadius": "10px", "padding": "22px", "marginBottom": "24px"}}>
                                <h2 style={{"margin": "0 0 6px 0", "fontSize": "15px", "fontWeight": "700", "color": "#1e293b"}}>Multi-hop (2-hop)</h2>
                                <p style={{"margin": "0 0 18px 0", "fontSize": "12px", "color": "#64748b"}}>
                                    root → MidNode[i] → [TargetNode | OtherNode].  Query: find all TargetNodes reachable from root in 2 hops.
                                    Local cost: mid_count + mid_count × branch_factor fetches.
                                    GT/AM cost: 2 index lookups + (mid_count × selectivity × branch_factor) fetches.
                                </p>
                                <div style={{"display": "flex", "gap": "24px", "flexWrap": "wrap", "alignItems": "flex-end"}}>
                                    <div>
                                        <label style={labelStyle}>Mid Count</label>
                                        <select value={midCount} onChange={lambda e: Any -> None { midCount = int(e.target.value);}} style={selectStyle}>
                                            <option value={5}>5</option>
                                            <option value={10}>10</option>
                                            <option value={20}>20</option>
                                            <option value={50}>50</option>
                                        </select>
                                    </div>
                                    <div>
                                        <label style={labelStyle}>Branch Factor (children/mid)</label>
                                        <select value={branchFactor} onChange={lambda e: Any -> None { branchFactor = int(e.target.value);}} style={selectStyle}>
                                            <option value={5}>5</option>
                                            <option value={10}>10</option>
                                            <option value={20}>20</option>
                                            <option value={50}>50</option>
                                        </select>
                                    </div>
                                    <div>
                                        <label style={labelStyle}>Selectivity (TargetNode %)</label>
                                        <select value={multihopSel} onChange={lambda e: Any -> None { multihopSel = float(e.target.value);}} style={selectStyle}>
                                            <option value={0.1}>10%</option>
                                            <option value={0.3}>30%</option>
                                            <option value={0.5}>50%</option>
                                            <option value={0.8}>80%</option>
                                        </select>
                                    </div>
                                    <div>
                                        <label style={labelStyle}>Iterations</label>
                                        <select value={multihopIters} onChange={lambda e: Any -> None { multihopIters = int(e.target.value);}} style={selectStyle}>
                                            <option value={1}>1</option>
                                            <option value={5}>5</option>
                                            <option value={10}>10</option>
                                        </select>
                                    </div>
                                    <div style={{"display": "flex", "gap": "8px"}}>
                                        <button onClick={handleSeedMultihop} disabled={multihopSeeding or multihopBenching} style={btnStyle("#0ea5e9")}>
                                            {("Seeding..." if multihopSeeding else "1. Seed")}
                                        </button>
                                        <button onClick={handleBenchMultihop} disabled={multihopBenching or multihopSeeding} style={btnStyle("#8b5cf6")}>
                                            {("Running..." if multihopBenching else "2. Benchmark")}
                                        </button>
                                    </div>
                                </div>
                                {(multihopStatus and <p style={{"margin": "14px 0 0 0", "color": "#0f766e", "fontSize": "13px"}}>{multihopStatus}</p>)}
                                {(multihopError and <p style={{"margin": "14px 0 0 0", "color": "#dc2626", "fontSize": "13px"}}>Error: {multihopError}</p>)}
                                <div style={{"marginTop": "14px", "padding": "12px", "background": "#f8fafc", "borderRadius": "6px", "fontSize": "12px", "color": "#64748b", "lineHeight": "1.6"}}>
                                    <strong>Local:</strong> hop1 loads {midCount} MidNodes; hop2 iterates each mid's edges → fetches all {midCount * branchFactor} children → filters.
                                    &nbsp;&nbsp;
                                    <strong>GT/AM:</strong> 2 sequential index dict lookups → bulk-fetch only {int(midCount * branchFactor * multihopSel)} TargetNodes.
                                </div>
                            </div>
                            {(len(multihopResults) > 0 and
                                <div style={{"background": "#fff", "border": "1px solid #e2e8f0", "borderRadius": "10px", "padding": "22px"}}>
                                    <h2 style={{"margin": "0 0 18px 0", "fontSize": "15px", "fontWeight": "700"}}>Results</h2>
                                    {[
                                        <div key={i} style={{"marginBottom": "16px"}}>
                                            <div style={{"fontSize": "12px", "color": "#64748b", "marginBottom": "6px", "fontWeight": "600"}}>
                                                {f"mids={r['mid_count']} branch={r['branch_factor']} sel={int(r['selectivity']*100)}% iter={r['iterations']}"}
                                            </div>
                                            {barRow("Local", "#8b5cf6", r["local_latency_ms"], max(r["local_latency_ms"], r["gt_latency_ms"], r["am_latency_ms"]), "local")}
                                            {barRow("GT",    "#0ea5e9", r["gt_latency_ms"],    max(r["local_latency_ms"], r["gt_latency_ms"], r["am_latency_ms"]), "gt")}
                                            {barRow("AM",    "#10b981", r["am_latency_ms"],    max(r["local_latency_ms"], r["gt_latency_ms"], r["am_latency_ms"]), "am")}
                                        </div>
                                        for (i, r) in enumerate(multihopResults)
                                    ]}
                                    {resultsTable(multihopResults)}
                                </div>
                            )}
                        </div>
                    )}

                    {(activeTab == "arbitrary" and
                        <div>
                            <div style={{"background": "#fff", "border": "1px solid #e2e8f0", "borderRadius": "10px", "padding": "22px", "marginBottom": "24px"}}>
                                <h2 style={{"margin": "0 0 6px 0", "fontSize": "15px", "fontWeight": "700", "color": "#1e293b"}}>Arbitrary Start Node</h2>
                                <p style={{"margin": "0 0 18px 0", "fontSize": "12px", "color": "#64748b"}}>
                                    Traversal starting from a non-root node (the first MidNode in the multi-hop graph).
                                    Requires the multi-hop graph to be seeded first.
                                    Demonstrates that GT and AM indexes are source-agnostic: any node ID can be the lookup key.
                                </p>
                                <div style={{"padding": "12px", "background": "#fef3c7", "borderRadius": "6px", "fontSize": "12px", "color": "#92400e", "marginBottom": "16px"}}>
                                    Prerequisite: seed the multi-hop graph from the Multi-hop tab first.
                                </div>
                                <div style={{"display": "flex", "gap": "24px", "flexWrap": "wrap", "alignItems": "flex-end"}}>
                                    <div>
                                        <label style={labelStyle}>Iterations</label>
                                        <select value={arbIters} onChange={lambda e: Any -> None { arbIters = int(e.target.value);}} style={selectStyle}>
                                            <option value={1}>1</option>
                                            <option value={5}>5</option>
                                            <option value={10}>10</option>
                                        </select>
                                    </div>
                                    <button onClick={handleBenchArbitrary} disabled={arbBenching} style={btnStyle("#8b5cf6")}>
                                        {("Running..." if arbBenching else "Run Benchmark")}
                                    </button>
                                </div>
                                {(arbStatus and <p style={{"margin": "14px 0 0 0", "color": "#0f766e", "fontSize": "13px"}}>{arbStatus}</p>)}
                                {(arbError and <p style={{"margin": "14px 0 0 0", "color": "#dc2626", "fontSize": "13px"}}>Error: {arbError}</p>)}
                                <div style={{"marginTop": "14px", "padding": "12px", "background": "#f8fafc", "borderRadius": "6px", "fontSize": "12px", "color": "#64748b", "lineHeight": "1.6"}}>
                                    <strong>Local:</strong> fetch MidNode anchor from SQLite, iterate ALL its outgoing edges, load each child, filter by TargetNode type.
                                    &nbsp;&nbsp;
                                    <strong>GT:</strong> <code>gt_index[mid_id]["TargetNode"]</code> — lookup by non-root node ID.
                                    &nbsp;&nbsp;
                                    <strong>AM:</strong> <code>am_index[mid_id]["TargetNode"]</code> — same, zero I/O.
                                </div>
                            </div>
                            {(len(arbResults) > 0 and
                                <div style={{"background": "#fff", "border": "1px solid #e2e8f0", "borderRadius": "10px", "padding": "22px"}}>
                                    <h2 style={{"margin": "0 0 18px 0", "fontSize": "15px", "fontWeight": "700"}}>Results</h2>
                                    {[
                                        <div key={i} style={{"marginBottom": "16px"}}>
                                            <div style={{"fontSize": "12px", "color": "#64748b", "marginBottom": "6px", "fontWeight": "600"}}>
                                                {f"start={r.get('start_node','?')[:8]}… iter={r['iterations']}"}
                                            </div>
                                            {barRow("Local", "#8b5cf6", r["local_latency_ms"], max(r["local_latency_ms"], r["gt_latency_ms"], r["am_latency_ms"]), "local")}
                                            {barRow("GT",    "#0ea5e9", r["gt_latency_ms"],    max(r["local_latency_ms"], r["gt_latency_ms"], r["am_latency_ms"]), "gt")}
                                            {barRow("AM",    "#10b981", r["am_latency_ms"],    max(r["local_latency_ms"], r["gt_latency_ms"], r["am_latency_ms"]), "am")}
                                        </div>
                                        for (i, r) in enumerate(arbResults)
                                    ]}
                                    {resultsTable(arbResults)}
                                </div>
                            )}
                        </div>
                    )}

                </div>
            </div>;
    }
}
