"""Minecraft command simulator for MCaml-compiled .mcfunction files.

Simulates the subset of Minecraft commands that the MCaml compiler emits:
scoreboard operations, NBT storage, function dispatch, execute chains,
macro substitution, tick_guard return, and frame-stack save/restore.
"""
from __future__ import annotations

import os
import re
import sys

sys.setrecursionlimit(200000)

DIR: str = ""


class _ReturnFromFunction(Exception):
    def __init__(self, value: int = 0):
        self.value = value


# Unmodeled world-mutating commands recorded into World.viz (see below).
_VIZ_COMMANDS = ("setblock ", "fill ", "summon ", "kill ", "particle ",
                 "tellraw ")


class World:
    def __init__(self):
        self.scores: dict[str, int] = {"$c256": 256}
        self.storage: dict[str, dict] = {}
        self.say: list[str] = []
        # World-mutating commands (setblock/fill/...) are not modeled, but
        # executed ones are logged here so tests can assert on the
        # visualization command stream.
        self.viz: list[str] = []


def load(name: str) -> list[str]:
    path = os.path.join(DIR, f"{name}.mcfunction")
    with open(path) as f:
        lines = f.read().splitlines()
    return [l.strip() for l in lines if l.strip()]


def _floor_div(a: int, b: int) -> int:
    """Vanilla scoreboard /= is Math.floorDiv (confirmed in-game
    2026-07-07 on 1.21.x via mc_test_suite t05), not Java's truncating
    int division. Python // is already floor."""
    if b == 0:
        return 0
    return a // b


def _floor_mod(a: int, b: int) -> int:
    """Vanilla scoreboard %= is Math.floorMod (confirmed in-game via
    mc_test_suite t08): result takes the divisor's sign."""
    if b == 0:
        return 0
    return a - _floor_div(a, b) * b


def _storage_root(world: World, sid: str) -> dict:
    if sid not in world.storage:
        world.storage[sid] = {}
    return world.storage[sid]


def _resolve_path(root: dict, path: str, create: bool = True):
    parts = re.split(r'\.', path)
    obj = root
    for i, part in enumerate(parts):
        m = re.match(r'^(.+?)\[(-?\d+)\]$', part)
        if m:
            key, idx_s = m.group(1), int(m.group(2))
            if i < len(parts) - 1:
                lst = obj[key]
                idx = idx_s if idx_s >= 0 else len(lst) + idx_s
                obj = lst[idx]
            else:
                return obj, key, idx_s
        else:
            if i < len(parts) - 1:
                if create and part not in obj:
                    obj[part] = {}
                obj = obj[part]
            else:
                return obj, part, None
    return root, path, None


def storage_get(world: World, sid: str, path: str):
    root = _storage_root(world, sid)
    obj, key, idx = _resolve_path(root, path)
    if idx is not None:
        lst = obj[key]
        real_idx = idx if idx >= 0 else len(lst) + idx
        return lst[real_idx]
    return obj.get(key)


def storage_set_value(world: World, sid: str, path: str, value) -> None:
    root = _storage_root(world, sid)
    obj, key, idx = _resolve_path(root, path)
    if idx is not None:
        lst = obj[key]
        real_idx = idx if idx >= 0 else len(lst) + idx
        lst[real_idx] = value
    else:
        obj[key] = value


def storage_set_scalar(world: World, sid: str, path: str, value: int) -> None:
    storage_set_value(world, sid, path, value)


def _parse_nbt_value(s: str):
    s = s.strip()
    if s.startswith('['):
        inner = s[1:-1].strip()
        if not inner:
            return []
        return [_parse_nbt_value(x.strip()) for x in inner.split(',')]
    if s.startswith('{'):
        result = {}
        inner = s[1:-1].strip()
        if not inner:
            return result
        for pair in _split_nbt_compound(inner):
            k, v = pair.split(':', 1)
            result[k.strip()] = _parse_nbt_value(v.strip())
        return result
    try:
        return int(s)
    except ValueError:
        return s


def _split_nbt_compound(s: str) -> list[str]:
    parts = []
    depth = 0
    current = []
    for ch in s:
        if ch in ('{', '['):
            depth += 1
            current.append(ch)
        elif ch in ('}', ']'):
            depth -= 1
            current.append(ch)
        elif ch == ',' and depth == 0:
            parts.append(''.join(current))
            current = []
        else:
            current.append(ch)
    if current:
        parts.append(''.join(current))
    return parts


def _check_data_exists(world: World, sid: str, path: str) -> bool:
    try:
        root = _storage_root(world, sid)
        obj, key, idx = _resolve_path(root, path)
        if idx is not None:
            lst = obj.get(key)
            if lst is None:
                return False
            real_idx = idx if idx >= 0 else len(lst) + idx
            return 0 <= real_idx < len(lst)
        return key in obj
    except (KeyError, IndexError, TypeError):
        return False


def _eval_score_condition(world: World, cond: str) -> bool:
    # score X obj matches N..
    m = re.match(r'score (\S+) (\S+) matches (-?\d+)\.\.$', cond)
    if m:
        return world.scores.get(m.group(1), 0) >= int(m.group(3))

    # score X obj matches ..N
    m = re.match(r'score (\S+) (\S+) matches \.\.(-?\d+)$', cond)
    if m:
        return world.scores.get(m.group(1), 0) <= int(m.group(3))

    # score X obj matches N
    m = re.match(r'score (\S+) (\S+) matches (-?\d+)$', cond)
    if m:
        return world.scores.get(m.group(1), 0) == int(m.group(3))

    # score X obj <cmp> Y obj
    m = re.match(r'score (\S+) (\S+) ([<>=!]+) (\S+) (\S+)$', cond)
    if m:
        a = world.scores.get(m.group(1), 0)
        b = world.scores.get(m.group(4), 0)
        op = m.group(3)
        if op == '=':
            return a == b
        elif op == '<':
            return a < b
        elif op == '>':
            return a > b
        elif op == '<=':
            return a <= b
        elif op == '>=':
            return a >= b
    return False


def _exec_plain(world: World, cmd: str, depth: int, macros: dict | None = None) -> int | None:
    # return 0
    if cmd == 'return 0':
        raise _ReturnFromFunction(0)

    # return run <command> — execute the command, then return from the
    # current function (MC 1.20.5+). MCaml emits this for every TTail
    # dispatch so the caller frame cannot fall through into the guarded
    # lines that follow the tail call in the file.
    if cmd.startswith('return run '):
        _exec_line(world, cmd[len('return run '):], depth, macros)
        raise _ReturnFromFunction(0)

    # say
    if cmd.startswith('say '):
        world.say.append(cmd[4:])
        return None

    # schedule — no-op in sim
    if cmd.startswith('schedule '):
        return None

    # scoreboard players set X obj N
    m = re.match(r'scoreboard players set (\S+) (\S+) (-?\d+)$', cmd)
    if m:
        name, val = m.group(1), int(m.group(3))
        world.scores[name] = val
        return val

    # scoreboard players get X obj
    m = re.match(r'scoreboard players get (\S+) (\S+)$', cmd)
    if m:
        return world.scores.get(m.group(1), 0)

    # scoreboard players add X obj N
    m = re.match(r'scoreboard players add (\S+) (\S+) (-?\d+)$', cmd)
    if m:
        name, val = m.group(1), int(m.group(3))
        cur = world.scores.get(name, 0)
        world.scores[name] = cur + val
        return cur + val

    # scoreboard players remove X obj N
    m = re.match(r'scoreboard players remove (\S+) (\S+) (-?\d+)$', cmd)
    if m:
        name, val = m.group(1), int(m.group(3))
        cur = world.scores.get(name, 0)
        world.scores[name] = cur - val
        return cur - val

    # scoreboard players operation X obj <op> Y obj
    m = re.match(r'scoreboard players operation (\S+) (\S+) ([+\-*/%<>=]+) (\S+) (\S+)$', cmd)
    if m:
        d_name, op, s_name = m.group(1), m.group(3), m.group(4)
        d_val = world.scores.get(d_name, 0)
        s_val = world.scores.get(s_name, 0)
        if op == '=':
            result = s_val
        elif op == '+=':
            result = d_val + s_val
        elif op == '-=':
            result = d_val - s_val
        elif op == '*=':
            result = d_val * s_val
        elif op == '/=':
            result = _floor_div(d_val, s_val)
        elif op == '%=':
            result = _floor_mod(d_val, s_val)
        elif op == '<':
            result = min(d_val, s_val)
        elif op == '>':
            result = max(d_val, s_val)
        else:
            result = d_val
        world.scores[d_name] = result
        return result

    # function mcaml:<name> with storage <sid> <path>
    m = re.match(r'function mcaml:(\S+) with storage (\S+) (\S+)$', cmd)
    if m:
        fname, sid, path = m.group(1), m.group(2), m.group(3)
        macro_data = storage_get(world, sid, path)
        if not isinstance(macro_data, dict):
            macro_data = {}
        run_function(world, fname, depth + 1, macros=macro_data)
        return None

    # function mcaml:<name>
    m = re.match(r'function mcaml:(\S+)$', cmd)
    if m:
        run_function(world, m.group(1), depth + 1)
        return None

    # data modify storage <sid> <path> set value <nbt>
    m = re.match(r'data modify storage (\S+) (.+?) set value (.+)$', cmd)
    if m:
        storage_set_value(world, m.group(1), m.group(2), _parse_nbt_value(m.group(3)))
        return None

    # data modify storage <sid> <path> append value <nbt>
    m = re.match(r'data modify storage (\S+) (.+?) append value (.+)$', cmd)
    if m:
        sid, path, nbt = m.group(1), m.group(2), m.group(3)
        root = _storage_root(world, sid)
        obj, key, idx = _resolve_path(root, path)
        if key not in obj:
            obj[key] = []
        obj[key].append(_parse_nbt_value(nbt))
        return None

    # data remove storage <sid> <path>
    m = re.match(r'data remove storage (\S+) (.+)$', cmd)
    if m:
        sid, path = m.group(1), m.group(2)
        root = _storage_root(world, sid)
        obj, key, idx = _resolve_path(root, path)
        if idx is not None:
            lst = obj[key]
            real_idx = idx if idx >= 0 else len(lst) + idx
            lst.pop(real_idx)
        else:
            obj.pop(key, None)
        return None

    # data get storage <sid> <path> <scale>
    m = re.match(r'data get storage (\S+) (.+?) (-?\d+)$', cmd)
    if m:
        sid, path, scale = m.group(1), m.group(2), int(m.group(3))
        val = storage_get(world, sid, path)
        if val is None:
            return 0
        return int(val) * scale

    for _p in _VIZ_COMMANDS:
        if cmd.startswith(_p):
            world.viz.append(cmd)
            return None

    return None


def _apply_macros(line: str, macros: dict | None) -> str:
    if line.startswith('$'):
        line = line[1:]
    if macros:
        for k, v in macros.items():
            line = line.replace(f'$({k})', str(v))
    return line


def _store_value(world: World, store_mode: str, store_target: tuple, val: int) -> None:
    if store_target[0] == 'score':
        world.scores[store_target[1]] = val
    elif store_target[0] == 'storage':
        _, sid, path, scale = store_target
        storage_set_scalar(world, sid, path, val * scale)


def _exec_line(world: World, line: str, depth: int, macros: dict | None = None) -> int | None:
    """Execute a single line (top-level entry point for each .mcfunction line)."""
    if macros and line.startswith('$'):
        line = _apply_macros(line, macros)
    elif line.startswith('$'):
        line = line[1:]

    if line.startswith('execute '):
        return _exec_execute(world, line[8:], depth, macros)
    else:
        return _exec_plain(world, line, depth, macros)


def _exec_execute(world: World, rest: str, depth: int, macros: dict | None = None) -> int | None:
    """Parse and run an execute chain. `rest` is everything after 'execute '."""

    store_mode = None
    store_target = None

    # store result score <name> <obj>
    m = re.match(r'store result score (\S+) (\S+) (.+)$', rest)
    if m:
        store_mode = 'result'
        store_target = ('score', m.group(1))
        rest = m.group(3)

    if store_mode is None:
        m = re.match(r'store success score (\S+) (\S+) (.+)$', rest)
        if m:
            store_mode = 'success'
            store_target = ('score', m.group(1))
            rest = m.group(3)

    if store_mode is None:
        m = re.match(r'store result storage (\S+) (.+?) int (-?\d+) (.+)$', rest)
        if m:
            store_mode = 'result'
            store_target = ('storage', m.group(1), m.group(2), int(m.group(3)))
            rest = m.group(4)

    # Now parse condition chain + terminal command
    conditions = []
    while rest:
        # if score ... matches ...
        m = re.match(r'if (score \S+ \S+ matches \S+) (.+)$', rest)
        if m:
            conditions.append(('if', m.group(1)))
            rest = m.group(2)
            if rest.startswith('run '):
                rest = rest[4:]
                break
            continue

        # unless score ... matches ...
        m = re.match(r'unless (score \S+ \S+ matches \S+) (.+)$', rest)
        if m:
            conditions.append(('unless', m.group(1)))
            rest = m.group(2)
            if rest.startswith('run '):
                rest = rest[4:]
                break
            continue

        # if score ... <cmp> ...
        m = re.match(r'if (score \S+ \S+ [<>=!]+ \S+ \S+)( .+)?$', rest)
        if m:
            conditions.append(('if', m.group(1)))
            tail = (m.group(2) or '').strip()
            if not tail:
                rest = ''
                break
            if tail.startswith('run '):
                rest = tail[4:]
                break
            rest = tail
            continue

        # unless score ... <cmp> ...
        m = re.match(r'unless (score \S+ \S+ [<>=!]+ \S+ \S+)( .+)?$', rest)
        if m:
            conditions.append(('unless', m.group(1)))
            tail = (m.group(2) or '').strip()
            if not tail:
                rest = ''
                break
            if tail.startswith('run '):
                rest = tail[4:]
                break
            rest = tail
            continue

        # if data storage <sid> <path>
        m = re.match(r'if (data storage \S+ \S+)( .+)?$', rest)
        if m:
            conditions.append(('if', m.group(1)))
            tail = (m.group(2) or '').strip()
            if not tail:
                rest = ''
                break
            if tail.startswith('run '):
                rest = tail[4:]
                break
            rest = tail
            continue

        # unless data storage <sid> <path>
        m = re.match(r'unless (data storage \S+ \S+)( .+)?$', rest)
        if m:
            conditions.append(('unless', m.group(1)))
            tail = (m.group(2) or '').strip()
            if not tail:
                rest = ''
                break
            if tail.startswith('run '):
                rest = tail[4:]
                break
            rest = tail
            continue

        # Must be a 'run ...' at this point
        if rest.startswith('run '):
            rest = rest[4:]
        break

    # Evaluate conditions
    all_pass = True
    for kind, cond_str in conditions:
        cond_val = _eval_condition(world, cond_str)
        if kind == 'if' and not cond_val:
            all_pass = False
            break
        elif kind == 'unless' and cond_val:
            all_pass = False
            break

    if not all_pass:
        if store_mode and store_target:
            _store_value(world, store_mode, store_target, 0)
        return 0 if store_mode else None

    if store_mode == 'success':
        # For store success, the "success" is whether all conditions pass.
        # If there's a terminal command, execute it and success = 1 if conditions pass.
        if rest:
            # Execute the inner command (for side effects) but store 1 (success)
            if rest.startswith('execute '):
                _exec_execute(world, rest[8:], depth, macros)
            else:
                _exec_plain(world, rest, depth, macros)
        _store_value(world, 'success', store_target, 1)
        return 1

    if store_mode == 'result':
        inner_result = 0
        if rest:
            if rest.startswith('execute '):
                r = _exec_execute(world, rest[8:], depth, macros)
            else:
                r = _exec_plain(world, rest, depth, macros)
            if r is not None:
                inner_result = r
        _store_value(world, 'result', store_target, inner_result)
        return inner_result

    # No store — just execute the inner command
    if rest:
        if rest.startswith('execute '):
            return _exec_execute(world, rest[8:], depth, macros)
        else:
            return _exec_plain(world, rest, depth, macros)

    return None


def _eval_condition(world: World, cond_str: str) -> bool:
    if cond_str.startswith('score '):
        return _eval_score_condition(world, cond_str)
    m = re.match(r'data storage (\S+) (.+)$', cond_str)
    if m:
        return _check_data_exists(world, m.group(1), m.group(2))
    return False


def run_function(world: World, name: str, depth: int = 0,
                 macros: dict | None = None) -> None:
    lines = load(name)
    try:
        for line in lines:
            if macros and line.startswith('$'):
                line = _apply_macros(line, macros)
            _exec_line(world, line, depth, macros)
    except _ReturnFromFunction:
        return
