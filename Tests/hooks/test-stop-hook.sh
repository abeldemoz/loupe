#!/usr/bin/env bash
# Tests hooks/loupe-stop-hook.sh against a fake `loupe` and a scratch git repository.
set -u
hook="$(cd "$(dirname "$0")/../../hooks" && pwd)/loupe-stop-hook.sh"
failures=0

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/repo"

# A fake loupe whose exit status and output come from the environment.
cat > "$scratch/bin/loupe" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$LOUPE_CALLS"
echo "${FAKE_OUTPUT:-}"
exit "${FAKE_STATUS:-0}"
FAKE
chmod +x "$scratch/bin/loupe"

cd "$scratch/repo" || exit 1
git init -q -b main
git -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
export CLAUDE_PROJECT_DIR="$scratch/repo"
export LOUPE_CALLS="$scratch/calls"

# run <stdin> <expected status> <description> [expected stderr substring]
run() {
    : > "$LOUPE_CALLS"
    stderr="$(printf '%s' "$1" | PATH="$scratch/bin:$PATH" "$hook" Client 2>&1 >/dev/null)"
    status=$?
    if [ "$status" -ne "$2" ]; then
        echo "FAIL: $3 (exit $status, wanted $2)"; failures=$((failures + 1)); return
    fi
    if [ -n "${4:-}" ] && ! printf '%s' "$stderr" | grep -qF -- "$4"; then
        echo "FAIL: $3 (stderr lacks: $4)"; failures=$((failures + 1)); return
    fi
    echo "ok:   $3"
}

called() { [ -s "$LOUPE_CALLS" ]; }

# 1. Nothing changed: loupe is not even run.
run '{}' 0 "clean tree does nothing"
called && { echo "FAIL: clean tree ran loupe"; failures=$((failures + 1)); }

# 2. A non-Swift change: still nothing.
echo hi > notes.txt
run '{}' 0 "non-Swift changes do nothing"
called && { echo "FAIL: non-Swift change ran loupe"; failures=$((failures + 1)); }

# 3. A Swift change and a passing loupe.
echo 'struct A {}' > A.swift
FAKE_STATUS=0 run '{}' 0 "swift change, no violations"
called || { echo "FAIL: loupe was not run"; failures=$((failures + 1)); }
grep -qx 'check Client' "$LOUPE_CALLS" || { echo "FAIL: wrong arguments: $(cat "$LOUPE_CALLS")"; failures=$((failures + 1)); }

# 4. Violations block the stop and the report reaches the agent.
FAKE_STATUS=1 FAKE_OUTPUT='A.swift:1:1: error: [interface-function] x' run '{}' 2 "violations block with the report" "[interface-function]"
FAKE_STATUS=1 FAKE_OUTPUT='x' run '{}' 2 "violations tell the agent not to add allows unasked" "Do not add a loupe:allow comment"

# 5. Already continuing because of this hook: never loop.
FAKE_STATUS=1 run '{"stop_hook_active": true}' 0 "stop_hook_active never blocks again"
FAKE_STATUS=1 run '{"stop_hook_active":true}' 0 "stop_hook_active (compact JSON)"

# 6. Loupe could not run: surfaced, but not blocking.
FAKE_STATUS=2 FAKE_OUTPUT='bad config' run '{}' 1 "a run error is non-blocking" "bad config"

# 7. A manifest-only change counts through its .swift suffix; a .loupe.json change counts too.
git add -A && git -c user.name=t -c user.email=t@example.com commit -q -m two
echo '{}' > .loupe.json
FAKE_STATUS=1 run '{}' 2 ".loupe.json changes trigger a check"

# 8. Not installed: nothing to enforce.
: > "$LOUPE_CALLS"
stderr="$(printf '{}' | PATH="/usr/bin:/bin" "$hook" Client 2>&1)"; status=$?
if [ "$status" -eq 0 ]; then echo "ok:   loupe not installed does nothing"; else echo "FAIL: loupe not installed (exit $status)"; failures=$((failures + 1)); fi

if [ "$failures" -ne 0 ]; then echo "$failures failure(s)"; exit 1; fi
echo "all hook tests passed"
