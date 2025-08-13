# Local Japanese Voice Assistant Pipeline

A fully local voice assistant pipeline that combines ASR (Automatic Speech Recognition), LLM (Language Model), and TTS (Text-to-Speech) for Japanese language interaction.

## Overview

This project implements a complete pipeline for:
1. Converting Japanese speech to text (ASR)
2. Processing the text through a language model (LLM)
3. Converting the response back to Japanese speech (TTS)

## Technologies

- **ASR**: Whisper (for speech recognition)
- **LLM**: TinyLlama-1.1B (served via llama.cpp server)
- **TTS**: VOICEVOX (Japanese speech synthesis)

## Project Structure
```
.
├─ docker-compose.yml
├─ models/                    # TinyLlama GGUF model storage
│  └─ tinyllama.Q4_K_M.gguf  # Recommended: Q4_K_M variant
├─ asr_models/               # Whisper ASR model cache
└─ scripts/                  # Test scripts
```

## Requirements

- Docker Desktop with Compose v2
- ffmpeg (for audio processing)
- curl, python3 (for testing)

## Services and Ports

| Service   | Role | Port  |
|-----------|------|-------|
| llama     | LLM  | 10000 |
| asr       | ASR  | 9000  |
| voicevox  | TTS  | 50021 |

## Quick Start

1. Download TinyLlama GGUF model (Q4_K_M variant recommended) and place it in `./models/`

2. Start the services:
```bash
docker compose pull
docker compose up -d
```

3. Test the complete pipeline:
```bash
# Make the test script executable
chmod +x run_jp_voice_pipeline.sh

# Run with 8-second recording duration
./run_jp_voice_pipeline.sh -t 8
```

When running the test:
- Speak in Japanese for 8 seconds
- The console will display:
  1. Speech recognition results (ASR)
  2. Language model response (LLM)
  3. Speech synthesis progress (TTS)

## Cleanup
```bash
# Stop services while keeping data
docker compose down

# Complete cleanup (including images and volumes)
docker compose down --rmi all --volumes --remove-orphans
