#!/usr/bin/env python3
"""Pre-flight verifier for the graph-visualization demo.

Compiles graphs + algorithms, drives every <algo>_start/<algo>_step pair
through sim/sim.py (re-entering the step function until $graph_done flips,
since the sim models `schedule` as a no-op), and asserts the results
against Python reference implementations that share the layout tables in
tools/gen_graph_viz.py:

    cat scripts/demos/graph_world.mcaml scripts/demos/graph_algos.mcaml | ./mcaml -o build_graph
    python3 tools/sim_check_graph.py build_graph

The references MUST mirror the MCaml scan order exactly: edges in
ascending index order, BFS marks at enqueue, min-scans take the first
minimum.
"""
import sys
import os

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "sim"))
sys.path.insert(0, os.path.join(REPO, "tools"))
import sim  # noqa: E402
from gen_graph_viz import (  # noqa: E402
    NODES_A, EDGES_A, NODES_B, EDGES_B, NODE_BLOCKS, EDGE_BLOCKS,
    FLOW_SOURCE, FLOW_SINK, pad_fill,
)

N_A = len(NODES_A)
N_B = len(NODES_B)
INF = 999999

_results = []


def check(name, got, want):
    ok = got == want
    _results.append(ok)
    if ok:
        print(f"OK: {name}")
    else:
        print(f"FAIL: {name}: got={got!r} want={want!r}")
    return ok


def heap(w, name):
    return w.storage["mcaml:heap"]["__g_" + name]


def neighbors(u):
    """(edge index, other endpoint) pairs for graph A, ascending edge order."""
    out = []
    for j, (a, b, _) in enumerate(EDGES_A):
        if a == u:
            out.append((j, b))
        elif b == u:
            out.append((j, a))
    return out


# ------------------------------------------------------------ references


def ref_bfs():
    order, depth = [], [0] * N_A
    seen = [False] * N_A
    seen[0] = True
    q = [0]
    while q:
        u = q.pop(0)
        order.append(u)
        for _, v in neighbors(u):
            if not seen[v]:
                seen[v] = True
                depth[v] = depth[u] + 1
                q.append(v)
    return order, depth


def ref_dfs():
    order = []
    seen = [False] * N_A
    stack = [0]
    while stack:
        u = stack.pop()
        if seen[u]:
            continue
        seen[u] = True
        order.append(u)
        for _, v in neighbors(u):
            if not seen[v]:
                stack.append(v)
    return order


def ref_dijkstra():
    dist = [INF] * N_A
    dist[0] = 0
    done = [False] * N_A
    order = []
    while True:
        u, bestd = None, INF
        for i in range(N_A):
            if not done[i] and dist[i] < bestd:  # first minimum
                bestd, u = dist[i], i
        if u is None:
            return order, dist
        done[u] = True
        order.append(u)
        for j, v in neighbors(u):
            if not done[v] and dist[u] + EDGES_A[j][2] < dist[v]:
                dist[v] = dist[u] + EDGES_A[j][2]


def ref_kruskal():
    order = sorted(range(len(EDGES_A)), key=lambda j: EDGES_A[j][2])
    dsu = list(range(N_A))

    def find(x):
        while dsu[x] != x:
            x = dsu[x]
        return x

    accepted, rejected = [], []
    for e in order:
        if len(accepted) == N_A - 1:
            break
        ru, rv = find(EDGES_A[e][0]), find(EDGES_A[e][1])
        if ru == rv:
            rejected.append(e)
        else:
            dsu[ru] = rv
            accepted.append(e)
    return accepted, rejected, sum(EDGES_A[e][2] for e in accepted)


def ref_maxflow():
    """Edmonds-Karp mirroring the MCaml scan: residual BFS with
    v = 0..N_B-1 ascending, skew-symmetric flow matrix."""
    cap = [[0] * N_B for _ in range(N_B)]
    for u, v, c in EDGES_B:
        cap[u][v] = c
    flw = [[0] * N_B for _ in range(N_B)]
    bottlenecks = []
    while True:
        par = [None] * N_B
        seen = [False] * N_B
        seen[FLOW_SOURCE] = True
        q = [FLOW_SOURCE]
        while q:
            u = q.pop(0)
            for v in range(N_B):
                if not seen[v] and cap[u][v] - flw[u][v] > 0:
                    seen[v] = True
                    par[v] = u
                    q.append(v)
        if not seen[FLOW_SINK]:
            reachable = {i for i in range(N_B) if seen[i]}
            cut = [j for j, (u, v, _) in enumerate(EDGES_B)
                   if u in reachable and v not in reachable]
            return sum(bottlenecks), bottlenecks, reachable, cut
        b, v = INF, FLOW_SINK
        while v != FLOW_SOURCE:
            u = par[v]
            b = min(b, cap[u][v] - flw[u][v])
            v = u
        v = FLOW_SINK
        while v != FLOW_SOURCE:
            u = par[v]
            flw[u][v] += b
            flw[v][u] -= b
            v = u
        bottlenecks.append(b)


def ref_prim():
    best = [INF] * N_A
    best[0] = 0
    pare = [None] * N_A
    done = [False] * N_A
    accepted = []
    while True:
        u, bestw = None, INF
        for i in range(N_A):
            if not done[i] and best[i] < bestw:  # first minimum
                bestw, u = best[i], i
        if u is None:
            return accepted, sum(EDGES_A[e][2] for e in accepted)
        done[u] = True
        if pare[u] is not None:
            accepted.append(pare[u])
        for j, v in neighbors(u):
            if not done[v] and EDGES_A[j][2] < best[v]:
                best[v] = EDGES_A[j][2]
                pare[v] = j


# ---------------------------------------------------------------- driver


def run_algo(start, step, cap=500):
    w = sim.World()
    sim.run_function(w, "__globals_init")
    sim.run_function(w, "graph_spawn")
    w.viz.clear()  # keep per-algorithm viz assertions clean of spawn noise
    sim.run_function(w, start)
    ticks = 0
    while w.scores.get("$graph_done", 0) != 1:
        ticks += 1
        assert ticks <= cap, f"{start}: never finished in {cap} steps"
        sim.run_function(w, step)
    return w, ticks


def last_pad_fill(w, node):
    """Last recolor command touching a graph-A node pad, or None."""
    prefix = pad_fill(NODES_A[node], "").rsplit(" ", 1)[0]
    hits = [c for c in w.viz if c.startswith(prefix + " ")]
    return hits[-1] if hits else None


def check_visited_lime(tag, w, nodes):
    bad = []
    for i in nodes:
        cmd = last_pad_fill(w, i)
        if cmd is None or not cmd.endswith("minecraft:" + NODE_BLOCKS[3]):
            bad.append((i, cmd))
    check(f"{tag}: every visited node pad ends lime", bad, [])


# ------------------------------------------------------------ algorithms


def check_spawn():
    w = sim.World()
    sim.run_function(w, "__globals_init")
    sim.run_function(w, "graph_spawn")
    check("spawn: first command kills stale labels",
          w.viz[0].startswith("kill "), True)
    summons = [c for c in w.viz if c.startswith("summon minecraft:text_display")]
    check("spawn: text_display label count", len(summons),
          len(EDGES_A) + len(EDGES_B) + N_B)
    pads = [c for c in w.viz if c.startswith("fill ") and c.endswith("_wool")]
    check("spawn: node pad fills", len(pads), N_A + N_B)


def check_bfs():
    w, ticks = run_algo("bfs_start", "bfs_step")
    order, depth = ref_bfs()
    st = heap(w, "st")
    check("bfs: visit order", heap(w, "vlog")[:st[6]], order)
    check("bfs: depths", heap(w, "dist")[:N_A], depth)
    check("bfs: one visit per tick", ticks, N_A)
    check_visited_lime("bfs", w, order)


def check_dfs():
    w, _ = run_algo("dfs_start", "dfs_step")
    order = ref_dfs()
    st = heap(w, "st")
    check("dfs: visit order", heap(w, "vlog")[:st[6]], order)
    check_visited_lime("dfs", w, order)


def check_dijkstra():
    w, _ = run_algo("dijkstra_start", "dijkstra_step")
    order, dist = ref_dijkstra()
    st = heap(w, "st")
    check("dijkstra: settle order", heap(w, "vlog")[:st[6]], order)
    check("dijkstra: distances", heap(w, "dist")[:N_A], dist)
    check_visited_lime("dijkstra", w, order)


def check_prim():
    w, _ = run_algo("prim_start", "prim_step")
    accepted, weight = ref_prim()
    st = heap(w, "st")
    check("prim: accepted edge order", heap(w, "vlog")[:st[6]], accepted)
    check("prim: MST weight", st[5], weight)
    check("prim: MST edge count", st[6], N_A - 1)
    return set(accepted), weight


def check_kruskal(prim_edges, prim_weight):
    w, _ = run_algo("kruskal_start", "kruskal_step")
    accepted, rejected, weight = ref_kruskal()
    st = heap(w, "st")
    check("kruskal: accepted edge order", heap(w, "vlog")[:st[6]], accepted)
    check("kruskal: MST weight", st[5], weight)
    est = heap(w, "est")
    check("kruskal: rejected edges",
          [j for j, s in enumerate(est) if s == 2], sorted(rejected))
    check("kruskal: agrees with prim (edge set)", set(accepted), prim_edges)
    check("kruskal: agrees with prim (weight)", weight, prim_weight)


def check_maxflow():
    w, _ = run_algo("ek_start", "ek_step")
    flow, bottlenecks, reachable, cut = ref_maxflow()
    st = heap(w, "st")
    check("maxflow: flow value", st[5], flow)
    check("maxflow: $graph_flow scoreboard", w.scores.get("$graph_flow"), flow)
    check("maxflow: augmentation bottlenecks", heap(w, "vlog")[:st[6]],
          bottlenecks)
    check("maxflow: residual-reachable set",
          {i for i in range(N_B) if heap(w, "vis")[i] == 1}, reachable)
    # flow conservation at every internal node
    flw = heap(w, "flw")
    bad = [i for i in range(N_B)
           if i not in (FLOW_SOURCE, FLOW_SINK)
           and sum(flw[u * N_B + i] for u in range(N_B)) != 0]
    check("maxflow: conservation at internal nodes", bad, [])
    # the cut edges (and only they) were painted red among flow edges
    red = "minecraft:" + EDGE_BLOCKS[3]
    red_fedges = set()
    for j, (u, v, _) in enumerate(EDGES_B):
        cmds = [c for c in w.viz if c.endswith(red)]
        # match by any coordinate command of this edge's line
        from gen_graph_viz import edge_cmds
        line = set(edge_cmds(NODES_B, u, v, EDGE_BLOCKS[3]))
        if any(c in line for c in cmds):
            red_fedges.add(j)
    check("maxflow: min-cut edges painted red", red_fedges, set(cut))


def main():
    build = sys.argv[1] if len(sys.argv) > 1 else "build_graph"
    sim.DIR = os.path.abspath(build)

    check_spawn()
    check_bfs()
    check_dfs()
    check_dijkstra()
    prim_edges, prim_weight = check_prim()
    check_kruskal(prim_edges, prim_weight)
    check_maxflow()

    ok = all(_results)
    print(f"GRAPH SUITE {'PASSED' if ok else 'FAILED'} "
          f"({sum(_results)}/{len(_results)} checks)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
