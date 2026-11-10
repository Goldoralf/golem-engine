#!/bin/bash
# render_case.sh <signal.wav> <chain> <nam> <ir> <out.wav>
set -u
S=$(cd "$(dirname "$0")" && pwd); cd "$S/../.."; source golem/dev/env.sh
W=$(mktemp -d); N="lilv_\|^$\|Reasonable\|call-slot\|paths done"
timeout 60 build/luasession/luasession "$S/build_chain.lua" "$W/s" "$2" "$3" "$4" 2>&1 | grep -v "$N" | grep -i "error\|built"
timeout 60 build/golem/golem-place "$W/s" bench gtr "$1" 0 2>&1 | grep -v "$N" | grep -i "error\|fatal"
timeout 120 build/session_utils/golem-engine9-export -b float -o "$5" "$W/s" bench 2>&1 | grep -i "error\|fatal"
rm -rf "$W"; [ -s "$5" ] && echo "ok $5"
