#!/usr/bin/env bash
# MIC (Japanese) -> ASR (ja) -> LLM (non-stream, ja) -> VOICEVOX (ja) -> Speaker
# Requirements: docker compose up -d (asr, llama, voicevox), ffmpeg, curl, jq
# macOS: uses avfoundation + afplay. Linux: ffplay/paplay/aplay if available.

set -euo pipefail

# ========= CONFIG =========
DURATION="${DURATION:-10}"            # recording duration in seconds if not using --hold
SPEAKER_ID="${SPEAKER_ID:-1}"         # VOICEVOX speaker id (see /speakers)
REC_DEVICE="${REC_DEVICE:-:0}"        # macOS (avfoundation): ":0" = default mic
ASR_URL="${ASR_URL:-http://localhost:9000/asr}"
LLM_URL="${LLM_URL:-http://localhost:10000/completion}"
VVX_Q_URL="${VVX_Q_URL:-http://localhost:50021/audio_query}"
VVX_S_URL="${VVX_S_URL:-http://localhost:50021/synthesis}"
N_PREDICT="${N_PREDICT:-256}"         # max tokens to generate

# ========= FILES =========
IN_RAW="/tmp/jp_mic_raw.wav"
IN_16K="/tmp/jp_mic_16k.wav"
VVX_Q="/tmp/vvx_query.json"
OUT_WAV="/tmp/jp_reply.wav"
LOG_TXT="/tmp/jp_pipeline_timing.log"
LOG_CSV="/tmp/jp_pipeline_timing.csv"
LLM_JSON_PATH="/tmp/jp_llm_raw.json"
ASR_TEXT_PATH="/tmp/jp_asr_text.txt"
REPLY_TEXT_PATH="/tmp/jp_reply_text.txt"
LLM_METRICS_CSV="/tmp/jp_llm_metrics.csv"

# ========= COLORS & UTILS =========
C_RESET=$'\033[0m'; C_HDR=$'\033[1;36m'; C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'

now_ms() {
  python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1. Please install and retry."; exit 1; }; }
section() { echo; echo "${C_HDR}==== $1 ====${C_RESET}"; }
log_step() { # $1=step $2=dur_ms
  local ts
  ts=$(now_ms)
  printf "%s | %-18s : %6d ms\n" "$(date '+%F %T')" "$1" "$2" | tee -a "$LOG_TXT" >/dev/null
  echo "${ts},${1},${2}" >> "$LOG_CSV"
}

# ========= ARGS =========
usage() {
cat <<EOF
Usage: $0 [-t seconds] [-s speaker_id] [-i rec_device] [--hold]
  -t   Recording duration in seconds (default: ${DURATION})
  -s   VOICEVOX speaker id (default: ${SPEAKER_ID})
  -i   Mic device (macOS avfoundation), e.g. ':0' or ':1' (default: ${REC_DEVICE})
  --hold  Hold-to-record mode: start recording and stop when you press ENTER

Tip (macOS): list input devices:
  ffmpeg -f avfoundation -list_devices true -i ""
EOF
}
HOLD_MODE="0"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t) DURATION="$2"; shift 2 ;;
    -s) SPEAKER_ID="$2"; shift 2 ;;
    -i) REC_DEVICE="$2"; shift 2 ;;
    --hold) HOLD_MODE="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

# ========= CHECKS =========
need ffmpeg; need curl; need jq
if [[ "$OSTYPE" == "darwin"* ]]; then command -v afplay >/dev/null 2>&1 || true; fi
: > "$LOG_TXT"
[[ -f "$LOG_CSV" ]] || echo "timestamp_ms,step,duration_ms" > "$LOG_CSV"
[[ -f "$LLM_METRICS_CSV" ]] || echo "timestamp_ms,prompt_tokens,completion_tokens,total_tokens,tok_per_sec,prompt_ms,pred_ms" > "$LLM_METRICS_CSV"

# ========= WAIT SERVICES =========
wait_up() { # $1=url  $2=name
  local url="$1" name="$2"
  echo "⏳ Checking $name at $url ..."
  for _ in {1..30}; do
    if curl -fsS -o /dev/null "$url"; then
      echo "✅ $name is ready."
      return 0
    fi
    sleep 1
  done
  echo "❌ Unable to reach $name at $url"; exit 1
}
PIPE_START=$(now_ms)
wait_up "http://localhost:9000/docs"       "ASR (Whisper)"
wait_up "http://localhost:10000/health"    "LLM (llama.cpp)"
wait_up "http://localhost:50021/speakers"  "VOICEVOX"

trap 'rm -f "$IN_RAW" "$IN_16K" "$VVX_Q" 2>/dev/null || true' EXIT

# ========= RECORD =========
section "RECORDING"
echo "🎙 Mic device: ${REC_DEVICE}"
REC_START=$(now_ms)
if [[ "$HOLD_MODE" == "1" ]]; then
  echo "➡️  Hold-to-record: recording... (press ENTER to stop)"
  ffmpeg -loglevel error -f avfoundation -i "$REC_DEVICE" -ac 1 -ar 16000 -c:a pcm_s16le "$IN_16K" &
  FF_PID=$!; read -r; kill -INT "$FF_PID" || true; wait "$FF_PID" || true
else
  echo "➡️  Recording for ${DURATION}s ..."
  ffmpeg -loglevel error -f avfoundation -i "$REC_DEVICE" -t "$DURATION" "$IN_RAW"
  ffmpeg -loglevel error -y -i "$IN_RAW" -ac 1 -ar 16000 -c:a pcm_s16le "$IN_16K"
fi
REC_END=$(now_ms); log_step "record" "$((REC_END-REC_START))"
echo "${C_OK}✔ Recorded audio:${C_RESET} $IN_16K"

# ========= ASR (Japanese) =========
section "ASR → TEXT (Japanese)"
ASR_START=$(now_ms)
ASR_TEXT="$(curl -fsS -X POST "$ASR_URL" -F task=transcribe -F language=ja -F "audio_file=@${IN_16K}")"
ASR_END=$(now_ms); log_step "asr_transcribe" "$((ASR_END-ASR_START))"
ASR_TEXT="$(echo "$ASR_TEXT" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
echo "$ASR_TEXT" | tee "$ASR_TEXT_PATH" >/dev/null
if [[ -z "$ASR_TEXT" ]]; then echo "❌ ASR returned empty text."; exit 1; fi
echo "${C_OK}✔ TRANSCRIBE (ja):${C_RESET} $ASR_TEXT"
echo "↳ Saved: $ASR_TEXT_PATH"

# ========= LLM (Japanese, non-stream) =========
section "LLM → REPLY (Japanese)"
PROMPT="以下はユーザーの入力です。これに自然に日本語で返答してください：\n${ASR_TEXT}"

# llama.cpp /completion in non-stream mode to get full JSON with usage/timings (if available)
LLM_REQ="$(jq -n --arg p "$PROMPT" --argjson n "$N_PREDICT" \
  '{prompt:$p, n_predict:$n, stream:false, temperature:0.7, cache_prompt:true}')"

LLM_START=$(now_ms)
LLM_JSON="$(curl --retry 2 --retry-connrefused --max-time 120 \
  -fsS "$LLM_URL" -H "Content-Type: application/json" -d "$LLM_REQ")"
LLM_END=$(now_ms); LLM_DUR_MS=$((LLM_END-LLM_START))
log_step "llm_completion" "$LLM_DUR_MS"

# Save raw JSON (for debugging)
echo "$LLM_JSON" | jq . > "$LLM_JSON_PATH" || echo "$LLM_JSON" > "$LLM_JSON_PATH"

# Extract reply (support multiple llama.cpp/OpenAI-like formats)
REPLY_JA="$(echo "$LLM_JSON" | jq -r '
  .content // .completion // (.choices[0].text // .choices[0].message.content // empty)
')"
if [[ -z "$REPLY_JA" || "$REPLY_JA" == "null" ]]; then
  echo "⚠️ Could not extract reply from LLM. Raw JSON saved to: $LLM_JSON_PATH"
  exit 1
fi
echo "$REPLY_JA" | tee "$REPLY_TEXT_PATH" >/dev/null
echo "${C_OK}✔ LLM REPLY (ja):${C_RESET} $REPLY_JA"
echo "↳ Saved raw JSON: $LLM_JSON_PATH"
echo "↳ Saved reply txt: $REPLY_TEXT_PATH"

# ------- LLM metrics (tokens & speed) -------
PROMPT_TOK="$(echo "$LLM_JSON" | jq -r '.usage.prompt_tokens // .tokens_evaluated // empty')"
COMP_TOK="$(echo "$LLM_JSON" | jq -r '.usage.completion_tokens // .tokens_generated // .tokens_predicted // empty')"
TOTAL_TOK="$(echo "$LLM_JSON" | jq -r '.usage.total_tokens // ( ( .usage.prompt_tokens // 0 ) + ( .usage.completion_tokens // 0 ) ) // empty')"
P_MS="$(echo "$LLM_JSON" | jq -r '.timings.prompt_ms // empty')"
C_MS="$(echo "$LLM_JSON" | jq -r '.timings.predicted_ms // .timings.completion_ms // empty')"
TOK_PER_SEC="$(echo "$LLM_JSON" | jq -r '.timings.predicted_per_second // .timings.tokens_per_second // empty')"

# Fallbacks if server doesn't return usage/timings:
if [[ -z "$COMP_TOK" || "$COMP_TOK" == "null" ]]; then
  # very rough estimate using whitespace-separated "words"
  COMP_TOK=$(echo "$REPLY_JA" | wc -w | awk '{print $1}')
fi
if [[ -z "$TOK_PER_SEC" || "$TOK_PER_SEC" == "null" ]]; then
  if [[ "$LLM_DUR_MS" -gt 0 ]]; then
    TOK_PER_SEC=$(python3 - <<PY
import sys
dur_ms=int("$LLM_DUR_MS")
try:
  comp=int("$COMP_TOK")
except:
  comp=0
print(f"{(comp/(dur_ms/1000)):.2f}" if dur_ms>0 and comp>0 else "")
PY
)
  fi
fi
if [[ -z "$TOTAL_TOK" || "$TOTAL_TOK" == "null" ]]; then
  if [[ -n "${PROMPT_TOK:-}" && "$PROMPT_TOK" != "null" ]] && [[ -n "${COMP_TOK:-}" && "$COMP_TOK" != "null" ]]; then
    TOTAL_TOK=$(( ${PROMPT_TOK:-0} + ${COMP_TOK:-0} ))
  fi
fi

echo
echo "📊 LLM metrics:"
[[ -n "${PROMPT_TOK:-}" && "$PROMPT_TOK" != "null" ]] && echo "  • prompt_tokens     : $PROMPT_TOK"
[[ -n "${COMP_TOK:-}"   && "$COMP_TOK"   != "null" ]] && echo "  • completion_tokens : $COMP_TOK"
[[ -n "${TOTAL_TOK:-}"  && "$TOTAL_TOK"  != "null" ]] && echo "  • total_tokens      : $TOTAL_TOK"
[[ -n "${TOK_PER_SEC:-}" && "$TOK_PER_SEC" != "null" ]] && echo "  • tokens/sec        : $TOK_PER_SEC"
[[ -n "${P_MS:-}"       && "$P_MS"       != "null" ]] && echo "  • prompt_ms         : $P_MS"
[[ -n "${C_MS:-}"       && "$C_MS"       != "null" ]] && echo "  • predicted_ms      : $C_MS"

ts_now=$(now_ms)
echo "${ts_now},${PROMPT_TOK:-},${COMP_TOK:-},${TOTAL_TOK:-},${TOK_PER_SEC:-},${P_MS:-},${C_MS:-}" >> "$LLM_METRICS_CSV"

# ========= TTS (Japanese) =========
section "VOICEVOX → AUDIO (Japanese)"
# audio_query
VVQ_START=$(now_ms)
ENCODED_TEXT="$(jq -rn --arg s "$REPLY_JA" '$s|@uri')"
curl -fsS -X POST "${VVX_Q_URL}?text=${ENCODED_TEXT}&speaker=${SPEAKER_ID}" \
  -H "Content-Type: application/json" -d '{}' > "$VVX_Q"
VVQ_END=$(now_ms); log_step "tts_audio_query" "$((VVQ_END-VVQ_START))"
# synthesis
VVS_START=$(now_ms)
curl -fsS -X POST "${VVX_S_URL}?speaker=${SPEAKER_ID}" \
  -H "Content-Type: application/json" -d @"$VVX_Q" -o "$OUT_WAV"
VVS_END=$(now_ms); log_step "tts_synthesis" "$((VVS_END-VVS_START))"
echo "${C_OK}✔ WAV generated:${C_RESET} $OUT_WAV"

# ========= PLAYBACK =========
section "PLAYBACK"
PLAY_START=$(now_ms)
if command -v afplay >/dev/null 2>&1; then
  afplay "$OUT_WAV"
elif command -v ffplay >/dev/null 2>&1; then
  ffplay -autoexit -nodisp -loglevel error "$OUT_WAV"
elif command -v paplay >/dev/null 2>&1; then
  paplay "$OUT_WAV"
elif command -v aplay >/dev/null 2>&1; then
  aplay "$OUT_WAV"
else
  echo "${C_WARN}⚠️  No audio player found (afplay/ffplay/paplay/aplay).${C_RESET}"
  echo "Open the file manually: $OUT_WAV"
fi
PLAY_END=$(now_ms); log_step "playback" "$((PLAY_END-PLAY_START))"

# ========= SUMMARY =========
section "SUMMARY"
PIPE_END=$(now_ms)
TOTAL=$((PIPE_END-PIPE_START))
echo "⏱  Total time (ms): $TOTAL"
echo "📄 Timing log (txt): $LOG_TXT"
echo "📊 Timing log (csv): $LOG_CSV"
echo "📊 LLM metrics csv : $LLM_METRICS_CSV"
echo "🔹 ASR text        : $ASR_TEXT_PATH"
echo "🔹 LLM raw JSON    : $LLM_JSON_PATH"
echo "🔹 LLM reply (txt) : $REPLY_TEXT_PATH"
echo "🔹 TTS wav         : $OUT_WAV"
echo
echo "${C_OK}Done.${C_RESET}"
