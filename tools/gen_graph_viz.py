#!/usr/bin/env python3
"""Layout source of truth + generator for the graph-visualization demo.

Importable constants (NODES_A, EDGES_A, NODES_B, EDGES_B, palettes) are
shared by tools/sim_check_graph.py so the MCaml program and the Python
reference implementations can never disagree about the graphs.

Run as a script to (re)generate scripts/graph_world.mcaml:

    python3 tools/gen_graph_viz.py

The generated file contains the graph-data `val` arrays, graph_spawn /
graph_reset / graph_despawn, and the viz dispatch functions that map a
runtime (element id, state) pair onto static fill/setblock commands.
All world coordinates are compile-time constants baked in here.
"""
import os

# ---------------------------------------------------------------- layout

# The Redstone Ready superflat preset spawns the player at (0, 58, 0),
# i.e. the top ground block is y=57 — NOT the vanilla-superflat -60.
Y_PLAT = 57   # platform (replaces the ground surface layer)
Y_NODE = 58   # node pads + edge lines
Y_MARK = 59   # flow-edge direction markers
Y_LABEL = 61  # text_display weight/capacity labels

# Graph A: undirected weighted, 16 nodes on a 4x4 grid (x, z), spacing 12,
# node ids row-major (n = row*4 + col). Edges: every grid adjacency
# (12 horizontal + 12 vertical) plus 4 diagonals = 28 edges. Weights are a
# fixed permutation of 1..28 ((i*11) % 28 + 1) - all distinct => unique MST.
GRID = 4
SPACING = 12
NODES_A = [(col * SPACING, row * SPACING)
           for row in range(GRID) for col in range(GRID)]

_pairs = []
for row in range(GRID):
    for col in range(GRID):
        n = row * GRID + col
        if col + 1 < GRID:
            _pairs.append((n, n + 1))         # horizontal
for row in range(GRID):
    for col in range(GRID):
        n = row * GRID + col
        if row + 1 < GRID:
            _pairs.append((n, n + GRID))      # vertical
_pairs += [(0, 5), (2, 7), (8, 13), (10, 15)]  # diagonals
EDGES_A = [(u, v, (i * 11) % 28 + 1) for i, (u, v) in enumerate(_pairs)]

# Graph B: directed flow network, 10 nodes in layers left to right:
# S=0, first layer A-D = 1..4, second layer E-H = 5..8, T=9 (sink LAST -
# graph_algos.mcaml addresses the sink as gsz[2]-1).
NODES_B = [(0, 64)] + \
          [(14, 49 + 10 * i) for i in range(4)] + \
          [(28, 49 + 10 * i) for i in range(4)] + \
          [(42, 64)]
NODE_NAMES_B = ["S", "A", "B", "C", "D", "E", "F", "G", "H", "T"]
# (u, v, capacity)
EDGES_B = [
    (0, 1, 12), (0, 2, 14), (0, 3, 10), (0, 4, 8),    # S -> layer 1
    (1, 5, 7), (1, 6, 6),                             # A -> E, F
    (2, 6, 9), (2, 7, 8),                             # B -> F, G
    (3, 7, 7), (3, 5, 5),                             # C -> G, E
    (4, 8, 12), (4, 7, 3),                            # D -> H, G
    (5, 9, 15), (6, 9, 14), (7, 9, 8), (8, 9, 6),     # layer 2 -> T
]
# Max-flow 40 via 7 augmenting paths; the min cut spans all three layers
# (S->A, B->F, C->E, G->T, H->T) so the finale paints a mixed partition.

FLOW_SOURCE, FLOW_SINK = 0, len(NODES_B) - 1

# ---------------------------------------------------------------- palette

# Node states -> pad block.
NODE_BLOCKS = [
    "white_wool",       # 0 idle
    "yellow_wool",      # 1 frontier / in-queue
    "orange_wool",      # 2 current
    "lime_wool",        # 3 visited / settled / in-tree
    "blue_wool",        # 4 source
    "red_wool",         # 5 sink
    "light_blue_wool",  # 6 min-cut S-side
    "pink_wool",        # 7 min-cut T-side
]

# Edge states -> line block.
EDGE_BLOCKS = [
    "gray_concrete",    # 0 idle
    "orange_concrete",  # 1 current / considering
    "lime_concrete",    # 2 accepted / tree / MST
    "red_concrete",     # 3 rejected / min-cut edge
    "yellow_concrete",  # 4 augmenting path (transient)
    "purple_concrete",  # 5 saturated
]

PLATFORM_BLOCK = "smooth_stone"
MARKER_BLOCK = "magenta_concrete"
ENTITY_TAG = "mcaml_graph"

# Platform bounds: bounding box of both graphs + margin.
MARGIN = 6
_ALL_XZ = NODES_A + NODES_B
PLAT_X0 = min(x for x, _ in _ALL_XZ) - MARGIN
PLAT_X1 = max(x for x, _ in _ALL_XZ) + MARGIN
PLAT_Z0 = min(z for _, z in _ALL_XZ) - MARGIN
PLAT_Z1 = max(z for _, z in _ALL_XZ) + MARGIN

# ------------------------------------------------------------- geometry


def bresenham(x0, z0, x1, z1):
    """Integer line from (x0,z0) to (x1,z1) inclusive, in the XZ plane."""
    pts = []
    dx, dz = abs(x1 - x0), abs(z1 - z0)
    sx = 1 if x1 >= x0 else -1
    sz = 1 if z1 >= z0 else -1
    err = dx - dz
    x, z = x0, z0
    while True:
        pts.append((x, z))
        if x == x1 and z == z1:
            break
        e2 = 2 * err
        if e2 > -dz:
            err -= dz
            x += sx
        if e2 < dx:
            err += dx
            z += sz
    return pts


def edge_points(nodes, u, v):
    """Rasterized line between node centers, trimmed clear of the 3x3 pads."""
    ux, uz = nodes[u]
    vx, vz = nodes[v]
    pts = bresenham(ux, uz, vx, vz)

    def in_pad(p):
        return (max(abs(p[0] - ux), abs(p[1] - uz)) <= 1
                or max(abs(p[0] - vx), abs(p[1] - vz)) <= 1)

    trimmed = [p for p in pts if not in_pad(p)]
    assert trimmed, f"edge {u}-{v} vanished after pad trim"
    return trimmed


def pad_fill(node_xz, block):
    x, z = node_xz
    return (f"fill {x-1} {Y_NODE} {z-1} {x+1} {Y_NODE} {z+1} "
            f"minecraft:{block}")


def edge_cmds(nodes, u, v, block):
    """Commands recoloring one edge line: a single fill when axis-aligned,
    per-block setblocks otherwise."""
    pts = edge_points(nodes, u, v)
    xs = {p[0] for p in pts}
    zs = {p[1] for p in pts}
    if len(xs) == 1 or len(zs) == 1:
        (x0, z0), (x1, z1) = pts[0], pts[-1]
        return [f"fill {x0} {Y_NODE} {z0} {x1} {Y_NODE} {z1} "
                f"minecraft:{block}"]
    return [f"setblock {x} {Y_NODE} {z} minecraft:{block}" for x, z in pts]


def label_at(x, z, text):
    scale = ("transformation:{translation:[0f,0f,0f],"
             "left_rotation:[0f,0f,0f,1f],right_rotation:[0f,0f,0f,1f],"
             "scale:[3f,3f,3f]}")
    return (f"summon minecraft:text_display {x} {Y_LABEL} {z} "
            f"{{text:'\"{text}\"',Tags:[\"{ENTITY_TAG}\"],"
            f"billboard:\"center\",{scale}}}")


def label_cmd(nodes, u, v, text):
    ux, uz = nodes[u]
    vx, vz = nodes[v]
    return label_at((ux + vx) / 2 + 0.5, (uz + vz) / 2 + 0.5, text)


def marker_cmd(u, v):
    """Direction marker for a flow edge: one block above the line, at the
    trimmed point nearest the head node v. Spawn-only, never recolored."""
    x, z = edge_points(NODES_B, u, v)[-1]
    return f"setblock {x} {Y_MARK} {z} minecraft:{MARKER_BLOCK}"


# ------------------------------------------------------------ mcaml emit


def esc(cmd):
    return cmd.replace("\\", "\\\\").replace('"', '\\"')


def mc(cmd):
    return f'cmd! "{esc(cmd)}"'


def emit_val(name, ints):
    return f"val {name} = [| {'; '.join(str(n) for n in ints)} |]"


def emit_dispatch(name, n_elems, n_states, cmds_for):
    """fun <name>(i, s) dispatching runtime (element, state) onto static
    commands via nested if chains."""
    out = [f"fun {name} (i: int, s: int) : unit ="]
    for i in range(n_elems):
        head = "  if" if i == 0 else "  else if"
        out.append(f"{head} i = {i} then (")
        for s in range(n_states):
            body = "; ".join(mc(c) for c in cmds_for(i, s))
            if s == 0:
                out.append(f"    if s = 0 then ({body})")
            elif s < n_states - 1:
                out.append(f"    else if s = {s} then ({body})")
            else:
                out.append(f"    else ({body})")
        out.append("  )")
    out.append("  else ()")
    return "\n".join(out)


def idle_world_cmds(include_platform):
    """Commands painting both graphs in their idle state."""
    cmds = []
    if include_platform:
        cmds.append(f"fill {PLAT_X0} {Y_PLAT} {PLAT_Z0} "
                    f"{PLAT_X1} {Y_PLAT} {PLAT_Z1} "
                    f"minecraft:{PLATFORM_BLOCK}")
    for i, xz in enumerate(NODES_A):
        cmds.append(pad_fill(xz, NODE_BLOCKS[0]))
    for i, xz in enumerate(NODES_B):
        state = 4 if i == FLOW_SOURCE else 5 if i == FLOW_SINK else 0
        cmds.append(pad_fill(xz, NODE_BLOCKS[state]))
    for u, v, _ in EDGES_A:
        cmds.extend(edge_cmds(NODES_A, u, v, EDGE_BLOCKS[0]))
    for u, v, _ in EDGES_B:
        cmds.extend(edge_cmds(NODES_B, u, v, EDGE_BLOCKS[0]))
    return cmds


def generate():
    parts = []
    parts.append("(* GENERATED by tools/gen_graph_viz.py - do not hand-edit.\n"
                 "   Graph layouts, palette, and world coordinates all live\n"
                 "   in the generator; rerun it after any layout change. *)")

    # -- graph data vals (consumed by scripts/graph_algos.mcaml)
    # gsz = sizes: [N_A nodes; E_A edges; N_B flow nodes; E_B flow edges]
    # graph_algos.mcaml loops read bounds from here, so resizing the
    # graphs is a generator-only change.
    parts.append(emit_val("gsz", [len(NODES_A), len(EDGES_A),
                                  len(NODES_B), len(EDGES_B)]))
    parts.append(emit_val("eu", [e[0] for e in EDGES_A]))
    parts.append(emit_val("ev", [e[1] for e in EDGES_A]))
    parts.append(emit_val("ew", [e[2] for e in EDGES_A]))
    parts.append(emit_val("fu", [e[0] for e in EDGES_B]))
    parts.append(emit_val("fv", [e[1] for e in EDGES_B]))
    parts.append(emit_val("fc", [e[2] for e in EDGES_B]))

    # -- viz dispatch functions
    parts.append(emit_dispatch(
        "viz_node", len(NODES_A), len(NODE_BLOCKS),
        lambda i, s: [pad_fill(NODES_A[i], NODE_BLOCKS[s])]))
    parts.append(emit_dispatch(
        "viz_edge", len(EDGES_A), len(EDGE_BLOCKS),
        lambda e, s: edge_cmds(NODES_A, EDGES_A[e][0], EDGES_A[e][1],
                               EDGE_BLOCKS[s])))
    parts.append(emit_dispatch(
        "viz_fnode", len(NODES_B), len(NODE_BLOCKS),
        lambda i, s: [pad_fill(NODES_B[i], NODE_BLOCKS[s])]))
    parts.append(emit_dispatch(
        "viz_fedge", len(EDGES_B), len(EDGE_BLOCKS),
        lambda e, s: edge_cmds(NODES_B, EDGES_B[e][0], EDGES_B[e][1],
                               EDGE_BLOCKS[s])))

    # -- graph_spawn: kill stale labels, platform, idle paint, markers, labels
    spawn = [f"kill @e[type=minecraft:text_display,tag={ENTITY_TAG}]"]
    spawn.extend(idle_world_cmds(include_platform=True))
    for u, v, _ in EDGES_B:
        spawn.append(marker_cmd(u, v))
    for u, v, w in EDGES_A:
        spawn.append(label_cmd(NODES_A, u, v, str(w)))
    for u, v, c in EDGES_B:
        spawn.append(label_cmd(NODES_B, u, v, str(c)))
    for i, (x, z) in enumerate(NODES_B):
        spawn.append(label_at(x + 0.5, z - 2 + 0.5, NODE_NAMES_B[i]))
    spawn.append("say [graph] spawned: graph A (weighted) + graph B (flow)")
    parts.append("fun graph_spawn () : unit =\n  "
                 + ";\n  ".join(mc(c) for c in spawn))

    # -- graph_reset: repaint both graphs idle (no platform/entity ops)
    reset = idle_world_cmds(include_platform=False)
    parts.append("fun graph_reset () : unit =\n  "
                 + ";\n  ".join(mc(c) for c in reset))

    # -- graph_despawn: labels + everything above/at the platform
    despawn = [
        f"kill @e[type=minecraft:text_display,tag={ENTITY_TAG}]",
        f"fill {PLAT_X0} {Y_PLAT} {PLAT_Z0} "
        f"{PLAT_X1} {Y_LABEL} {PLAT_Z1} minecraft:air",
        "say [graph] despawned",
    ]
    parts.append("fun graph_despawn () : unit =\n  "
                 + ";\n  ".join(mc(c) for c in despawn))

    return "\n\n".join(parts) + "\n"


def main():
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(repo, "scripts", "graph_world.mcaml")
    with open(out, "w") as f:
        f.write(generate())
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
