#!/bin/bash
# Sets up MediDispense kiosk to auto-launch on Pi desktop login.
# Run once: bash setup_kiosk_autostart.sh

AUTOSTART_DIR="/home/fens402/.config/autostart"
AUTOSTART_FILE="$AUTOSTART_DIR/medidispense-kiosk.desktop"

mkdir -p "$AUTOSTART_DIR"

cat > "$AUTOSTART_FILE" << 'EOF'
[Desktop Entry]
Type=Application
Name=MediDispense Kiosk
Comment=MediDispense kiosk display and face auth
Exec=/bin/bash -c 'sleep 5 && /usr/bin/python3 /home/fens402/pi_backend/kiosk_app.py'
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF

chmod +x "$AUTOSTART_FILE"
echo "[setup] ✓ Autostart entry created at $AUTOSTART_FILE"

# Also install and enable the systemd service as backup
sudo cp /home/fens402/pi_backend/medidispense-kiosk.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable medidispense-kiosk.service
echo "[setup] ✓ systemd service enabled"

echo
echo "[setup] Done. Reboot Pi to test:"
echo "  sudo reboot"
