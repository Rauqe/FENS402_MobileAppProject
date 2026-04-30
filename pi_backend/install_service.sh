#!/bin/bash
# Installs and enables the MediDispense systemd service.
# Run once on the Pi: bash install_service.sh

SERVICE_NAME="medidispense"
SERVICE_FILE="$(dirname "$(realpath "$0")")/medidispense.service"
DEST="/etc/systemd/system/${SERVICE_NAME}.service"

echo "=== MediDispense Service Installer ==="

if [ ! -f "$SERVICE_FILE" ]; then
  echo "[ERROR] medidispense.service not found at $SERVICE_FILE"
  exit 1
fi

# Copy service file
sudo cp "$SERVICE_FILE" "$DEST"
echo "[OK] Copied service file to $DEST"

# Reload systemd and enable
sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE_NAME"
sudo systemctl restart "$SERVICE_NAME"

echo ""
echo "=== Done! ==="
echo "Service status:"
sudo systemctl status "$SERVICE_NAME" --no-pager -l

echo ""
echo "Useful commands:"
echo "  sudo systemctl status medidispense     # check status"
echo "  sudo systemctl restart medidispense    # restart"
echo "  sudo systemctl stop medidispense       # stop"
echo "  journalctl -u medidispense -f          # live logs"
