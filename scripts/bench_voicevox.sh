#!/usr/bin/env bash
set -euo pipefail

HOST="${1:-http://localhost:50021}"
TEXT="${2:-"おはようございます。本日は天気が良く、散歩するのに最適です。"}"
SPEAKER="${3:-1}"   # thử các ID khác nếu muốn
OUT="${4:-voice.wav}"

# audio_query
START=$(date +%s.%N)
QUERY=$(curl -s -X POST "$HOST/audio_query?speaker=${SPEAKER}" \
  -H "Content-Type: application/json" \
  --data "{\"text\":\"$TEXT\"}")
# synthesis
curl -s -X POST "$HOST/synthesis?speaker=${SPEAKER}" \
  -H "Content-Type: application/json" -d "$QUERY" -o "$OUT"
END=$(date +%s.%N)

ELAPSED=$(echo "$END - $START" | bc)

# Độ dài file audio (giây) để tính RTF
DUR=$(ffprobe -v error -of csv=p=0 -show_entries format=duration "$OUT" 2>/dev/null || echo "0")
RTF="n/a"
if [ "$DUR" != "N/A" ] && [ -n "$DUR" ]; then
  RTF=$(echo "scale=2; $ELAPSED / $DUR" | bc)
fi

echo "=== VOICEVOX Benchmark ==="
echo "Text length (chars): ${#TEXT}"
echo "Synthesis time (s):  $ELAPSED"
echo "Audio duration (s):  $DUR"
echo "Real-time factor:    $RTF  ( <1.0 là nhanh hơn thời gian thực )"
echo "Output file:         $OUT"
