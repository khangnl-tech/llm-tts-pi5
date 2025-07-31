LLM + ASR + TTS (JP) — Docker Stack (macOS/M1)

## Mục đích
Triển khai nhanh một trợ lý thoại chạy hoàn toàn local gồm:

- **LLM** (TinyLlama-1.1B, phục vụ qua llama.cpp server)
- **ASR** (Whisper webservice – nhận dạng giọng nói)
- **TTS** (VOICEVOX – tổng hợp tiếng Nhật)

### Lưu ý kiến trúc/kiểu máy:
- Chỉ service llama chạy với platform: linux/amd64 (dùng emulation trên Mac M1).
- Hai service còn lại (asr và voicevox) chạy platform: linux/arm64/v8.

## 1) Yêu cầu phần mềm
- **macOS** (Apple Silicon M1/M2)
- **Docker Desktop** (Compose v2 đi kèm)
  - Bật emulation cho x86/amd64: Settings → Features in development → Use Rosetta for x86/amd64 emulation on Apple Silicon (hoặc tương đương trong phiên bản Docker của bạn).
- **ffmpeg** (để chuẩn hoá tần số mẫu audio khi test ASR)
  - Cài bằng Homebrew: `brew install ffmpeg`
- **curl, python3** (tùy chọn, dùng cho ví dụ lệnh test)

## 2) Cấu trúc dự án
```
.
├─ docker-compose.yml
├─ models/                    # chứa GGUF của TinyLlama
│  └─ tinyllama.Q4_K_M.gguf  # (đặt tên tuỳ bạn)
├─ asr_models/                # cache model cho Whisper ASR (để khởi động nhanh)
└─ scripts/                   # (tuỳ chọn) script test end-to-end
```

Chuẩn bị model LLM: tải file GGUF của TinyLlama (khuyến nghị biến thể Q4_K_M), đặt vào `./models/` và trùng tên với tham số `-m` trong `docker-compose.yml`.

## 3) Dịch vụ và cổng
| Service | Vai trò | Ảnh Docker (gợi ý) | Platform | Cổng mặc định |
|---------|---------|---------------------|----------|---------------|
| llama   | LLM     | ghcr.io/ggml-org/llama.cpp:server | linux/amd64 | 10000 |
| asr     | ASR     | lsxw/whisper-asr-webservice:latest | linux/arm64/v8 | 9000 |
| voicevox| TTS (JP)| voicevox/voicevox_engine:cpu-ubuntu24.04-latest | linux/arm64/v8 | 50021 |

Đừng đặt platform ở mức top-level compose. Chỉ set theo từng service như trên để tránh xung đột kiến trúc.

## 4) Khởi chạy
### Kéo ảnh và khởi động stack
```bash
docker compose pull
docker compose up -d
```

### Kiểm tra trạng thái
```bash
docker compose ps
docker compose logs -f llama
docker compose logs -f asr
docker compose logs -f voicevox
```

### Health-check nhanh

**Llama:**
```bash
curl -fsS http://localhost:10000/health
```

**ASR (trang tài liệu):**
```bash
curl -I http://localhost:9000/docs
```

**VOICEVOX (danh sách speakers):**
```bash
curl -fsS http://localhost:50021/speakers
```

## 5) Test từng thành phần
### 5.1 TTS (VOICEVOX → WAV tiếng Nhật)
```bash
TEXT='こんにちは。テストです。'
ENC=$(python3 - <<'PY'
import urllib.parse,sys
print(urllib.parse.quote(sys.argv[1]))
PY
"$TEXT")

# audio_query → synthesis
curl -fsS -X POST "http://localhost:50021/audio_query?text=$ENC&speaker=1" \
  -H "Content-Type: application/json" -d '{}' > /tmp/q.json

curl -fsS -X POST "http://localhost:50021/synthesis?speaker=1" \
  -H "Content-Type: application/json" -d 'tmp/q.json' -o /tmp/ja.wav

# Có thể nghe thử trên macOS:
afplay /tmp/ja.wav
```

### 5.2 ASR (Whisper – nhận dạng tiếng Nhật)
**Chuẩn hoá audio về 16kHz/mono PCM16 trước khi gửi:**
```bash
ffmpeg -y -i /tmp/ja.wav -ar 16000 -ac 1 -c:a pcm_s16le /tmp/ja16.wav
```

**Gửi lên ASR:**
```bash
curl -v http://localhost:9000/asr \
  -F task=transcribe \
  -F language=ja \
  -F audio_file='tmp/ja16.wav'
```

Nếu kết quả không chính xác với tiếng Nhật, nâng `ASR_MODEL` lên `base` hoặc `small` trong compose, sau đó `docker compose up -d asr` để áp dụng.

### 5.3 LLM (llama.cpp server)
**Completion API (đơn giản):**
```bash
curl -fsS http://localhost:10000/completion \
  -H "Content-Type: application/json" \
  -d '{"prompt":"日本語で自己紹介をしてください。","n_predict":256}'
```

**(Tuỳ bản server) OpenAI-like chat:**
```bash
curl -fsS http://localhost:10000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model":"tinyllama",
    "messages":[{"role":"user","content":"日本語で自己紹介をしてください。"}],
    "max_tokens":256
  }'
```

## 6) (Tuỳ chọn) Test vòng kín ASR → LLM → TTS
```bash
cat > /tmp/pipeline.sh <<'SH'
set -euo pipefail

# 1) ASR (giả sử đã có /tmp/ja16.wav)
JSON=$(curl -fsS http://localhost:9000/asr \
  -F task=transcribe -F language=ja -F audio_file='tmp/ja16.wav')
echo "[ASR] $JSON"
USER_TEXT="$JSON"   # server này thường trả plain text

# 2) Gọi LLM
LLM_JSON=$(curl -fsS http://localhost:10000/completion \
  -H "Content-Type: application/json" \
  -d "{\"prompt\":\"以下はユーザーの入力です。これに自然に日本語で返答してください：\\n$USER_TEXT\",\"n_predict\":256}")
echo "[LLM] $LLM_JSON"

REPLY_JA=$(python3 - <<'PY'
import json,sys
s=sys.stdin.read()
try:
  j=json.loads(s)
  if "content" in j: print(j["content"])
  elif "choices" in j and j["choices"]:
    c=j["choices"][0]
    print(c.get("text", c.get("content","")))
  else:
    print("")
except:
  print("")
PY
<<<"$LLM_JSON")

echo "[REPLY_JA] $REPLY_JA"

# 3) TTS bằng VOICEVOX
ENC=$(python3 - <<'PY'
import urllib.parse,sys
print(urllib.parse.quote(sys.argv[1]))
PY
"$REPLY_JA")

curl -fsS -X POST "http://localhost:50021/audio_query?text=$ENC&speaker=1" \
  -H "Content-Type: application/json" -d '{}' > /tmp/q_llm.json

curl -fsS -X POST "http://localhost:50021/synthesis?speaker=1" \
  -H "Content-Type: application/json" -d 'tmp/q_llm.json' -o /tmp/reply.wav

# Phát trên macOS
afplay /tmp/reply.wav
SH

bash /tmp/pipeline.sh
```

## 7) Gợi ý cấu hình & mô phỏng Pi 5 (8 GB)
Trong `docker-compose.yml`, có thể giới hạn tài nguyên để gần với Pi 5:

```yaml
deploy:
  resources:
    limits:
      cpus: "4.0"     # Pi 5 ~4 cores
      memory: "6g"    # chừa headroom cho OS & cache
```

Áp dụng cho từng service (nhất là llama và asr). Trên Docker Desktop, phần deploy có tác dụng ở chế độ Compose hiện đại (không phải Swarm); nếu không, cân nhắc dùng `cpus:` và `mem_limit:` ở phần `services.<name>`.

**llama:**
- **Model**: TinyLlama 1.1B Q4_K_M
- **Tham số gợi ý**: `-t 4` (threads), `--parallel 2`, `-c 2048`.

**asr (Whisper):**
- `ASR_MODEL=tiny/base/small` (JP tốt hơn với small), `COMPUTE_TYPE=int8`.

**voicevox:**
- CPU dùng khoảng 0.8–1.5 GB khi tổng hợp; chọn speaker phù hợp (ví dụ 1).

## 8) Dừng & dọn dẹp
```bash
# Dừng nhưng giữ dữ liệu (cache, models)
docker compose down

# Dọn toàn bộ container + ảnh (cẩn thận!)
docker compose down --rmi all --volumes --remove-orphans
