#!/usr/bin/env bash
# SEKTOR7 pilot token-leak scanner — the quiet O3 detection procedure.
#
# Scans the given paths for the daemon bearer-token VALUE and reports ONLY a
# status: clean / match / error. It never prints matching lines, file names of
# matches, or the secret value itself (grep -q). The token value is read from
# the token file into a shell variable and never echoed.
#
# usage: token-scan.sh [TOKEN_FILE] [PATH...]
#   default TOKEN_FILE: ~/.qwen-serve-token
#   default PATHs: the pilot dir, the orchestrator state dir, the orchestrator
#                  sources, and the coordination review documents
# exit: 0 = clean · 1 = MATCH (the value is present — treat as T5, immediate
#         rollback class) · 2 = error (unreadable token file / scan error)
set -u

TOKEN_FILE="${1:-$HOME/.qwen-serve-token}"
if [ $# -gt 1 ]; then shift; TARGETS=("$@"); else
  TARGETS=("$HOME/.qwen/sektor7-coordination/pilot" \
           "$HOME/.qwen/sektor7-coordination/orchestrator/state" \
           "$HOME/.qwen/sektor7-coordination/orchestrator" \
           "$HOME/.qwen/sektor7-coordination"/*.md)
fi

if [ ! -r "$TOKEN_FILE" ]; then
  echo "ERROR: the token file is unreadable: $TOKEN_FILE"
  exit 2
fi
TOK="$(cat "$TOKEN_FILE")"
if [ -z "$TOK" ]; then
  echo "ERROR: the token file is empty: $TOKEN_FILE"
  exit 2
fi

grep -rFq -- "$TOK" "${TARGETS[@]}" 2>/dev/null
rc=$?
case "$rc" in
  0) echo "MATCH: the token value is present in the scanned tree (T5 — immediate rollback class; locations suppressed)"
     exit 1 ;;
  1) echo "clean: the token value is absent from the scanned tree"
     exit 0 ;;
  *) echo "ERROR: the scan itself failed (unreadable target or internal error) — investigate before relying on this result"
     exit 2 ;;
esac
