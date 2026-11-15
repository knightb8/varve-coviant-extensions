#!/usr/bin/env python3
"""End-to-end coverage audit: source stores -> mirror -> lake, per runtime.

Read-only. Guards the DR-0003 invariant: every settled source session must be
mirrored and reach the lake. A unit is settled when it carries a usable
identity artifact (a uuid directory name, or a mirrored meta.json with a
session_id); anything else is in-flight and reported as pending, never failed
— live agents write stores continuously.

Usage:  python3 tools/coverage_audit.py [--compact] [--runtime NAME]
Exits:  0 all green (pending allowed), 1 gaps needing action, 2 setup error.
Environment: VARVE_ENGINE (required, a varve engine checkout),
             VARVE_DATA (default ~/.local/share/varve).
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

HOME = Path.home()
UUID_RE = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)


def fail(msg, code=2):
    print(f"coverage_audit: {msg}", file=sys.stderr)
    sys.exit(code)


def data_home():
    return Path(os.environ.get("VARVE_DATA", HOME / ".local/share/varve"))


def engine_cwd():
    e = os.environ.get("VARVE_ENGINE", "")
    if not e or not (Path(e).expanduser() / "bin/duck").is_file():
        fail("set VARVE_ENGINE to a varve engine checkout (it ships bin/duck)")
    return Path(e).expanduser()


def just_sql(query):
    proc = subprocess.run(
        ["just", "sql", "-json", "-noheader", "-c", query],
        cwd=engine_cwd(), env=dict(os.environ),
        capture_output=True, text=True, timeout=300)
    if proc.returncode != 0:
        raise RuntimeError(f"just sql failed: {proc.stderr.strip()[:300]}")
    out = proc.stdout.strip()
    return json.loads(out) if out else []


def runtime_rows(toml_path):
    """(name, source, include patterns) per [[row]] in runtimes.toml."""
    rows = []
    for chunk in re.split(r"\[\[row\]\]", toml_path.read_text()):
        nm = re.search(r'name = "([^"]+)"', chunk)
        src = re.search(r'source = "([^"]+)"', chunk)
        inc = re.search(r"include = \[(.*?)\]", chunk)
        if not (nm and src and inc):
            continue
        pats = [x.strip().strip('"') for x in inc.group(1).split(",")]
        rows.append((nm.group(1), src.group(1), pats))
    return rows


def audit_runtime(name, source, pats, data):
    src = Path(os.path.expanduser(source))
    mir = data / "mirror" / name
    rep = {"status": "OK", "source_units": 0, "mirror_units": 0,
           "lake_sessions": None, "pending": [], "unmirrored_units": [],
           "mirror_files_missing": 0, "settled_not_in_lake": []}
    if not src.is_dir():
        rep["status"] = "SKIP"
        rep["reason"] = "no source directory"
        return rep
    if not mir.is_dir():
        rep["status"] = "GAP"
        rep["reason"] = "no mirror yet; run just sync"
        return rep

    # units = the session store directories; vibe nests its 3.x stores one
    # level deep under unified/, everything else is a top-level child dir.
    def unit_map(root):
        def unit_of(rel):
            return "unified/" + rel.parts[1] if rel.parts[0] == "unified" else rel.parts[0]
        out = {}
        for pat in pats:
            for f in root.rglob(pat):
                rel = f.relative_to(root)
                out.setdefault(unit_of(rel), set()).add(str(rel))
        return out

    src_units = unit_map(src)
    mir_units = unit_map(mir)

    # file-level mirror completeness (sync only grows)
    unset = set()
    for unit, rels in src_units.items():
        for rel in rels:
            if not (mir / rel).is_file():
                rep["mirror_files_missing"] += 1
                unset.add(unit)

    # settle identities. A uuid-named unit settles once it carries identity
    # artifacts in the source (meta.json, or a unified projection state) —
    # until then it is a live, in-flight store. Non-uuid units settle via
    # mirrored meta.json. Opaque units (databases and similar blobs) cannot
    # be identity-mapped here: neither settled nor pending.
    settled, pending = set(), set()
    for unit in src_units:
        rels = [Path(rel) for rel in src_units[unit]]
        if all((src / r).is_file() for r in rels):
            continue  # a loose file, not a session store (indices etc.)
        udir = src / unit.split('/')[0] if not unit.startswith('unified/') \
            else src / 'unified' / unit.split('/')[1]
        name_from_meta = None
        if any(rel.suffix in ('.db', '.db-wal') for rel in rels):
            continue  # opaque
        has_projection = any(udir.glob('generations/*/projection-state.json')) \
            if (udir / 'generations').is_dir() else False
        for meta in list((mir / unit).glob('meta.json')) + list((udir).glob('meta.json')):
            try:
                name_from_meta = json.loads(meta.read_text()).get("session_id")
            except Exception:
                name_from_meta = None
            break
        if UUID_RE.match(unit) and (has_projection or (udir / 'meta.json').is_file()):
            settled.add(unit)
        elif name_from_meta:
            settled.add(name_from_meta)
        else:
            pending.add(unit)  # identity artifact missing: in-flight
    rep["pending"] = sorted(pending)

    # lake coverage of settled identities
    ids = {r["session_id"] for r in just_sql(
        f"SELECT session_id FROM sessions WHERE runtime = '{name}'")}
    rep["lake_sessions"] = len(ids)
    rep["settled_not_in_lake"] = sorted(settled - ids)
    rep["source_units"] = len(src_units)
    rep["mirror_units"] = len(mir_units)
    rep["unmirrored_units"] = sorted(set(src_units) - set(mir_units))

    if rep["settled_not_in_lake"] or rep["unmirrored_units"] or rep["mirror_files_missing"]:
        rep["status"] = "GAP"
    elif rep["pending"]:
        rep["status"] = "OK_PENDING"
    return rep


def main():
    compact = "--compact" in sys.argv
    only = next((a.split("=", 1)[1] for a in sys.argv[1:]
                 if a.startswith("--runtime=")), None)
    data = data_home()
    toml = data / "runtimes.toml"
    if not toml.is_file():
        fail(f"no runtimes.toml at {toml}")
    report, gap = {}, False
    for name, source, pats in sorted(runtime_rows(toml)):
        if only and name != only:
            continue
        rep = audit_runtime(name, source, pats, data)
        if rep["status"] == "GAP":
            gap = True
        report[name] = rep
    print(json.dumps(report, indent=None if compact else 2))
    if gap:
        print("action: `just sync` then `just build` in $VARVE_ENGINE, re-run audit",
              file=sys.stderr)
    sys.exit(1 if gap else 0)


if __name__ == "__main__":
    main()
