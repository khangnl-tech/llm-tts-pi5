# LLM (TinyLlama) + TTS tiếng Nhật (VOICEVOX) trên Mac M1 (ARM64) bằng Docker Compose

Triển khai trợ lý ảo chạy local gồm:

- **LLM**: llama.cpp server (TinyLlama 1.1B, định dạng GGUF).
- **TTS**: VOICEVOX Engine (CPU, ARM64) cho tiếng Nhật.

Thiết lập nhằm mô phỏng tương đối Raspberry Pi 5 (ARM64) trên Mac M1.

## 1) Yêu cầu

- macOS trên Apple Silicon (M1/M2).
- Docker Desktop (chạy ARM64).
- Công cụ CLI khuyến nghị: `curl`, `jq`, `bc`, `ffmpeg` (cài bằng Homebrew nếu cần).

## 2) Cấu trúc thư mục

```bash
llm-tts/
├─ .env                   # biến môi trường (threads, context, tag image…)
├─ docker-compose.yml     # định nghĩa services: llama + voicevox
├─ models/                # đặt file TinyLlama *.gguf (nếu không dùng --hf-*)
└─ scripts/
   ├─ bench_llm.sh        # đo latency & tokens/s cho llama.cpp
   ├─ bench_voicevox.sh   # đo thời gian synth & RTF của VOICEVOX
   └─ bench_all.sh        # chạy cả 2 benchmark
```


## 3) Biến môi trường (.env)

Các biến chính (ví dụ):

- `LLAMA_THREADS`: số luồng CPU cho LLM (mặc định 4).
- `LLAMA_CTX`: context window (mặc định 2048).
- `LLAMA_IMAGE`: image llama.cpp server (multi-arch).
- `VOICEVOX_IMAGE`: image VOICEVOX Engine (multi-arch/ARM64).

Bạn có thể “pin” đúng phiên bản bằng cách thay tag bằng digest (image@sha256:...) sau khi `docker compose pull`.

## 4) Docker Compose

Compose tạo 2 service:

### voicevox

- **Kiến trúc**: linux/arm64/v8.
- **Cổng mặc định**: 50021 (REST API: `/speakers`, `/audio_query`, `/synthesis`).
- **Command**: Không cần override command.

### llama

- **Kiến trúc**: linux/arm64/v8.
- **Cổng mở**: 10000 cho HTTP server (OpenAI-compatible).
- **Mount**: Mount thư mục `./models` để đọc file GGUF.
- **Command**: Chỉ truyền tham số cho llama-server (đừng lặp lại `/app/llama-server` trong command).
- **Healthcheck**: Đã cấu hình sẵn để chờ engine/model sẵn sàng.

## 5) Chuẩn bị model TinyLlama

Chọn một file GGUF đã lượng tử (khuyên dùng Q4_K_M để cân bằng tốc độ/chất lượng) và đặt vào `./models/`, ví dụ:

```bash
models/TinyLlama-1.1B-Chat-v1.0.Q4_K_M.gguf
```

Tuỳ chọn: Có thể cấu hình llama dùng `--hf-repo`/`--hf-file` để tự tải model lần đầu (sẽ lâu hơn; healthcheck đã nới thời gian).

## 6) Khởi động & kiểm tra

### Docker Compose

```bash
docker compose pull
docker compose up -d
docker compose ps
```

### VOICEVOX – kiểm tra nhanh

```bash
# danh sách speakers
curl -s http://localhost:50021/speakers | jq '.[].name'

# synth 2 bước: audio_query → synthesis
echo -n "おはようございます。" > text.txt
curl -s -X POST "http://127.0.0.1:50021/audio_query?speaker=1" \
     -H "Content-Type: application/json" \
     --data "{\"text\":\"$(cat text.txt)\"}" > query.json

curl -s -X POST "http://localhost:50021/synthesis?speaker=1" \
     -H "Content-Type: application/json" \
     -d @query.json -o voice.wav

# mở file
open voice.wav
```

### LLM – kiểm tra nhanh (OpenAI-compatible)

```bash
# Health
curl -s http://localhost:10000/health

# Models
curl -s http://localhost:10000/v1/models | jq

# Chat Completions
curl -s http://localhost:10000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model":"tinyllama",
    "messages":[
      {"role":"system","content":"You are a helpful assistant."},
      {"role":"user","content":"簡単な日本語で自己紹介してください。"}
    ],
    "temperature":0.7
  }' | jq
```

## 7) Benchmark

Trong thư mục `scripts/` đã có sẵn:

- `bench_llm.sh`: đo latency & tokens/s cho TinyLlama.
- `bench_voicevox.sh`: đo thời gian synth & RTF (Real-Time Factor).
- `bench_all.sh`: chạy cả hai.

Chạy:

```bash
chmod +x scripts/bench_*.sh
./scripts/bench_all.sh
```

**Diễn giải nhanh:**

- **LLM**: quan sát Latency & Tokens/sec (ước lượng).
- **VOICEVOX**: RTF < 1.0 nghĩa là synth nhanh hơn thời gian thực.

## 8) Lệnh tiện dụng

```bash
# Khởi động (pull + up)
docker compose pull && docker compose up -d

# Log theo dịch vụ
docker compose logs -f voicevox
docker compose logs -f llama

# Dừng & xoá stack (kèm volumes)
docker compose down -v

# Dọn rác Docker (cẩn trọng: xoá image/cache/volumes không dùng)
docker system prune -af --volumes
```

**Ghi chú:** Mac M1 mạnh hơn Pi 5, vì vậy benchmark dùng để so sánh tương đối khi ước lượng hiệu năng trên Pi 5 thực tế. Nếu cần thêm UI chat (OpenWebUI) hoặc ASR (Whisper.cpp), bạn có thể mở rộng `docker-compose.yml` tương ứng.
