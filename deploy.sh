#!/bin/bash
# Deploy pi_backend to Raspberry Pi via rsync + auto-restart

PI_HOST="${1:-192.168.0.16}"
PI_USER="${2:-fens402}"
PI_PATH="~/pi_backend"

echo "=========================================="
echo "[deploy] MediDispense Pi Backend Deployment"
echo "=========================================="
echo "[deploy] Target: $PI_USER@$PI_HOST:$PI_PATH"
echo

# ── 1. SSH check ────────────────────────────────────────────────────────────

echo "[deploy] Testing SSH connection..."
if ssh -o ConnectTimeout=5 "$PI_USER@$PI_HOST" "echo OK" &>/dev/null; then
  echo "[deploy] ✓ SSH connection OK"
else
  echo "[deploy] ✗ Cannot connect to $PI_USER@$PI_HOST"
  exit 1
fi

# ── 2. Rsync files ──────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="$SCRIPT_DIR/pi_backend"

if [ ! -d "$SOURCE_DIR" ]; then
  echo "[deploy] ✗ pi_backend/ not found at $SOURCE_DIR"
  exit 1
fi

echo "[deploy] Syncing pi_backend/ → Pi..."
rsync -avz \
  --exclude='__pycache__' \
  --exclude='*.pyc' \
  --exclude='*.db' \
  --exclude='.git' \
  --exclude='.venv' \
  --exclude='venv' \
  --exclude='*.log' \
  --exclude='sync_state.json' \
  --exclude='faces.db' \
  --exclude='faces.db-journal' \
  --delete \
  "$SOURCE_DIR/" "$PI_USER@$PI_HOST:$PI_PATH/"

if [ $? -ne 0 ]; then
  echo "[deploy] ✗ Rsync failed"
  exit 1
fi

echo "[deploy] ✓ Files synced"

# ── 3. Restart Flask on Pi ──────────────────────────────────────────────────

echo "[deploy] Installing service file + restarting MediDispense on Pi..."

ssh "$PI_USER@$PI_HOST" bash << 'REMOTE'
  set -e

  # Update service file if changed
  if ! diff -q ~/pi_backend/medidispense.service /etc/systemd/system/medidispense.service &>/dev/null; then
    echo "[pi] Updating service file..."
    sudo cp ~/pi_backend/medidispense.service /etc/systemd/system/medidispense.service
    sudo systemctl daemon-reload
    echo "[pi] ✓ Service file updated"
  fi

  # Try systemctl restart first
  if sudo systemctl restart medidispense.service 2>/dev/null; then
    sleep 2
    STATUS=$(sudo systemctl is-active medidispense.service 2>/dev/null)
    if [ "$STATUS" = "active" ]; then
      echo "[pi] ✓ Service restarted via systemctl (active)"
      exit 0
    fi
  fi

  # Fallback: kill process manually and restart
  echo "[pi] systemctl unreliable — using pkill fallback..."
  sudo pkill -f api_server.py 2>/dev/null || true
  sleep 2

  # Try systemctl start again after kill
  if sudo systemctl start medidispense.service 2>/dev/null; then
    sleep 2
    STATUS=$(sudo systemctl is-active medidispense.service 2>/dev/null)
    if [ "$STATUS" = "active" ]; then
      echo "[pi] ✓ Service started via systemctl (active)"
      exit 0
    fi
  fi

  # Last resort: run directly in background
  echo "[pi] Starting api_server.py directly..."
  cd ~/pi_backend
  nohup sudo /usr/bin/python3 api_server.py >> /tmp/medidispense.log 2>&1 &
  sleep 3

  # Verify it's running
  if pgrep -f api_server.py > /dev/null; then
    echo "[pi] ✓ api_server.py running (PID: $(pgrep -f api_server.py))"
  else
    echo "[pi] ✗ Failed to start api_server.py — check /tmp/medidispense.log"
    exit 1
  fi
REMOTE

RESTART_STATUS=$?

echo
echo "=========================================="
if [ $RESTART_STATUS -eq 0 ]; then
  echo "[deploy] ✓ Deploy complete! Pi is running new code."
  echo
  echo "[deploy] Verify: curl http://$PI_HOST:5000/api/health"
else
  echo "[deploy] ✗ Deploy succeeded but restart failed."
  echo "[deploy] SSH into Pi and check: journalctl -u medidispense.service -n 30"
fi
echo "=========================================="
