"""Shared behave fixtures: reach the varve engine, lake, and mirror.

Portability contract:
- VARVE_ENGINE must point at a varve engine checkout (the repo that ships
  bin/duck, bin/sync, sql/prelude.sql). There is no hardcoded location.
- VARVE_DATA defaults to varve's own standard data home (~/.local/share/varve).
"""

import json
import os
from pathlib import Path

HOME = Path.home()
REPO = Path(__file__).resolve().parents[1]
DATA = Path(os.environ.get("VARVE_DATA", HOME / ".local/share/varve"))


def engine_env():
    env = dict(os.environ)
    shims = str(HOME / ".local/share/mise/shims")
    if Path(shims).is_dir():
        env["PATH"] = shims + os.pathsep + env.get("PATH", "")
    return env


def _engine():
    """Locate the varve engine checkout ($VARVE_ENGINE), fail with guidance."""
    engine = os.environ.get("VARVE_ENGINE", "")
    msg = (
        "VARVE_ENGINE is not set: point it at a varve engine checkout "
        "(the repo that ships bin/duck, bin/sync and sql/prelude.sql), e.g.\n"
        "  export VARVE_ENGINE=~/path/to/varve"
    )
    if not engine:
        raise AssertionError(msg)
    engine = Path(engine).expanduser()
    if not (engine / "bin/duck").is_file():
        raise AssertionError(f"VARVE_ENGINE={engine} is not a varve checkout ({msg})")
    return engine


engine = _engine  # public alias for step definitions


def run_sql(query, timeout=300):
    """Run a read-only query against the lake through the engine runner."""
    import subprocess

    proc = subprocess.run(
        ["just", "sql", "-json", "-noheader", "-c", query],
        cwd=_engine(), env=engine_env(), capture_output=True, text=True, timeout=timeout,
    )
    if proc.returncode != 0:
        raise AssertionError(
            f"just sql failed (rc={proc.returncode}): {proc.stderr.strip()[:400]}"
        )
    out = proc.stdout.strip()
    return json.loads(out) if out else []


def mirrored_unified_stores():
    """Mirror-side unified store directories that carry a projection state."""
    base = DATA / "mirror/vibe/unified"
    if not base.is_dir():
        return set()
    return {
        p.name for p in base.iterdir()
        if p.is_dir() and any((p / "generations").glob("*/projection-state.json"))
    }


def stores_with_meta():
    base = DATA / "mirror/vibe/unified"
    if not base.is_dir():
        return set()
    return {p.name for p in base.iterdir() if (p / "meta.json").is_file()}


def before_all(context):
    context.repo = REPO
    context.run_sql = run_sql
    context.data_home = DATA
    context.mirrored_unified_stores = mirrored_unified_stores
    context.stores_with_meta = stores_with_meta
