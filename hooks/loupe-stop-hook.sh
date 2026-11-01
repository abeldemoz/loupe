#!/usr/bin/env bash
# Claude Code Stop hook: before an agent stops, run `loupe check` if it touched Swift code, and hand
# any violations back to it. Each violation says which rule broke and how to fix it.
#
# Usage (from .claude/settings.json):
#   "command": "\"$CLAUDE_PROJECT_DIR\"/scripts/loupe-stop-hook.sh <dir containing loupe.json>"
#
# Exit codes follow the hook contract: 0 lets the agent stop; 2 blocks the stop and shows stderr to the
# agent. Everything that isn't a rule violation is non-blocking, so this can never wedge a session.

set -u

directory="${1:-.}"
input="$(cat)"

# Claude sets this when it is already continuing because of a stop hook. Run once, never loop.
if printf '%s' "$input" | grep -Eq '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
    exit 0
fi

# Not installed (a machine without mise's tools, say): nothing to enforce here.
command -v loupe >/dev/null 2>&1 || exit 0

cd "${CLAUDE_PROJECT_DIR:-$PWD}" 2>/dev/null || exit 0

# Only sessions that touched Swift sources, a manifest or the config pay for a check.
git rev-parse --git-dir >/dev/null 2>&1 || exit 0
changed="$(
    { git diff --name-only HEAD 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null; } |
        grep -E '\.swift$|(^|/)loupe\.json$' || true
)"
[ -n "$changed" ] || exit 0

output="$(loupe check "$directory" 2>&1)"
status=$?

case "$status" in
    0)
        exit 0
        ;;
    1)
        {
            printf '%s\n' "$output"
            printf '\nloupe found architecture violations. Fix each one as its fix: line says, then run: loupe check %s\n' "$directory"
            printf 'Do not add a loupe:allow comment to make a violation go away without asking the user first.\n'
        } >&2
        exit 2
        ;;
    *)
        # Loupe itself could not run (bad loupe.json, a Package.swift that won't load). Say so, but
        # don't block: the agent may not be able to fix an environment problem.
        {
            printf 'loupe could not run (exit status %s):\n%s\n' "$status" "$output"
        } >&2
        exit 1
        ;;
esac
