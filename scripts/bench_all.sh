#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
bash "$DIR/bench_llm.sh"
echo
bash "$DIR/bench_voicevox.sh"
