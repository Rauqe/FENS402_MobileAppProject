# MediDispense Deployment Checklist

Use this checklist to ensure all components are properly configured before deployment to production.

---

## Pre-Deployment (Local Development)

### Code Quality
- [ ] All Python files follow PEP 8 style (run `flake8` on pi_backend/)
- [ ] Flutter code builds without warnings (`flutter analyze`)
- [ ] No hardcoded credentials in any source files
- [ ] Comments are concise and English-only
- [ ] All TODO/FIXME comments addressed

### Testing Completed
- [ ] Unit tests pass for critical functions
- [ ] Integration tests verify API endpoints
- [ ] UI tests verify Flutter screens render correctly
- [ ] Manual testing of all features completed

### Documentation
- [ ] TESTING_GUIDE.md created and up-to-date
- [ ] FACE_DUPLICATE_DETECTION.md explains new features
- [ ] README.md contains setup instructions
- [ ] API endpoint documentation current

---

## Raspberry Pi Configuration

### Hardware
- [ ] Raspberry Pi 5 with adequate power supply
- [ ] Raspberry Pi AI Camera (IMX500) connected to CSI port
- [ ] Network connected (Ethernet or WiFi)
- [ ] Storage: minimum 32GB SD card
- [ ] Optional: Dispenser hardware connected (if testing physical dispensing)

### Operating System
- [ ] Raspberry Pi OS (64-bit) installed and updated
  ```bash
  sudo apt update && sudo apt full-upgrade
  ```

### User Setup
- [ ] User account `fens402` created
- [ ] User added to `video` group for camera access
  ```bash
  sudo usermod -a -G video fens402
  sudo usermod -a -G dialout fens402  # For serial devices if needed
  ```

### System Python
- [ ] Python 3.11+ installed
  ```bash
  python3 --version
  ```
- [ ] System packages installed:
  ```bash
  sudo apt install -y python3-picamera2 python3-psycopg2 \
    python3-dotenv python3-pip
  ```

### Backend Directory Structure
- [ ] Directory created: `~/pi_backend/`
- [ ] Permissions set: `chmod 755 ~/pi_backend/`
- [ ] Subdirectories created:
  ```
  ~/pi_backend/
  ├── api_server.py
  ├── auth.py
  ├── register.py
  ├── sync_service.py
  ├── state_machine.py
  ├── pi_camera.py
  ├── .env              # Do NOT check in to git
  ├── .venv/            # Python virtual environment (optional)
  └── faces.db          # SQLite database (auto-created)
  ```

### Environment Variables (.env)

Create `~/pi_backend/.env`:
```bash
# AWS RDS Configuration
RDS_HOST=your-rds-endpoint.rds.amazonaws.com
RDS_PORT=5432
RDS_DB_NAME=medidispense
RDS_USER=admin
RDS_PASSWORD=<strong-password>

# Pi Backend Configuration
DISPENSER_MODEL_ID=MEDI-FENS402-2024
PI_BACKEND_PORT=5000
LOG_LEVEL=INFO

# Default Caregiver Account
DEFAULT_CAREGIVER_EMAIL=caregiver@medidispense.local
DEFAULT_CAREGIVER_PASSWORD=TempPassword123!

# Optional: Firebase Configuration (if using Firebase)
FIREBASE_API_KEY=your-api-key
FIREBASE_PROJECT_ID=your-project-id
```

**Permissions:**
```bash
chmod 600 ~/.env  # Only owner can read
```

### AWS RDS Setup

- [ ] RDS PostgreSQL instance created
- [ ] Security group allows inbound on port 5432 from Pi's IP
- [ ] Database `medidispense` created
- [ ] User `admin` created with full privileges
- [ ] Test connection from Pi:
  ```bash
  psql -h your-rds-endpoint.amazonaws.com -U admin -d medidispense -c "SELECT 1"
  ```

### Database Schema

The following tables are auto-created by the Pi backend on startup:

**SQLite (local):**
- `users` — Caregiver/patient accounts
- `patients` — Patient records
- `medications` — Medication inventory
- `slot_bindings` — Patient ↔ Slot associations
- `slot_medications` — Slot ↔ Medication associations
- `local_schedules` — Medication schedules
- `local_users` — Face encoding averages
- `face_samples` — Individual face capture samples
- `face_auth_log` — Face authentication events
- `sync_queue` — Events pending AWS sync

**AWS RDS (PostgreSQL):**
- `patients` — Synced from Pi
- `medications` — Synced from Pi
- `medication_schedules` — Synced from Pi
- `dispensing_logs` — Synced from Pi

No manual schema creation needed; endpoints handle idempotent table creation.

---

## Flask API Server

### Installation
- [ ] Flask installed: `pip3 install flask`
- [ ] All dependencies available in system Python

### API Endpoints Deployed
The following endpoints should be accessible:

**State & Control:**
- `GET /api/state` — Machine state
- `POST /api/reset` — Reset state machine
- `POST /api/trigger-dispense` — Manual dispensing

**Face Registration:**
- `POST /api/face/register` — Register new face (with duplicate detection)
- `GET /api/face/users` — List registered faces
- `GET /api/face-auth-logs` — Face authentication history
- `DELETE /api/face-auth-logs` — Clear logs

**Slots & Medications:**
- `GET /api/slots` — List all slots
- `GET /api/slots/<id>/medications` — Get slot medications
- `POST /api/bind-slot` — Bind patient to slot
- `DELETE /api/slots/<id>` — Delete slot binding
- `POST /api/barcode` — Scan barcode

**Schedules:**
- `GET /api/schedules/<patient_id>` — Get patient's schedules
- `POST /api/schedules` — Create schedule
- `DELETE /api/schedules/<id>` — Delete schedule

**Patients:**
- `GET /api/patients` — List all patients
- `POST /api/patients` — Create patient
- `GET /api/patients/<id>` — Get patient details

### CORS Configuration
- [ ] CORS properly configured if app runs on different domain
- [ ] Allowed origins: Flutter app's origin and localhost

---

## Systemd Service Setup

### Service File
Verify `/etc/systemd/system/medidispense.service` contains:

```ini
[Unit]
Description=MediDispense Pi Backend
After=network.target

[Service]
Type=simple
User=fens402
WorkingDirectory=/home/fens402/pi_backend
ExecStart=/usr/bin/python3 /home/fens402/pi_backend/api_server.py
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SupplementaryGroups=video

[Install]
WantedBy=multi-user.target
```

### Service Setup
```bash
# Copy service file
sudo cp ~/pi_backend/medidispense.service /etc/systemd/system/

# Reload systemd
sudo systemctl daemon-reload

# Enable auto-start
sudo systemctl enable medidispense

# Start service
sudo systemctl start medidispense

# Check status
sudo systemctl status medidispense

# View logs
journalctl -u medidispense -f
```

- [ ] Service file installed to `/etc/systemd/system/`
- [ ] Service enabled: `sudo systemctl enable medidispense`
- [ ] Service started: `sudo systemctl start medidispense`
- [ ] Service running: `systemctl status medidispense` shows "active (running)"

---

## Camera Configuration

### Hardware Verification
```bash
# List connected cameras
libcamera-hello --list-cameras

# Should output something like:
# 0 : [912x912] (/base/soc/i2c0mux/i2c@1,ba80000/rp_ov5647 10-0036) [SENSOR]
```

- [ ] Camera appears in `libcamera-hello --list-cameras`
- [ ] User in `video` group: `groups fens402` includes `video`

### Software Verification
```bash
# Test picamera2
/usr/bin/python3 -c "from picamera2 import Picamera2; print('✓ picamera2 available')"

# Should print: ✓ picamera2 available
```

- [ ] `picamera2` module available in system Python
- [ ] Test capture works: `libcamera-still -o test.jpg` (creates image)

### Fallback (OpenCV)
If picamera2 fails, system falls back to OpenCV `VideoCapture`:
- [ ] OpenCV installed: `pip3 install opencv-python`
- [ ] Note: OpenCV fallback may not work well with Pi AI Camera

---

## Flutter App Configuration

### Firebase Setup
- [ ] Firebase project created
- [ ] iOS app registered in Firebase console
- [ ] `GoogleService-Info.plist` downloaded and added to project
- [ ] Firebase dependencies in `pubspec.yaml`:
  ```yaml
  firebase_core: ^latest
  firebase_auth: ^latest
  firebase_database: ^latest
  ```

### API Service Configuration
- [ ] `lib/core/constants/api_constants.dart` contains correct Pi IP:
  ```dart
  const String kPiBaseUrl = 'http://192.168.x.x:5000';  // Set to actual Pi IP
  ```

### Build & Deploy
- [ ] App builds without errors: `flutter build ios`
- [ ] App tested on physical iPhone device
- [ ] App handles offline Pi gracefully (error messages shown)

---

## Network Configuration

### Pi Network
- [ ] Pi has static IP or reserved DHCP lease
- [ ] Pi IP reachable from development machine
- [ ] Test connectivity:
  ```bash
  ping <pi-ip>
  curl http://<pi-ip>:5000/api/state
  ```

### iPhone Network
- [ ] iPhone on same WiFi network as Pi (or bridged network)
- [ ] iPhone can reach Pi IP from app:
  ```
  In app, check status shows "Pi Connected: <ip>"
  ```

### Firewall
- [ ] Port 5000 open on Pi for Flask API
- [ ] Port 5432 open from Pi to AWS RDS (security group)

---

## Deployment Process

### 1. Code Deployment
```bash
# On development machine
cd ~/FENS402_MobileAppProject
./deploy.sh
```

This should:
- [ ] SSH into Pi successfully
- [ ] Sync backend files (excluding `.venv`, `faces.db`)
- [ ] Show summary of changes

### 2. Database Setup (First Time Only)
```bash
# On Pi, manually create AWS tables once
(.venv) fens402@raspberrypi:~/pi_backend$ python3 -c "
from sync_service import SyncService
sync = SyncService()
# Tables auto-created by endpoints, but can verify:
import psycopg2
# Connection test only, don't execute
"
```

### 3. Service Restart
```bash
# On Pi
sudo systemctl restart medidispense
sudo systemctl status medidispense  # Should be "active (running)"
```

### 4. Verification
```bash
# Test API is responding
curl -s http://localhost:5000/api/state | jq '.'

# Check database files created
ls -lah ~/pi_backend/faces.db*
```

---

## Post-Deployment Verification

### Backend Startup
- [ ] Service started without errors
- [ ] Logs show "Flask app running on 0.0.0.0:5000"
- [ ] No errors about missing modules or database

### API Availability
- [ ] `curl http://<pi-ip>:5000/api/state` returns JSON
- [ ] All endpoints respond (check TESTING_GUIDE.md for full list)

### Database Initialization
- [ ] Local `faces.db` created in `~/pi_backend/`
- [ ] All tables exist: `sqlite3 ~/pi_backend/faces.db ".tables"`
- [ ] AWS RDS receives sync data after first registration/medication

### Default Account
- [ ] Caregiver account auto-created on startup
- [ ] Can login with credentials from .env
- [ ] No need to run `create_test_caregiver.py`

### Face Registration
- [ ] Camera detection works
- [ ] Can capture face samples
- [ ] **NEW**: Duplicate faces detected and warned
- [ ] Data synced to AWS

---

## Monitoring & Maintenance

### Log Monitoring
```bash
# Real-time logs
journalctl -u medidispense -f

# Recent logs
journalctl -u medidispense -n 100

# Logs from last hour
journalctl -u medidispense --since "1 hour ago"
```

- [ ] Monitor logs daily for errors
- [ ] Set up log rotation if logs grow too large

### Database Backups
```bash
# Backup SQLite
cp ~/pi_backend/faces.db ~/pi_backend/faces.db.$(date +%Y%m%d-%H%M%S)

# AWS RDS automated backups should be enabled in AWS console
```

- [ ] Daily backups of `faces.db` scheduled (cron job)
- [ ] AWS RDS automated backups enabled
- [ ] Backup retention policy set (minimum 7 days)

### Performance Monitoring
- [ ] API response times <500ms (typical)
- [ ] Face registration <45 seconds total
- [ ] Database size monitored (`du -sh ~/pi_backend/faces.db`)

### Error Handling
- [ ] Monitor logs for database connection errors
- [ ] Monitor logs for face registration failures
- [ ] Monitor logs for AWS sync issues

---

## Rollback Procedure

If issues occur after deployment:

### Quick Rollback
```bash
# Restore from git
cd ~/pi_backend
git checkout api_server.py register.py  # Or whichever files broke

# Restart
sudo systemctl restart medidispense
```

### Full Rollback
```bash
# Stop service
sudo systemctl stop medidispense

# Restore backup (if available)
cp ~/pi_backend/faces.db.backup ~/pi_backend/faces.db

# Re-checkout
git checkout .

# Start service
sudo systemctl start medidispense
```

### Database Rollback
```bash
# If database corrupted
cd ~/pi_backend
mv faces.db faces.db.bad
sudo systemctl restart medidispense  # Creates new database

# Then sync from AWS
python3 -c "
from sync_service import SyncService
sync = SyncService()
# Full sync will pull data from AWS
"
```

---

## Security Checklist

### Credentials
- [ ] `.env` file NOT committed to git
- [ ] `.env` file permissions: `chmod 600`
- [ ] AWS RDS password is strong (>12 chars, mixed case, symbols)
- [ ] No credentials in source code

### Network
- [ ] SSH key-based auth enabled (no passwords over network)
- [ ] Firewall restricts ports (only 5000/5432 for required connections)
- [ ] Pi not exposed to internet (internal network only)

### Database
- [ ] RDS backups enabled
- [ ] Database encryption enabled
- [ ] Only required users have access

### Application
- [ ] CORS properly configured (specific origins, not *)
- [ ] Input validation on all endpoints
- [ ] Rate limiting considered for registration

---

## Final Sign-Off

- [ ] All items above checked
- [ ] Testing completed successfully
- [ ] No critical issues remaining
- [ ] Backup created before deployment
- [ ] Team notified of deployment

**Deployment Date:** ___________
**Deployed By:** ___________
**Notes:**

