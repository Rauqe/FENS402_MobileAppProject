#!/usr/bin/env bash
# Pi: ~/dispenser/pi_backend →  bash run_api.sh
#
# İlk sefer: venv oluşturur + pip kurar (uzun sürebilir).
# Sonraki her çalıştırma: mevcut .venv kullanılır, pip TEKRARLANMAZ (bekleme yok).
# Paketleri yeniden kurmak için:  FORCE_PIP=1 bash run_api.sh
set -e
cd "$(dirname "$0")"

STAMP=".venv/.deps_installed"

if [[ ! -d .venv ]]; then
  echo "[run_api] İlk kurulum: .venv oluşturuluyor..."
  python3 -m venv .venv
fi

# shellcheck disable=SC1091
source .venv/bin/activate

if [[ ! -f "$STAMP" ]] || [[ "${FORCE_PIP:-}" == "1" ]]; then
  echo "[run_api] pip install requirements-pi.txt (bir kez veya FORCE_PIP=1)..."
  pip install -q --upgrade pip
  pip install -q -r requirements-pi.txt
  mkdir -p .venv
  touch "$STAMP"
  echo "[run_api] Kurulum bitti. Bir daha pip çalışmayacak (FORCE_PIP=1 ile zorlayabilirsin)."
else
  echo "[run_api] Hazır venv kullanılıyor — pip atlandı (hızlı başlatma)."
fi

export FACES_DB="${FACES_DB:-$HOME/dispenser/faces.db}"
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source ./.env
  set +a
fi

echo "[run_api] FACES_DB=$FACES_DB"
echo "[run_api] api_server.py başlatılıyor..."
exec python3 api_server.py
