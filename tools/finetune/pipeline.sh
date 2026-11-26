#!/usr/bin/env bash
# tools/finetune/pipeline.sh — the unattended run: train both 12B co-chatter
# LoRAs one after the other, then register each in Ollama on top of the
# model it was trained for. Everything logs to E:/MMA-train/logs/.
#
#   bash tools/finetune/pipeline.sh            (after both base downloads finish)
set -u
ROOT="D:/Software/Dev/Chatting/MMA"
PY="$ROOT/src/services/autoword/.venv/Scripts/python.exe"
BASE="E:/MMA-train/base"
LOGS="E:/MMA-train/logs"
MODELS="$ROOT/userdata/corpus/models"
export PYTHONIOENCODING=utf-8 PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

wait_for() {           # a download log ends with exit=0 when it is complete
  until grep -q "exit=0" "$1" 2>/dev/null; do
    grep -q "exit=[1-9]" "$1" 2>/dev/null && { echo "download failed: $1"; return 1; }
    sleep 60
  done
}

run() {                # run NAME BASE_DIR FORMAT OLLAMA_BASE
  local name=$1 base=$2 fmt=$3 obase=$4 out="$MODELS/$1"
  echo "== $(date +%H:%M) training $name"
  ollama stop "$obase" >/dev/null 2>&1   # free the GPU
  "$PY" "$ROOT/tools/finetune/train_lora.py" --base "$base" --format "$fmt" --out "$out" \
      > "$LOGS/train_$name.log" 2>&1 || { echo "training $name FAILED, see $LOGS/train_$name.log"; return 1; }
  printf 'FROM %s\nADAPTER %s\n' "$obase" "$out" > "$out/Modelfile"
  ollama create "$name" -f "$out/Modelfile" > "$LOGS/ollama_$name.log" 2>&1 \
      && echo "== $(date +%H:%M) $name registered in Ollama" \
      || echo "ollama create $name FAILED, see $LOGS/ollama_$name.log"
}

wait_for "$LOGS/dl_nemo.log" && run mistral-nemo-silly "$BASE/mistral-nemo-2407-bnb4" mistral mistral-nemo:12b
wait_for "$LOGS/dl_rocinante.log" && run rocinante-silly "$BASE/rocinante-12b-v1.1" chatml rocinante:latest
echo "== $(date +%H:%M) pipeline finished"
