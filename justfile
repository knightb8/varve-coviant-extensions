# varve-coviant-extensions automation recipes
set shell := ["bash", "-uc"]

VARVE_DATA := env("VARVE_DATA", home_directory() / ".local/share/varve")
# Required: point VARVE_ENGINE at any varve engine checkout (bin/duck, sql/prelude.sql).
VARVE_ENGINE := env("VARVE_ENGINE", "")

default:
    @just --list

# Install extension adapters into your Varve data home ($VARVE_DATA/adapters)
install:
    @mkdir -p "{{VARVE_DATA}}/adapters"
    @cp -v adapters/*.sql "{{VARVE_DATA}}/adapters/"
    @echo "✓ Copied adapters to {{VARVE_DATA}}/adapters/"
    @echo ""
    @echo "Next steps:"
    @echo "1. Ensure {{VARVE_DATA}}/runtimes.toml includes the extension runtimes (see runtimes.extension.toml)."
    @echo "2. Run 'just sync && just build' in your Varve repository."

# Display extension adapter configuration status
status:
    @echo "Varve Data Directory: {{VARVE_DATA}}"
    @echo "Installed Adapters in {{VARVE_DATA}}/adapters:"
    @ls -l "{{VARVE_DATA}}/adapters"/*.sql 2>/dev/null || echo "  (none installed yet)"

# Compile each extension adapter the same way bin/build would, but in the
# engine's in-memory runner: pinned duckdb, shared prelude, mirror variable.
# Safe at any time — nothing is written to the lake.
test:
    #!/usr/bin/env bash
    set -uo pipefail
    if [ -z "{{VARVE_ENGINE}}" ]; then
        echo "VARVE_ENGINE is not set: point it at a varve engine checkout" >&2
        echo "  export VARVE_ENGINE=~/path/to/varve   # the repo that ships bin/duck, sql/prelude.sql" >&2
        exit 2
    fi
    # Prefer a pinned duckdb on mise shims when the host has one; bin/duck's
    # version pin still enforces the requirement.
    if [ -d "$HOME/.local/share/mise/shims" ]; then
        export PATH="$HOME/.local/share/mise/shims:$PATH"
    fi
    # Compile runs match a real build's memory envelope; bin/duck defaults to 4GB,
    # which is not enough for the opencode adapter (it floored a real build too).
    export VARVE_MEMORY_LIMIT="${VARVE_MEMORY_LIMIT:-8GB}"
    engine="{{VARVE_ENGINE}}"
    data="{{VARVE_DATA}}"
    duck="$engine/bin/duck"
    prelude="$engine/sql/prelude.sql"
    failed=0
    for f in adapters/*.sql; do
        name="$(basename "$f" .sql)"
        dir="$data/mirror/$name"
        if [ ! -d "$dir" ]; then
            echo "  $name: SKIP (no mirror at $dir)"
            continue
        fi
        if ! out=$("$duck" "compile $name" -noheader -list \
                -c "SET VARIABLE mirror_dir='$dir';" \
                -f "$prelude" -f "$f" \
                -c "SELECT 'adapter=$name table=stg_sessions rows='||count(*) FROM stg_sessions" \
                -c "SELECT 'adapter=$name table=stg_messages rows='||count(*) FROM stg_messages" \
                -c "SELECT 'adapter=$name table=stg_api_calls rows='||count(*) FROM stg_api_calls" \
                -c "SELECT 'adapter=$name table=stg_tool_calls rows='||count(*) FROM stg_tool_calls" 2>&1); then
            echo "  $name: FAIL"
            printf '%s\n' "$out" | sed 's/^/    /'
            failed=1
        else
            printf '%s\n' "$out" | sed 's/^/    /'
        fi
    done
    if [ "$failed" -ne 0 ]; then
        echo "adapter compile check: FAILED"
        exit 1
    fi
    echo "adapter compile check: OK"
