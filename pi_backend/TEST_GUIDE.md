# Pi Backend Testing Guide

## Quick Setup (MacBook → Pi)

### 1. Deploy latest code to Pi

```bash
cd ~/path/to/FENS402_MobileAppProject

# Make deploy script executable
chmod +x deploy.sh

# Deploy to Pi (adjust hostname if different)
./deploy.sh raspberrypi.local
```

This syncs `pi_backend/` to `~/pi_backend/` on Pi, excluding `*.db` files so your face data isn't lost.

### 2. SSH into Pi

```bash
ssh pi@raspberrypi.local
cd ~/pi_backend
```

### 3. Bootstrap (one-time setup)

```bash
python3 bootstrap_pi_backend.py
```

This creates the SQLite database and downloads the MediaPipe face model.

## Running Tests

### Test 1: State Machine Integration Test (no HTTP, no hardware)

```bash
cd ~/pi_backend
python3 test_integration.py
```

**What it tests:**
- Full workflow: bind slot → scan 3 barcodes → commit → trigger dispense → face auth → dispense → reset
- All state transitions
- Database operations (slot bindings, barcode logs)
- Query endpoints (get_all_slots, get_slot_medications)

**Expected output:** 10/10 tests passed

---

### Test 2: Flask API Test (requires running API server)

**Terminal 1 — Start the API server:**

```bash
cd ~/pi_backend
python3 api_server.py
```

Output should show:
```
[API] Starting on 0.0.0.0:5000 (debug=False)
```

**Terminal 2 — Run API tests:**

```bash
cd ~/pi_backend
python3 test_api.py
```

**What it tests:**
- All REST endpoints: `/api/state`, `/api/bind-slot`, `/api/barcode`, etc.
- HTTP request/response cycle
- JSON serialization/deserialization
- Error handling

---

## Test From MacBook (Over SSH)

If you want to run tests from your MacBook without SSH-ing in:

```bash
# Deploy
./deploy.sh

# Run state machine test
ssh pi@raspberrypi.local 'cd ~/pi_backend && python3 test_integration.py'

# Run API test (in background, polling for health)
ssh pi@raspberrypi.local 'cd ~/pi_backend && python3 api_server.py' &
sleep 2
ssh pi@raspberrypi.local 'cd ~/pi_backend && python3 test_api.py'
kill %1
```

---

## Manual Testing Via curl (Quick checks)

```bash
# SSH into Pi first
ssh pi@raspberrypi.local

# In one terminal, start API
python3 ~/pi_backend/api_server.py &

# In another terminal, test endpoints
sleep 2

# Health check
curl http://localhost:5000/api/health | jq

# Get state
curl http://localhost:5000/api/state | jq

# Bind slot
curl -X POST http://localhost:5000/api/bind-slot \
  -H 'Content-Type: application/json' \
  -d '{"patient_id": "test-001", "slot_id": 0, "patient_name": "Test"}' | jq

# Stop API
pkill -f 'python3.*api_server'
```

---

## Real Hardware Testing (Face + Motors)

Once tests pass, you can test with real camera & motors:

1. **Register a face:**
   ```bash
   python3 register.py --first-name John --last-name Doe --samples 5
   ```

2. **Start BLE server:**
   ```bash
   sudo python3 ble_server.py
   ```

3. **Connect Flutter app and test the full workflow** (caregiver → barcode scan → patient → face auth → dispense)

---

## Troubleshooting

### API server won't start
- Check if port 5000 is in use: `lsof -i :5000`
- Kill it: `pkill -f 'python3.*api_server'`

### Tests fail with DB errors
- Make sure `bootstrap_pi_backend.py` was run
- Check `faces.db` exists: `ls -la ~/pi_backend/faces.db`

### Motor test fails
- If using hardware, check GPIO pins in `motor_controller.py`
- Tests run in `DRY_RUN` mode by default (no actual GPIO)

### Face auth test fails
- If `face_landmarker.task` missing, `bootstrap_pi_backend.py` will download it
- Check: `ls -la ~/pi_backend/face_landmarker.task`

---

## Next Steps After Tests Pass

1. **Flutter integration:** Test the Flutter app's `DispenserService` connecting to Pi API
2. **Barcode scanner:** Test real camera barcode scanning in the app
3. **Face registration:** Register actual patient faces via app
4. **End-to-end flow:** Full caregiver + patient workflow
