"""Graph Topology Index Benchmark (GTI + SAM layers).

Measures wall-clock traversal time WITH vs WITHOUT the SAM+GTI optimization
across five scenarios:

  Scenario 1 — Node-type filter        [-->(?:TargetNode)]
               Various fan-out x selectivity combinations.

  Scenario 2 — Inheritance query       [-->(?:BaseContent)]
               PostNode and CommentNode are subclasses of BaseContent.
               MRO fan-out indexes both concrete and parent types.

  Scenario 3 — Wildcard traversal      [-->]
               No type filter — index must NOT activate (zero overhead).

  Scenario 4 — Edge-type filter        [-[FollowEdge]->]
               Index activated via "e:FollowEdge" SAM column.

  Scenario 5 — Combined filter         [-[FollowEdge]->(?:PostNode)]
               SAM intersection of "n:PostNode" and "e:FollowEdge" columns.

Methodology
-----------
* Graph is built ONCE in a fresh SQLite-backed context, then that context
  is closed.  Each timed iteration re-opens the same DB from scratch so
  TieredMemory L1 cache is empty on every iteration (cold start).
* sam_clear() is called before every timed iteration — all traversals start
  as SAM misses, paying the GTI SQL query cost (worst-case cold start).
* N_ITERS iterations per cell; first discarded as JIT / SQLite warm-up.

Anchor stub fetch model
-----------------------
NodeAnchor pickles store edges as STUB EdgeAnchors (only .id).
Accessing any field on a stub triggers __getattr__ -> populate() -> SQLite.
Per edge, the local path pays THREE fetches:
  1. anchor.source  -> populate(EdgeAnchor stub)  -> loads source+target stubs
  2. source.archetype -> populate(source NodeAnchor stub)
  3. target.archetype -> populate(target NodeAnchor stub)

Local path total: ~3 x fan_out SQLite round-trips.
Index path total:  1 SQL SELECT  +  selectivity x fan_out NodeAnchor fetches.

Speedup formula: ~3 / selectivity  (at large fan, SQL overhead negligible).

Run with:
  python -m jaclang jac/examples/graph_index_bench/bench_gt_am.jac
"""

import os;
import time;
import from tempfile { mkdtemp }
import from jaclang { JacRuntime as Jac }
import from jaclang.jac0core.runtime { without_plugins }
import from jaclang.runtimelib.sam_gti { sam_clear }

# ── configuration ─────────────────────────────────────────────────────────────

glob N_ITERS: int = 6;   # timed iterations per cell (first discarded as warm-up)

# ── node/edge types (module-level — required for OSP walker traversal) ────────

node TargetNode  { has val: int = 0; }
node OtherNode   { has val: int = 0; }
node BaseContent { has val: int = 0; }
node PostNode(BaseContent)    { has val: int = 0; }
node CommentNode(BaseContent) { has val: int = 0; }

edge FollowEdge {}
edge LikeEdge   {}

# ── graph-building walkers ────────────────────────────────────────────────────

walker BuildFlat {
    has n_targets: int;
    has n_others:  int;

    can build with Root entry {
        for i in range(self.n_targets) { here ++> TargetNode(val=i); }
        for i in range(self.n_others)  { here ++> OtherNode(val=i);  }
    }
}

walker BuildHierarchy {
    has n_post:    int;
    has n_comment: int;
    has n_other:   int;

    can build with Root entry {
        for i in range(self.n_post)    { here ++> PostNode(val=i);    }
        for i in range(self.n_comment) { here ++> CommentNode(val=i); }
        for i in range(self.n_other)   { here ++> OtherNode(val=i);   }
    }
}

walker BuildEdgeTyped {
    has n_follow_post:    int;
    has n_follow_other:   int;
    has n_like_post:      int;

    can build with Root entry {
        for i in range(self.n_follow_post)  { here +>: FollowEdge() :+> PostNode(val=i);  }
        for i in range(self.n_follow_other) { here +>: FollowEdge() :+> OtherNode(val=i); }
        for i in range(self.n_like_post)    { here +>: LikeEdge()   :+> PostNode(val=i);  }
    }
}

# ── query walkers ─────────────────────────────────────────────────────────────

walker QueryTargets {
    has results: list = [];
    can query with Root entry { self.results = [-->(?:TargetNode)]; }
}

walker QueryBaseContent {
    has results: list = [];
    can query with Root entry { self.results = [-->(?:BaseContent)]; }
}

walker QueryAll {
    has results: list = [];
    can query with Root entry { self.results = [-->]; }
}

walker QueryFollowEdge {
    has results: list = [];
    can query with Root entry { self.results = [->:FollowEdge:->]; }
}

walker QueryFollowEdgePostNode {
    has results: list = [];
    can query with Root entry { self.results = [->:FollowEdge:-> (?:PostNode)]; }
}

# ── context helpers ───────────────────────────────────────────────────────────

def fresh_ctx(tmp: str) -> object {
    Jac.set_base_path(tmp);
    Jac.exec_ctx = None;
    ctx = Jac.create_j_context(None);
    Jac.set_context(ctx);
    return ctx;
}

def close_ctx(ctx: object) -> None {
    ctx.close();
    Jac.exec_ctx = None;
}

# ── graph builders ────────────────────────────────────────────────────────────

def build_flat(n_targets: int, n_others: int) -> str {
    tmp = mkdtemp();
    _orig_base = Jac.base_path_dir;
    _orig_ctx  = Jac.exec_ctx;
    with without_plugins() {
        ctx = fresh_ctx(tmp);
        try { root spawn BuildFlat(n_targets=n_targets, n_others=n_others); }
        finally { close_ctx(ctx); }
    }
    Jac.set_base_path(_orig_base);
    Jac.exec_ctx = _orig_ctx;
    return tmp;
}

def build_hierarchy(n_post: int, n_comment: int, n_other: int) -> str {
    tmp = mkdtemp();
    _orig_base = Jac.base_path_dir;
    _orig_ctx  = Jac.exec_ctx;
    with without_plugins() {
        ctx = fresh_ctx(tmp);
        try { root spawn BuildHierarchy(n_post=n_post, n_comment=n_comment, n_other=n_other); }
        finally { close_ctx(ctx); }
    }
    Jac.set_base_path(_orig_base);
    Jac.exec_ctx = _orig_ctx;
    return tmp;
}

def build_edge_typed(n_follow_post: int, n_follow_other: int, n_like_post: int) -> str {
    tmp = mkdtemp();
    _orig_base = Jac.base_path_dir;
    _orig_ctx  = Jac.exec_ctx;
    with without_plugins() {
        ctx = fresh_ctx(tmp);
        try {
            root spawn BuildEdgeTyped(
                n_follow_post=n_follow_post,
                n_follow_other=n_follow_other,
                n_like_post=n_like_post
            );
        }
        finally { close_ctx(ctx); }
    }
    Jac.set_base_path(_orig_base);
    Jac.exec_ctx = _orig_ctx;
    return tmp;
}

# ── timing runner ─────────────────────────────────────────────────────────────

def run_timed(
    tmp_dir:     str,
    enabled:     bool,
    walker_kind: str
) -> tuple[float, int] {
    os.environ["JAC_INDEX_ENABLED"] = "true" if enabled else "false";
    _orig_base = Jac.base_path_dir;
    _orig_ctx  = Jac.exec_ctx;
    times: list[float] = [];
    result_count = 0;

    with without_plugins() {
        for _ in range(N_ITERS) {
            sam_clear();
            ctx = fresh_ctx(tmp_dir);
            try {
                t0 = time.perf_counter();
                if walker_kind == "target" {
                    w = root spawn QueryTargets();
                    result_count = len(w.results);
                } elif walker_kind == "base_content" {
                    w = root spawn QueryBaseContent();
                    result_count = len(w.results);
                } elif walker_kind == "follow_edge" {
                    w = root spawn QueryFollowEdge();
                    result_count = len(w.results);
                } elif walker_kind == "follow_post" {
                    w = root spawn QueryFollowEdgePostNode();
                    result_count = len(w.results);
                } else {
                    w = root spawn QueryAll();
                    result_count = len(w.results);
                }
                t1 = time.perf_counter();
                times.append((t1 - t0) * 1000.0);
            } finally {
                close_ctx(ctx);
            }
        }
    }

    os.environ["JAC_INDEX_ENABLED"] = "true";
    Jac.set_base_path(_orig_base);
    Jac.exec_ctx = _orig_ctx;

    valid = times[1:] if len(times) > 1 else times;
    return (sum(valid) / len(valid), result_count);
}

# ── reporting helpers ─────────────────────────────────────────────────────────

def section(title: str) -> None {
    print(f"\n{'═' * 72}");
    print(f"  {title}");
    print(f"{'═' * 72}");
}

def col_header -> None {
    print(f"  {'fan':>6}  {'sel':>5}  {'matches':>8}  "
          f"{'index(ms)':>10}  {'local(ms)':>10}  {'speedup':>8}  saved");
    print(f"  {'-'*6}  {'-'*5}  {'-'*8}  {'-'*10}  {'-'*10}  {'-'*8}  {'-'*15}");
}

def data_row(fan: int, sel_pct: int, matches: int, idx_ms: float, loc_ms: float) -> None {
    speedup = loc_ms / idx_ms if idx_ms > 0 else 0.0;
    saved   = fan - matches;
    bar     = "█" * min(int(speedup * 2), 36);
    print(f"  fan={fan:>4}  sel={sel_pct:>3}%  matches={matches:>4}  "
          f"index={idx_ms:>7.3f}ms  local={loc_ms:>7.3f}ms  "
          f"speedup={speedup:>5.1f}x  {saved}/{fan}  {bar}");
}

def wildcard_row(fan: int, idx_ms: float, loc_ms: float) -> None {
    ratio = idx_ms / loc_ms if loc_ms > 0 else 1.0;
    flag  = "OK (zero overhead)" if ratio < 1.15 else "WARNING: unexpected overhead";
    print(f"  fan={fan:>4}  [wildcard]  "
          f"index={idx_ms:>7.3f}ms  local={loc_ms:>7.3f}ms  "
          f"ratio={ratio:>5.3f}x  {flag}");
}

# ── main benchmark ────────────────────────────────────────────────────────────

with entry {
    print("\n");
    print("╔══════════════════════════════════════════════════════════════════╗");
    print("║   Graph Topology Index (GTI + SAM) — Performance Benchmark      ║");
    print("║   Cold-L1 traversal: fresh SQLite context per iteration         ║");
    print(f"║   {N_ITERS} iterations per cell (first discarded as warm-up)           ║");
    print("╚══════════════════════════════════════════════════════════════════╝");

    # ── Scenario 1: node-type filter ──────────────────────────────────────────
    section("Scenario 1 — [-->(?:TargetNode)]  (node-type filter, flat star graph)");
    col_header();

    s1: list[tuple[int, int, int]] = [
        (50,   5,  45),
        (50,  25,  25),
        (50,  45,   5),
        (200, 20, 180),
        (200,100, 100),
        (500, 50, 450),
        (500,250, 250),
    ];

    for (fan, n_t, n_o) in s1 {
        tmp = build_flat(n_targets=n_t, n_others=n_o);
        (idx_ms, n_idx) = run_timed(tmp, True,  "target");
        (loc_ms, n_loc) = run_timed(tmp, False, "target");
        data_row(fan, int(n_t * 100 / fan), n_idx, idx_ms, loc_ms);
    }

    # ── Scenario 2: inheritance / MRO query ───────────────────────────────────
    section("Scenario 2 — [-->(?:BaseContent)]  (MRO fan-out: PostNode + CommentNode)");
    col_header();

    s2: list[tuple[int, int, int, int]] = [
        (5,   5,  40, 50),
        (25, 25,   0, 50),
        (20, 20, 160,200),
        (50, 50, 400,500),
    ];

    for (n_post, n_comment, n_other, fan) in s2 {
        tmp = build_hierarchy(n_post=n_post, n_comment=n_comment, n_other=n_other);
        (idx_ms, n_idx) = run_timed(tmp, True,  "base_content");
        (loc_ms, n_loc) = run_timed(tmp, False, "base_content");
        matches = n_post + n_comment;
        data_row(fan, int(matches * 100 / fan), n_idx, idx_ms, loc_ms);
    }

    # ── Scenario 3: wildcard — index must stay silent ─────────────────────────
    section("Scenario 3 — [-->]  wildcard (no filter — index BYPASSED)");
    print(f"  {'fan':>6}  {'kind':>10}  {'index(ms)':>10}  {'local(ms)':>10}  {'ratio':>8}  note");
    print(f"  {'-'*6}  {'-'*10}  {'-'*10}  {'-'*10}  {'-'*8}  {'-'*25}");

    for fan in [50, 200, 500] {
        tmp = build_flat(n_targets=0, n_others=fan);
        (idx_ms, _) = run_timed(tmp, True,  "wildcard");
        (loc_ms, _) = run_timed(tmp, False, "wildcard");
        wildcard_row(fan, idx_ms, loc_ms);
    }

    # ── Scenario 4: edge-type filter ──────────────────────────────────────────
    section("Scenario 4 — [-[FollowEdge]->]  (edge-type filter, SAM e: column)");
    col_header();

    # Graph: FollowEdge -> PostNode (matches) + FollowEdge -> OtherNode (matches)
    #        LikeEdge   -> PostNode (non-matching edge type)
    # sel = n_follow / (n_follow_post + n_follow_other + n_like_post)
    s4: list[tuple[int, int, int]] = [
        (25,  25,  50),   # fan=100, sel=50%
        (25, 175,  50),   # fan=250, sel=80%  (mostly FollowEdge)
        (50,  50, 400),   # fan=500, sel=20%
        (50, 200, 250),   # fan=500, sel=50%
    ];

    for (n_fp, n_fo, n_lp) in s4 {
        fan = n_fp + n_fo + n_lp;
        matches_follow = n_fp + n_fo;
        tmp = build_edge_typed(n_follow_post=n_fp, n_follow_other=n_fo, n_like_post=n_lp);
        (idx_ms, n_idx) = run_timed(tmp, True,  "follow_edge");
        (loc_ms, n_loc) = run_timed(tmp, False, "follow_edge");
        data_row(fan, int(matches_follow * 100 / fan), n_idx, idx_ms, loc_ms);
    }

    # ── Scenario 5: combined filter ───────────────────────────────────────────
    section("Scenario 5 — [-[FollowEdge]->(?:PostNode)]  (SAM intersection)");
    col_header();

    # Matches: only FollowEdge edges pointing to PostNode
    # Non-matches: FollowEdge->OtherNode + LikeEdge->PostNode
    s5: list[tuple[int, int, int]] = [
        (25,  25,  50),   # fan=100, matches=25, sel=25%
        (50,  50, 400),   # fan=500, matches=50, sel=10%
        (50, 200, 250),   # fan=500, matches=50, sel=10%  (more non-FollowEdge)
        (100, 50, 350),   # fan=500, matches=100, sel=20%
    ];

    for (n_fp, n_fo, n_lp) in s5 {
        fan = n_fp + n_fo + n_lp;
        matches_combined = n_fp;  # FollowEdge AND PostNode
        tmp = build_edge_typed(n_follow_post=n_fp, n_follow_other=n_fo, n_like_post=n_lp);
        (idx_ms, n_idx) = run_timed(tmp, True,  "follow_post");
        (loc_ms, n_loc) = run_timed(tmp, False, "follow_post");
        data_row(fan, int(matches_combined * 100 / fan), n_idx, idx_ms, loc_ms);
    }

    # ── legend ────────────────────────────────────────────────────────────────
    print(f"\n{'─' * 72}");
    print("  Legend");
    print(f"{'─' * 72}");
    print("  index path : JAC_INDEX_ENABLED=true  (SAM dict + GTI SQL SELECT)");
    print("  local path : JAC_INDEX_ENABLED=false (full edge-list loop)");
    print("  SAM columns: \"n:TypeName\" (node type, MRO fan-out)");
    print("               \"e:TypeName\" (edge type, direct only)");
    print("  Combined   : intersect(sam[src][\"n:X\"], sam[src][\"e:Y\"])");
    print("  Each iteration: fresh ExecutionContext opened on same SQLite file");
    print("  (TieredMemory L1 starts empty — all fetches go to SQLite).");
    print("  sam_clear() before each iteration → SAM miss on every traversal.");
    print("  Local cost = ~3 x fan SQLite fetches (edge stub + 2 node stubs).");
    print("  Index cost =  1 SQL SELECT + matches x NodeAnchor fetch.");
    print(f"{'─' * 72}\n");
}
