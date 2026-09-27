#!/usr/bin/env bash
# Kept for familiarity — the real builder is build.sh, which CI uses too.
_self="${BASH_SOURCE[0]:-$0}"
exec "$(cd "$(dirname "$_self")" && pwd)/build.sh" "$@"
