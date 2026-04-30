# MediDispense - Teknik Mimari Detayları

---

## 🎯 Sistem Mimarisi Detaylı Görünüm

### 1. Mobil Uygulaması (Flutter) - Katmanlandırılmış Mimari

```
┌─────────────────────────────────────────────────────────────────┐
│                        PRESENTATION LAYER                       │
│  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐             │
│  │ Login Page   │ │ Patient      │ │ Caregiver    │             │
│  │              │ │ Dashboard    │ │ Dashboard    │             │
│  └──────────────┘ └──────────────┘ └──────────────┘             │
│  ┌──────────────────────────────────────────────────────────────┤
│  │ Drug Mgmt │ Schedule Mgmt │ Patient Mgmt │ Additional Screens│
│  └──────────────────────────────────────────────────────────────┘
└─────────────────────────────────────────────────────────────────┘
                              │
┌─────────────────────────────▼─────────────────────────────────┐
│                      BUSINESS LOGIC LAYER                    │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  State Management (Provider / ValueNotifier)           │  │
│  │  ├── AuthProvider                                      │  │
│  │  ├── PatientProvider                                   │  │
│  │  ├── MedicationProvider                                │  │
│  │  ├── ScheduleProvider                                  │  │
│  │  └── BLEConnectionProvider                             │  │
│  └────────────────────────────────────────────────────────┘  │
│                              │                                 │
│  ┌────────────────────────────▼────────────────────────────┐  │
│  │              SERVICE LAYER                              │  │
│  │  ┌──────────────────────────────────────────────────┐  │  │
│  │  │ FirebaseService      │ APIService               │  │  │
│  │  │ ├── getPatient()     │ ├── triggerDispense()    │  │  │
│  │  │ ├── saveMeds()       │ ├── verifyFace()         │  │  │
│  │  │ ├── watchSchedules() │ └── reportDeviceStatus()│  │  │
│  │  │ └── pushLog()        │                          │  │  │
│  │  └────────┬─────────────────────┬──────────────────┘  │  │
│  │           │                     │                      │  │
│  │  ┌────────▼────────┐  ┌─────────▼───────────────────┐  │  │
│  │  │ PermissionSvc   │  │ BLE Service (flutter_blue) │  │  │
│  │  │ ├── getCamPerm()│  │ ├── scan()                  │  │  │
│  │  │ ├── getBLEPerm()│  │ ├── connect()               │  │  │
│  │  │ └── getLocPerm()│  │ ├── writeCharacteristic()   │  │  │
│  │  └─────────────────┘  │ ├── onNotification()        │  │  │
│  │                       │ └── disconnect()            │  │  │
│  │                       └────────────────────────────┘  │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                              │
┌─────────────────────────────▼─────────────────────────────────┐
│                    DATA ACCESS LAYER                          │
│  ┌─────────────────────┐      ┌────────────────────────────┐  │
│  │ Local Database      │      │ Remote Data Sources        │  │
│  │ (SQLite via sqflite)│      │                            │  │
│  ├──────────────────────      ├────────────────────────────┤  │
│  │ ├── patients        │      │ ├── Firebase Realtime DB   │  │
│  │ ├── medications     │      │ ├── AWS Lambda API         │  │
│  │ ├── schedules       │      │ └── Raspberry Pi BLE       │  │
│  │ ├── dispensing_logs │      │                            │  │
│  │ └── sync_queue      │      │                            │  │
│  └──────────┬──────────┘      └─────────────┬──────────────┘  │
│             │                              │                   │
│  ┌──────────▼──────────────────────────────▼─────────────┐    │
│  │    SyncQueueManager                                    │    │
│  │    (Çevrimdışı operasyonları sıralar ve oynatır)      │    │
│  └────────────────────────────────────────────────────────┘    │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ ConnectivityService (online/offline durumunu izler)    │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

### 2. Backend Mimarisi (Raspberry Pi)

```
┌──────────────────────────────────────────────────────────────┐
│           Bluetooth LE Peripheral (BlueZ + Python)          │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │         ble_server.py (Ana giriş noktası)             │ │
│  │  ┌───────────────────────────────────────────────────┐ │ │
│  │  │ D-Bus Interface (org.bluez)                       │ │ │
│  │  │ ├── org.bluez.GattService1 (Advertisement)        │ │ │
│  │  │ ├── org.bluez.GattCharacteristic1 (Commands)      │ │ │
│  │  │ │   ├── CommandCharacteristic (write)             │ │ │
│  │  │ │   │   └── on_write() → handleCommand()          │ │ │
│  │  │ │   │                                              │ │ │
│  │  │ │   └── NotifyCharacteristic (notify)             │ │ │
│  │  │ │       └── send_notification() → Flask event     │ │ │
│  │  │ │                                                  │ │ │
│  │  │ └── Event Handler (Glib.GLib.MainLoop)            │ │ │
│  │  │     ├── on_pill_taken()                           │ │ │
│  │  │     ├── on_missed_dose()                          │ │ │
│  │  │     ├── on_hardware_error()                       │ │ │
│  │  │     └── on_status_request()                       │ │ │
│  │  └───────────────────────────────────────────────────┘ │ │
│  │                      │                                  │ │
│  │  ┌───────────────────▼───────────────────────────────┐ │ │
│  │  │ Command Router                                    │ │ │
│  │  │ switch(commandByte):                              │ │ │
│  │  │  case 0x01: unlock_compartment()                  │ │ │
│  │  │  case 0x02: lock_compartment()                    │ │ │
│  │  │  case 0x03: query_status()                        │ │ │
│  │  │  case 0x06: bind_slot_to_patient()                │ │ │
│  │  │  case 0x09: trigger_dispense_window()             │ │ │
│  │  │  ...                                              │ │ │
│  │  └───────────────────┬───────────────────────────────┘ │ │
│  └────────────────┬─────┴────────────────────────────────┘ │
│                   │                                          │
│    ┌──────────────▼────────────────┬───────────────────┐   │
│    │                               │                   │   │
│  ┌─▼───────────────┐  ┌────────────▼───┐  ┌──────────▼─┐  │
│  │DispenseControl  │  │MotorController │  │FaceAuthHeadless
│  │  er.py          │  │                │  │            │  │
│  ├─────────────────┤  ├────────────────┤  ├────────────┤  │
│  │ dispense()      │  │ move_stepper() │  │ detect()   │  │
│  │ calculate_dose()│  │ set_servo()    │  │ verify()   │  │
│  │ validate_slot() │  │ read_sensor()  │  │ register() │  │
│  └────┬────────────┘  └────┬───────────┘  └────┬───────┘  │
│       │                    │                    │           │
│       │ GPIO PWM           │ GPIO Digital      │ Camera   │
│       │ (Stepper)          │ (Servo)           │ MediaPipe
│       │                    │                   │           │
└───────┼────────────────────┼───────────────────┼───────────┘
        │                    │                   │
        ▼                    ▼                   ▼
    ┌──────────┐    ┌──────────────┐   ┌──────────────┐
    │Stepper   │    │Servo         │   │USB Camera    │
    │Motors    │    │Motors        │   │(Yüz tanıma)  │
    │(Dosage)  │    │(Valve)       │   └──────────────┘
    └──────────┘    └──────────────┘


  ┌────────────────────────────────────────────────────────┐
  │              Veri Depolama & Senkronizasyon            │
  ├────────────────────────────────────────────────────────┤
  │                                                        │
  │  ┌──────────────────┐         ┌──────────────────┐   │
  │  │  faces.db        │         │ .env             │   │
  │  │  (SQLite)        │         │ (Config)         │   │
  │  ├──────────────────┤         ├──────────────────┤   │
  │  │ PatientFace      │         │ API_BASE_URL →   │   │
  │  │ ├── patient_id   │         │ AWS Lambda       │   │
  │  │ ├── embedding    │         └──────────────────┘   │
  │  │ └── timestamp    │                │                │
  │  └──────────────────┘                │                │
  │                         ┌────────────▼────────────┐  │
  │                         │ requests library        │  │
  │                         │ POST /trigger_dispense  │  │
  │                         │ POST /log_dispensing    │  │
  │                         │ POST /verify_face       │  │
  │                         │ POST /device_status     │  │
  │                         └────────────┬────────────┘  │
  │                                      │                │
  │                         ┌────────────▼────────────┐  │
  │                         │ AWS Lambda (Python)     │  │
  │                         │ ├── trigger_dispense    │  │
  │                         │ ├── log_dispensing      │  │
  │                         │ ├── verify_face         │  │
  │                         │ └── device_status       │  │
  │                         └────────────┬────────────┘  │
  │                                      │                │
  │                         ┌────────────▼────────────┐  │
  │                         │ Firebase Realtime DB    │  │
  │                         │ ├── /patients           │  │
  │                         │ ├── /medications        │  │
  │                         │ ├── /schedules          │  │
  │                         │ └── /dispensing_logs    │  │
  │                         └─────────────────────────┘  │
  │                                                        │
  └────────────────────────────────────────────────────────┘
```

---

## 🔄 İletişim Protokolleri

### BLE Event Akışı

```
┌─────────────────────────────────────────────────────────────┐
│                   Flutter App (Client)                      │
│                  ┌──────────────────┐                       │
│                  │ Ready to dispense │                       │
│                  └────────┬─────────┘                        │
│                           │                                  │
│                           │ BLE Write Command                │
│                           │ (0x09 TRIGGER_DISP)              │
│                           ▼                                  │
└─────────────────────────────────────────────────────────────┘
                            │
┌───────────────────────────▼────────────────────────────────┐
│          Raspberry Pi (BLE GATT Server)                    │
│                                                             │
│ ├─ on_write() triggered                                    │
│ │   └─ parseCommand(0x09)                                 │
│ │       └─ trigger_dispense_window()                      │
│ │           ├─ dispense_controller.dispense()             │
│ │           │   ├─ motor_controller.move_stepper()        │
│ │           │   ├─ Poll load-cell sensor (5 sec)         │
│ │           │   ├─ If pill detected:                      │
│ │           │   │   └─ send_notification(0xA1)            │
│ │           │   └─ POST /log_dispensing (AWS)             │
│ │           │                                              │
│ │           └─ Update /dispensing_logs in Firebase        │
│ │                                                          │
│ └─ send_notification(0xA1, slot_id, status) via BLE      │
│    (Notify Characteristic)                                 │
│                                                             │
└───────────────────────────┬────────────────────────────────┘
                            │
┌───────────────────────────▼────────────────────────────────┐
│          Flutter App (Client)                              │
│                                                             │
│ ├─ onNotification() listener triggered                     │
│ │   └─ parseByte(0xA1)                                    │
│ │       └─ updateUI("Pill delivered!")                    │
│ │           └─ Show success toast                         │
│ │           └─ Update local DB (sql…                      │
│ │           └─ Sync to Firebase                           │
│ │                                                          │
│ └─ Caregiver Dashboard real-time updated                 │
│    (Firebase listener)                                     │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Yüz Tanıma Akışı

```
Patient App                    Raspberry Pi Backend
   │                                  │
   ├─ "Verify Face" tap               │
   │                                  │
   ├─ Open camera                     │
   │  Capture frame                   │
   │                                  │
   ├─ Face detection (MediaPipe)      │
   │  Extract 478 landmarks           │
   │                                  │
   ├─ Convert to embedding            │
   │  (Vector: 192-d)                 │
   │                                  │
   ├─ BLE Write                       │
   │  (Embedding bytes + patientId)   │
   │                                  │ ──► receive_embedding()
   │                                  │ ──► load faces.db
   │                                  │ ──► compute_distance()
   │                                  │ ──► if distance < THRESHOLD
   │                                  │     ├─► authenticated ✅
   │                                  │     └─► send_notification(0xA4)
   │  ◄─────────────────────────────────
   │  BLE Notify (AUTH_OK)            │
   │                                  │
   ├─ Update UI                       │
   │  "Patient authenticated"         │
   │                                  │
   └─ Ready for dispensing            │
```

---

## 📱 Firebase Realtime Database Operasyonları

### Read Operations (Listener Pattern)

```dart
// Hasta tüm bilgilerini izle (real-time)
FirebaseService.watchPatient(patientId).listen((patient) {
  // Battery level değişti mi?
  // Online status değişti mi?
  updateUI(patient);
});

// Tüm ilaç zamanlamalarını izle
FirebaseService.watchSchedules(patientId).listen((schedules) {
  // Bugün kaç ilaç var?
  // Hangisi sonrası?
  calculateNextDoseTime(schedules);
});

// Dispensing loglarını izle (sadece bugün)
FirebaseService.watchLogsToday(patientId).listen((logs) {
  // İlaçlar alındı mı?
  // Kaç tane missed?
  updateDashboard(logs);
});
```

### Write Operations (One-time)

```dart
// Hasta kaydı
await firebase.savePatient(PatientPayload(
  patientId: user.uid,
  firstName: "John",
  email: user.email,
));

// İlaç ekleme
await firebase.saveMedication(MedicationPayload(
  medicationId: generateId(),
  patientId: patientId,
  name: "Aspirin",
  stock: 30,
));

// Zamanlamayı güncelle
await firebase.updateSchedule(scheduleId, {
  'time': '08:00',
  'dosageAmount': 1,
  'isActive': true,
});

// Dağıtım kaydı (Offline-first)
// 1. Lokal DB'ye yaz
await localDb.insertLog(log);
// 2. SyncQueue'ye ekle
await syncQueue.enqueue('pushDispensingLog', log);
// 3. Bağlantı gelince otomatik Firebase'e
```

---

## 🔐 Veri Güvenliği Modeli

### Firebase Security Rules

```javascript
{
  "rules": {
    "patients": {
      "$patientId": {
        ".read": "root.child('patient_caregivers')
          .hasChild(auth.uid + '-' + $patientId) ||
          auth.uid === $patientId",

        ".write": "auth.uid === $patientId",

        ".validate": "newData.hasChildren(['firstName', 'email'])"
      }
    },

    "medications": {
      "$medicationId": {
        ".read": "root.child('medications').child($medicationId)
          .child('patientId').val() === root.child('patients')
          .child(auth.uid).exists()",

        ".write": "root.child('medications').child($medicationId)
          .child('patientId').val() === auth.uid"
      }
    },

    "dispensing_logs": {
      "$logId": {
        ".read": "root.child('dispensing_logs').child($logId)
          .child('patientId').val() === auth.uid ||
          [caregiver logic]",

        ".write": "root.child('dispensing_logs').child($logId)
          .child('patientId').val() === auth.uid"
      }
    }
  }
}
```

### BLE Güvenlik

- **No Pairing:** İlk prototipos test için basit uygulama
- **TODO:** GATT Characteristic permissions (read-only, write-only)
- **TODO:** Encekryptilmiş BLE komutları (TLS-style)
- **TODO:** Device whitelist (faces.db'deki patientId tabanlı)

---

## 🗂️ Veritabanı Şeması

### SQLite (sqflite) - Mobil Uygulaması

```sql
-- Hastalar (Firebase'den senkronize)
CREATE TABLE patients (
  patient_id TEXT PRIMARY KEY,
  first_name TEXT,
  last_name TEXT,
  email TEXT UNIQUE,
  role TEXT,
  is_online BOOLEAN,
  battery_level INTEGER,
  last_seen_at TEXT,
  synced_at TEXT
);

-- İlaçlar
CREATE TABLE medications (
  medication_id TEXT PRIMARY KEY,
  patient_id TEXT,
  name TEXT,
  dosage TEXT,
  stock INTEGER,
  expiry_date TEXT,
  FOREIGN KEY(patient_id) REFERENCES patients(patient_id)
);

-- İlaç Zamanlaması
CREATE TABLE schedules (
  schedule_id TEXT PRIMARY KEY,
  medication_id TEXT,
  patient_id TEXT,
  days_of_week TEXT,  -- JSON: [0,2,4]
  time TEXT,           -- HH:MM
  dosage_amount INTEGER,
  is_active BOOLEAN,
  FOREIGN KEY(medication_id) REFERENCES medications(medication_id)
);

-- Dağıtım Logları (offline queue)
CREATE TABLE dispensing_logs (
  log_id TEXT PRIMARY KEY,
  medication_id TEXT,
  patient_id TEXT,
  dispensed_at TEXT,
  status TEXT,         -- "pending" | "taken" | "missed"
  synced BOOLEAN,
  FOREIGN KEY(medication_id) REFERENCES medications(medication_id)
);

-- Sync Queue (offline operasyonlar)
CREATE TABLE sync_queue (
  queue_id TEXT PRIMARY KEY,
  operation TEXT,      -- "POST" | "PUT" | "DELETE"
  table_name TEXT,     -- "medications" | "schedules"
  record_id TEXT,
  payload TEXT,        -- JSON
  created_at TEXT,
  synced BOOLEAN
);
```

### SQLite (Raspberry Pi) - faces.db

```sql
CREATE TABLE patient_faces (
  patient_id TEXT PRIMARY KEY,
  face_embedding BLOB,      -- 192-dimensional float array
  face_encoding_json TEXT,  -- JSON backup
  registered_at TEXT,
  updated_at TEXT
);

CREATE TABLE face_access_log (
  log_id INTEGER PRIMARY KEY AUTOINCREMENT,
  patient_id TEXT,
  attempt_at TEXT,
  match_score REAL,
  authenticated BOOLEAN,
  FOREIGN KEY(patient_id) REFERENCES patient_faces(patient_id)
);
```

---

## 🚀 Deployment & DevOps

### Flutter App Deployment

```
┌──────────────────────────┐
│  GitHub Actions CI/CD    │
├──────────────────────────┤
│                          │
│ Trigger: push to main    │
│                          │
│ ├─ flutter test          │
│ ├─ flutter analyze       │
│ ├─ flutter build apk     │
│ ├─ flutter build ipa     │
│ └─ Upload artifacts      │
│                          │
├──────────────────────────┤
│ Manual Release:          │
│                          │
│ ├─ Google Play Store     │
│ │  └─ Internal Testing   │
│ │  └─ Beta Track         │
│ │  └─ Production         │
│ │                        │
│ └─ Apple App Store       │
│    └─ TestFlight         │
│    └─ Production         │
│                          │
└──────────────────────────┘
```

### Raspberry Pi Backend Deployment

```bash
# SSH into Pi
ssh pi@192.168.1.x

# Clone repo
git clone <repo>
cd pi_backend

# Setup Python venv
python3 -m venv venv
source venv/bin/activate

# Install dependencies
pip install -r requirements.txt

# Setup .env
cp .env.example .env
# Edit .env with AWS API_BASE_URL

# Initialize database
python3 bootstrap_pi_backend.py

# Start BLE server (systemd service)
sudo systemctl start medidispense-ble
sudo systemctl enable medidispense-ble

# Monitor logs
sudo journalctl -u medidispense-ble -f
```

---

## 🧪 Test Stratejisi

### Unit Tests (Dart)

```dart
// Firebase Service Tests
test('FirebaseService.getPatient returns patient data', () async {
  final firebase = FirebaseService(database: mockFirebaseDB);
  final patient = await firebase.getPatient('patient-123');

  expect(patient?.patientId, 'patient-123');
  expect(patient?.firstName, 'John');
});

// Model Tests
test('PatientPayload serialization round-trip', () {
  final original = PatientPayload(
    patientId: 'p1',
    firstName: 'John',
  );

  final json = original.toJson();
  final restored = PatientPayload.fromJson(json);

  expect(restored.patientId, original.patientId);
});
```

### Widget Tests

```dart
// LoginPage Tests
testWidgets('LoginPage renders email and password fields', (tester) async {
  await tester.pumpWidget(const SmartDrugDispenserApp());

  expect(find.byType(TextField), findsWidgets);
  expect(find.text('Sign In'), findsOneWidget);
});

// PatientDashboard Tests
testWidgets('PatientDashboard shows todays medications', (tester) async {
  // Setup mock data
  // Pump widget
  // Verify widgets rendered
});
```

### Integration Tests

```dart
// BLE Connection Test
testWidgets('Connect to BLE device and read status', (tester) async {
  // 1. Scan for devices
  // 2. Connect to SmartDispenser
  // 3. Subscribe to notify characteristic
  // 4. Verify 0xA4 (STATUS_RESPONSE) received
  // 5. Parse response
  // 6. Assert device online
});

// Firebase Sync Test
testWidgets('Offline changes sync when online', (tester) async {
  // 1. Disconnect from internet
  // 2. Add new medication locally
  // 3. Verify in local DB
  // 4. Verify in SyncQueue
  // 5. Reconnect internet
  // 6. Wait for sync
  // 7. Verify in Firebase
});
```

### Backend Tests (Python)

```python
# BLE Server Tests
@pytest.mark.asyncio
async def test_handle_trigger_disp_command():
    """Test 0x09 TRIGGER_DISP command"""
    ble_server = BLEServer()
    response = ble_server.handle_command(bytes([0x09, 0x01]))

    assert response[0] == 0xA5  # COMMAND_ACK
    assert dispense_controller.dispense.called

# Face Auth Tests
def test_face_detection_and_matching():
    """Test face detection + embedding matching"""
    auth = FaceAuthHeadless()

    # Register patient
    auth.register("patient-1", face_image_1)

    # Verify same patient
    is_match = auth.verify("patient-1", face_image_1)
    assert is_match

    # Verify different patient
    is_match = auth.verify("patient-1", face_image_2)
    assert not is_match
```

---

## 📊 Performance Optimizations

### Flutter Tarafı
- **const constructors** tüm ekranlarda kullanılıyor
- **Listeners** sadece gerekli yerlerde (Provider pattern)
- **SQLite caching** sık sorgulanan veriler için
- **BLE batching** multiple commands birleştirilir

### Backend Tarafı
- **faces.db indexing:** patient_id PRIMARY KEY
- **Async I/O:** Python asyncio (GLib event loop)
- **Debouncing:** Sensor readings (5 saniye threshold)
- **Lazy loading:** Face embedding ancak kayıt sırasında

---

**Mimari Dokümantasyon** | v1.0
Son Güncelleme: 4 Nisan 2025
