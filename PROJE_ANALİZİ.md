# MediDispense — Akıllı İlaç Dağıtıcı Sistemi
## FENS402 Proje Tam Analizi

> **Tarih:** 21 Nisan 2026
> **Platform:** Flutter (Dart) + Raspberry Pi (Python) + AWS Lambda + Firebase
> **Versiyon:** 1.0.0+1

---

## 1. Projeye Genel Bakış

MediDispense, FENS402 dersi kapsamında geliştirilen **akıllı bir ilaç dağıtım sistemidir**. Hasta, yüz tanıma ile kimliğini doğruladıktan sonra fiziksel ilaç dağıtıcı cihaz otomatik olarak açılır. Sistem; Flutter mobil uygulaması, Raspberry Pi tabanlı donanım arka ucu, Firebase Realtime Database ve AWS Lambda bulut servisleri olmak üzere dört ana bileşenden oluşmaktadır.

**Temel Senaryo:**
1. Bakıcı (Caregiver), hastanın ilaçlarını ve çizelgesini sisteme girer.
2. Bakıcı, ilaçları fiziksel dağıtıcının slotlarına barcode tarayarak yükler.
3. Dağıtım zamanı geldiğinde sistem hastayı uyarır.
4. Hasta, mobil uygulamada yüz doğrulamasını geçer.
5. Raspberry Pi, servo motoru çalıştırarak ilgili slotu açar.
6. Tüm dağıtım olayları Firebase'e ve AWS'ye loglanır.

---

## 2. Sistem Mimarisi

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        FLUTTER MOBİL UYGULAMA                           │
│  ┌────────────────┐  ┌──────────────────┐  ┌─────────────────────────┐  │
│  │  Giriş / Kayıt │  │  Hasta Dashboard │  │  Bakıcı Dashboard       │  │
│  └────────────────┘  └──────────────────┘  └─────────────────────────┘  │
│  ┌────────────────┐  ┌──────────────────┐  ┌─────────────────────────┐  │
│  │  İlaç Yönetimi │  │  Çizelge Yönetimi│  │  Hasta Yönetimi         │  │
│  └────────────────┘  └──────────────────┘  └─────────────────────────┘  │
│  ┌────────────────────────────────────────────────────────────────────┐  │
│  │  Dağıtıcı Kontrol | Yüz Kayıt | Barkod Tarama                    │  │
│  └────────────────────────────────────────────────────────────────────┘  │
└──────────────────────┬────────────────────────────────────────┬──────────┘
                       │ HTTP REST (Wi-Fi)                       │ Firebase SDK
                       ▼                                         ▼
┌──────────────────────────────────┐      ┌──────────────────────────────┐
│    RASPBERRY Pi BACKEND          │      │    FIREBASE REALTIME DB       │
│  ┌──────────────────────────┐   │      │  /patients/{id}               │
│  │  Flask REST API (5000)   │   │      │  /medications/{id}            │
│  │  ├── /api/state          │   │      │  /medication_schedules/{id}   │
│  │  ├── /api/bind-slot      │◄──┼──────│  /dispensing_logs/{id}        │
│  │  ├── /api/trigger-dispense│  │      │  /patient_caregivers/{id}     │
│  │  ├── /api/barcode        │   │      └──────────────────────────────┘
│  │  ├── /api/camera/open    │   │
│  │  ├── /api/sync/*         │   │      ┌──────────────────────────────┐
│  │  └── /api/auth/*         │   │      │    AWS Lambda + API Gateway   │
│  └──────────────────────────┘   │      │  (eu-north-1)                 │
│  ┌──────────────────────────┐   │◄─────│  /default/api/patients        │
│  │  State Machine           │   │      │  /default/api/medications     │
│  │  IDLE→ROTATING→LOADING   │   │      │  /default/api/schedules       │
│  │  →SLOT_READY→WAITING     │   │      │  /default/api/dispensing-logs │
│  │  →FACE_MATCHED→DISPENSING│   │      │  /default/api/sync/*          │
│  └──────────────────────────┘   │      └──────────────────────────────┘
│  ┌──────────────────────────┐   │
│  │  Motor Controller (Servo)│   │
│  │  14 slot × 25.714° /slot │   │
│  │  BCM GPIO 18 — 50 Hz PWM │   │
│  └──────────────────────────┘   │
│  ┌──────────────────────────┐   │
│  │  Face Auth (face_recogn.)│   │
│  │  + MediaPipe liveness    │   │
│  └──────────────────────────┘   │
│  ┌──────────────────────────┐   │
│  │  SQLite (faces.db)       │   │
│  │  local_users / face_samp │   │
│  └──────────────────────────┘   │
└──────────────────────────────────┘
```

---

## 3. Proje Dizin Yapısı

```
FENS402_MobileAppProject/
├── lib/                          ← Flutter uygulama kaynak kodu
│   ├── main.dart                 ← Uygulama giriş noktası
│   ├── core/
│   │   ├── app_session.dart      ← Oturum yönetimi singleton
│   │   ├── bridge_test_state.dart← BLE köprü test durumu
│   │   └── constants/
│   │       ├── api_constants.dart← AWS API base URL
│   │       └── ble_constants.dart← BLE UUID ve komut enum'ları
│   ├── models/
│   │   ├── patient.dart          ← Hasta veri modeli
│   │   ├── medication.dart       ← İlaç veri modeli
│   │   ├── medication_schedule.dart ← İlaç çizelgesi modeli
│   │   ├── user_role.dart        ← Kullanıcı rolü enum
│   │   └── firebase_payloads.dart← Firebase için payload sınıfları
│   ├── services/
│   │   ├── api_service.dart      ← Pi REST API istemcisi (CRUD)
│   │   ├── auth_service.dart     ← Giriş / kayıt HTTP servisi
│   │   ├── auth_manager.dart     ← Yüz tanıma + BLE unlock boru hattı
│   │   ├── ble_service.dart      ← BLE GATT bağlantısı ve komutları
│   │   ├── dispenser_service.dart← Pi durum poller + komut istemcisi
│   │   ├── firebase_service.dart ← Firebase Realtime DB sarmalayıcı
│   │   └── permission_service.dart← Bluetooth/kamera izinleri
│   ├── data/
│   │   ├── local_database.dart   ← SQLite (yüz embedding, çizelge, kuyruk)
│   │   └── sync_queue_manager.dart← Çevrimdışı senkronizasyon kuyruğu
│   ├── screens/
│   │   ├── login_page.dart       ← E-posta + şifre girişi
│   │   ├── signup_page.dart      ← Kayıt ekranı
│   │   ├── patient_dashboard.dart← Hasta ana ekranı (çizelge + BLE)
│   │   ├── caregiver_dashboard.dart ← Bakıcı ana ekranı (hasta listesi + sync)
│   │   ├── patient_management.dart  ← Hasta ekleme/düzenleme/silme
│   │   ├── drug_management.dart     ← İlaç yönetimi
│   │   ├── schedule_management.dart ← Çizelge yönetimi
│   │   ├── dispenser_control.dart   ← Dağıtıcı kontrol paneli (slot bağlama)
│   │   └── face_registration.dart   ← Yüz kaydı ekranı
│   └── widgets/
│       └── barcode_scanner_sheet.dart ← Kamera tabanlı barkod tarayıcı
├── pi_backend/                   ← Raspberry Pi Python arka ucu
│   ├── api_server.py             ← Flask REST API sunucusu
│   ├── state_machine.py          ← Dağıtıcı durum makinesi
│   ├── motor_controller.py       ← Servo motor (14-slot dönel tepsi)
│   ├── face_auth_headless.py     ← Başsız yüz doğrulama (face_recognition)
│   ├── auth.py                   ← Kullanıcı kimlik doğrulama (SQLite)
│   ├── ble_server.py             ← BLE GATT sunucusu (bluez/dbus)
│   ├── dispenser_scheduler.py    ← Otomatik zamanlama servisi
│   ├── sync_service.py           ← Pi ↔ AWS bulut senkronizasyon
│   ├── register.py               ← Yüz kayıt aracı
│   ├── pi_camera.py              ← Raspberry Pi kamera sarmalayıcı
│   ├── servo_control.py          ← Düşük seviye servo yardımcıları
│   ├── display_ui.py             ← Pi kiosk ekranı (opsiyonel)
│   ├── kiosk_app.py              ← Kiosk uygulaması
│   ├── faces.db                  ← Yerel SQLite (yüz vektörleri)
│   ├── face_landmarker.task      ← MediaPipe model dosyası
│   ├── medidispense.service      ← systemd servis birimi
│   └── install_service.sh        ← Servis kurulum scripti
├── FENS-Drug_Dispenser/          ← AWS bulut bileşeni (FastAPI)
│   ├── api/
│   │   ├── main.py               ← FastAPI uygulaması
│   │   ├── database.py           ← SQLAlchemy bağlantısı
│   │   └── routers/              ← Endpoint router'ları
│   ├── database/
│   │   ├── aws_database/         ← AWS (RDS) veritabanı şeması
│   │   └── local_database/       ← Yerel DB şeması
│   └── face_authentication/      ← Bulut tarafı yüz kimlik doğrulama
├── android/                      ← Android platform dosyaları
├── ios/                          ← iOS platform dosyaları
├── pubspec.yaml                  ← Flutter bağımlılıkları
├── ARCHITECTURE.md               ← Teknik mimari dökümantasyonu
└── DEPLOYMENT_CHECKLIST.md       ← Dağıtım kontrol listesi
```

---

## 4. Flutter Uygulama Katmanları

### 4.1 Giriş Noktası — `main.dart`

Uygulama `SmartDrugDispenserApp` adlı `StatelessWidget` ile başlar. Material3 kullanılır; tema rengi `#0D9373` (koyu yeşil). Başlangıç ekranı doğrudan `LoginPage`'dir — Firebase `initializeApp()` çağrısı şu an eksiktir (TODO).

### 4.2 Oturum Yönetimi — `AppSession`

Singleton `AppSession.instance` ile giriş yapan kullanıcının rolü (hasta / bakıcı) ve seçili `Patient` nesnesi bellekte tutulur. Herhangi bir ekrandan `AppSession.instance.currentPatientId` ile mevcut hastaya erişilebilir.

### 4.3 Veri Modelleri

| Model | Alanlar | Önemli Özellikler |
|---|---|---|
| `Patient` | `patientId`, `firstName`, `lastName`, `dateOfBirth`, `timezone`, `deviceSerialNumber`, `batteryLevel`, `isOnline` | `fullName`, `age` getter'ları; `copyWith`, `fromJson`/`toJson` |
| `Medication` | `medicationId`, `patientId`, `medicationName`, `pillBarcode`, `remainingCount`, `lowStockThreshold`, `expiryDate` | `isLowStock`, `isExpired` getter'ları |
| `MedicationSchedule` | `scheduleId`, `medicationId`, `plannedTime` (TimeOfDay), `dosageQuantity`, `isActive`, `startDate`, `endDate`, `slotId` | `formattedTime` getter'ı; API'dan joined field destekli `fromJson` |

### 4.4 Servis Katmanı

#### `ApiService` (Tekli — singleton)
Pi'nin Flask API'sine (`http://172.20.10.3:5000`) HTTP istekleri gönderir. `GET`, `POST`, `PUT`, `DELETE` için tekrar kullanılan yardımcı metodlar mevcuttur. Zaman aşımı 15 saniyedir (sync işlemleri için 30 saniye). Desteklenen uç noktalar:

- **Health:** `GET /api/health`
- **Hastalar:** `GET/POST /api/patients`, `GET/PUT/DELETE /api/patients/{id}`
- **İlaçlar:** `GET /api/medications/{patientId}`, `POST /api/medications`
- **Çizelgeler:** `GET /api/schedules/{patientId}`, `POST /api/schedules`, `DELETE /api/schedules/{id}`
- **Dağıtım logları:** `GET/POST /api/dispensing-logs/{patientId}`
- **Senkronizasyon:** `GET /api/sync/status`, `POST /api/sync`, `POST /api/sync/push`, `POST /api/sync/pull`

#### `AuthService` (Tekli — singleton)
Pi'nin `/api/auth/login` ve `/api/auth/signup` uç noktalarına HTTP ile giriş/kayıt yapar. Dönen `AuthResult` nesnesi `role` alanına göre hastayı mı yoksa bakıcıyı mı yönlendireceğini belirler. Şifre doğrulaması: min 8 karakter, büyük harf, küçük harf, rakam zorunlu.

#### `DispenserService` (ChangeNotifier)
Pi'nin `/api/state` uç noktasını **2 saniyede bir** polling ile sorgular. Dağıtıcı durumunu (`DispenserSnapshot`) tüm widget'lara yayınlar. Komut metodları: `bindSlot`, `scanBarcode`, `commitSlot`, `triggerDispense`, `openCamera`, `reset`, `deleteSlot`.

Durum makinesi enum değerleri: `idle → rotating → loadingMode → slotReady → waitingForPatient → faceMatched → dispensing → error`

#### `BLEService`
`flutter_blue_plus` kullanarak Raspberry Pi'nin BLE GATT sunucusuna bağlanır.

**GATT Yapısı:**
- Service UUID: `12345678-1234-1234-1234-1234567890AB`
- Command Char (Write): `ABCD1234-AB12-AB12-AB12-ABCDEF123456`
- Notify Char (Notify): `DCBA4321-DC43-DC43-DC43-DCBA98765432`
- Cihaz adı: `SmartDispenser`

**Komut baytları (mobil → Pi):**

| Komut | Bayt | Açıklama |
|---|---|---|
| `unlock` | `0x01` | Mevcut günün compartmanını aç |
| `lock` | `0x02` | Dağıtıcıyı kapat |
| `statusRequest` | `0x03` | Pi'den durum bilgisi iste |
| `ack` | `0x04` | Olayı onayla |
| `identify` | `0x05` | LED göstergesi yak |
| `bindSlot` | `0x06` | Slot + hasta ID bağla (`[slot_id:1B][patient_id:36B]`) |
| `barcodeIncrement` | `0x07` | Barkod tarama sayısını artır |
| `commitMeds` | `0x08` | İlaç yükleme oturumunu tamamla |
| `triggerDispense` | `0x09` | 15 dakikalık dağıtım penceresini başlat |

**Olay baytları (Pi → mobil):**

| Olay | Bayt | Açıklama |
|---|---|---|
| `pillTaken` | `0xA1` | Hap fiziksel olarak alındı |
| `missedDose` | `0xA2` | Kompartman açıldı ama hap alınmadı |
| `hardwareError` | `0xA3` | Donanım hatası (Byte[1] = hata kodu) |
| `statusResponse` | `0xA4` | Durum sorgusu yanıtı |
| `commandAck` | `0xA5` | Son komut onaylandı |

#### `AuthManager` (Yüz Tanıma)
ML Kit `FaceDetector` ile kamera akışından yüz tespiti yapar. **Canlılık kontrolü** iki adımdan oluşur: 1) Göz kırpma (`leftEyeOpenProbability < 0.4`) ve 2) Kafa hareketi (yaw/pitch > 12°). Başarılı doğrulama sonrasında otomatik olarak `BLEService.sendCommand(BleCommand.unlock)` çağrılır.

> **Not:** `_extractEmbedding()` şu an bir placeholder'dır. Gerçek implementasyon için TFLite + MobileFaceNet modeli entegre edilmeli (TODO).

#### `FirebaseService`
Firebase Realtime Database'e doğrudan erişir. 5 koleksiyon yönetir: `patients`, `medications`, `medication_schedules`, `dispensing_logs`, `patient_caregivers`. Önemli metodlar:
- `watchSchedules(patientId)` → Gerçek zamanlı çizelge stream'i
- `watchLatestLog(patientId)` → Son dağıtım logunun stream'i
- `decrementPillCount()` → Transaction ile ilaç sayısını güvenli azaltır
- `pushDispensingLog()` → Log kaydı ekler

#### `LocalDatabase` (SQLite — Tekli)
`sqflite` ile 3 tablo yönetir:

| Tablo | Amaç |
|---|---|
| `local_users` | Çevrimdışı yüz kimlik doğrulama için yüz embedding'i saklar (virgülle ayrılmış float dizisi) |
| `local_schedules` | Firebase'den önbelleğe alınan çizelgeler (çevrimdışı görüntüleme) |
| `sync_queue` | Çevrimdışıyken kaydedilen olaylar — Firebase'e yüklenmek üzere kuyrukta bekler |

### 4.5 Ekranlar

| Ekran | Rol | Önemli Özellikler |
|---|---|---|
| `LoginPage` | Tüm kullanıcılar | E-posta + şifre girişi; rol bazlı yönlendirme (hasta/bakıcı) |
| `SignupPage` | Tüm kullanıcılar | Yeni hesap oluşturma; model ID ile yüz modeli bağlama |
| `PatientDashboard` | Hasta | Günlük çizelge görüntüleme; BLE bağlantısı; ilaç dağıtım tetikleme |
| `CaregiverDashboard` | Bakıcı | Tüm hasta listesi; Pi bağlantı durumu; bulut senkronizasyon |
| `PatientManagement` | Bakıcı | Hasta ekleme, düzenleme, silme |
| `DrugManagement` | Bakıcı | İlaç ekleme; barkod ile tarama; stok takibi |
| `ScheduleManagement` | Bakıcı | İlaç çizelgesi oluşturma ve yönetimi |
| `DispenserControl` | Bakıcı | Fiziksel slot bağlama; barkod tarama ile ilaç yükleme; dağıtım tetikleme; Pi durum izleme |
| `FaceRegistration` | Bakıcı | Hasta yüzünü kameradan kaydeder; embedding SQLite'a kaydeder |

---

## 5. Raspberry Pi Backend

### 5.1 Flask REST API (`api_server.py`)

Pi üzerinde `http://172.20.10.3:5000` adresinde çalışır. Singleton `DispenserStateMachine` örneğini yönetir. Tüm uç noktalar:

| Metod | Uç Nokta | Açıklama |
|---|---|---|
| GET | `/api/state` | Mevcut dağıtıcı durumu |
| POST | `/api/bind-slot` | Hastayı fiziksel slota bağla |
| POST | `/api/barcode` | Barkod tarama oturumu |
| POST | `/api/commit-slot` | İlaç yüklemeyi tamamla |
| POST | `/api/trigger-dispense` | Dağıtım penceresini başlat |
| POST | `/api/camera/open` | Yüz doğrulama kamerasını aç |
| POST | `/api/reset` | Hata durumundan IDLE'a sıfırla |
| GET | `/api/slots` | Tüm slotların listesi |
| GET | `/api/slots/{id}/medications` | Slottaki ilaçlar |
| GET | `/api/face-auth-logs` | Yüz doğrulama geçmişi |
| DELETE | `/api/slots/{id}` | Slotu sil |
| GET | `/api/health` | Sağlık kontrolü |
| GET/POST | `/api/sync/*` | Bulut senkronizasyon |
| POST | `/api/auth/login` | Kullanıcı girişi |
| POST | `/api/auth/signup` | Kullanıcı kaydı |
| POST | `/api/patients` | Hasta oluştur |
| GET/PUT/DELETE | `/api/patients/{id}` | Hasta CRUD |

### 5.2 Durum Makinesi (`state_machine.py`)

Thread-safe (`threading.Lock`) durum geçişleri. Toplam **14 slot** desteklenir.

```
IDLE
  │ bind_slot()
  ▼
ROTATING (motor çalışıyor)
  │ slot hedefine ulaşıldı
  ▼
LOADING_MODE (barkod taramaya hazır)
  │ increment_barcode() × N
  ▼
SLOT_READY (yükleme onaylandı)
  │ commit_slot()
  ▼ (veya trigger_dispense())
WAITING_FOR_PATIENT (5 dakika pencere)
  │ yüz tanıma başarılı
  ▼
FACE_MATCHED
  │ servo aç
  ▼
DISPENSING (hap alınıyor)
  │ tamamlandı
  ▼
IDLE

Herhangi bir durumdan → ERROR → reset() ile IDLE
```

### 5.3 Motor Kontrolü (`motor_controller.py`)

Continuous rotation servo motor; `lgpio` kütüphanesi ile BCM GPIO 18 üzerinden 50 Hz PWM sinyaliyle kontrol edilir.

| Parametre | Değer |
|---|---|
| Toplam slot sayısı | 14 |
| Slot başına açı | 25.714° |
| Slot başına süre | 0.6 saniye |
| Tam tur süresi | 8.4 saniye |
| Durdurma duty cycle | %7.5 |
| CW duty cycle | %8.5 |
| CCW duty cycle | %6.5 |

`DRY_RUN=1` ortam değişkeni ile donanımsız simülasyon modu desteklenir.

### 5.4 Yüz Doğrulama (`face_auth_headless.py`)

`face_recognition` kütüphanesi (dlib tabanlı) ve isteğe bağlı MediaPipe ile çalışır.

- **Eşik:** Öklid mesafesi ≤ 0.4 → skor ≥ 0.6 (başarılı)
- **Canlılık tespiti:** Göz açıklık oranı (EAR) ve ağız açıklık oranı (MAR) ile kırpma + ağız hareketi
- **Çoklu örnek:** `face_samples` tablosu mevcutsa birden fazla yüz fotoğrafıyla karşılaştırma; aksi takdirde `local_users` tablosundaki ortalama vektör kullanılır
- **Liveness süresi:** 5 saniye

### 5.5 Senkronizasyon (`sync_service.py`)

Pi ile AWS Lambda API arasında çift yönlü senkronizasyon. Pi üzerindeki yerel SQLite veritabanındaki dağıtım logları ve hasta bilgileri periyodik olarak AWS'ye push edilir; AWS'deki güncel çizelgeler Pi'ye pull edilir.

### 5.6 BLE Sunucu (`ble_server.py`)

Python `bluez`/`dbus` tabanlı GATT sunucu. Mobil uygulamanın `BLEService`'i ile uyumlu aynı UUID'leri kullanır. Motor komutlarını ve yüz doğrulama akışını tetikler.

---

## 6. AWS Bulut Bileşeni (`FENS-Drug_Dispenser/`)

**FastAPI** tabanlı REST API, AWS Lambda üzerinde çalışır ve API Gateway ile dışarıya açılır.

- **Base URL:** `https://s766ccq1c7.execute-api.eu-north-1.amazonaws.com/default`
- **Bölge:** eu-north-1 (Stockholm)
- Hastalar, ilaçlar, çizelgeler ve dağıtım logları için CRUD uç noktaları
- `face_authentication/` dizini: Bulut tarafı yüz doğrulama (tek fotoğraf, yutma modu vb.)

---

## 7. Firebase Realtime Database Yapısı

```
/
├── patients/
│   └── {patientId}/
│       ├── patient_id, first_name, last_name, date_of_birth
│       ├── timezone (varsayılan: "Europe/Istanbul")
│       ├── device_serial_number
│       ├── battery_level, is_online, last_seen_at
│
├── medications/
│   └── {medicationId}/
│       ├── medication_id, patient_id, medication_name
│       ├── pill_barcode, pill_color_shape, pill_image_url
│       └── remaining_count, low_stock_threshold, expiry_date
│
├── medication_schedules/
│   └── {scheduleId}/
│       ├── schedule_id, medication_id
│       ├── planned_time (HH:MM), dosage_quantity
│       ├── is_active, start_date, end_date
│
├── dispensing_logs/
│   └── {logId}/
│       ├── log_id, patient_id, schedule_id
│       ├── status (taken/missed/error/manual)
│       ├── face_auth_score, device_timestamp, error_details
│
└── patient_caregivers/
    └── {mappingId}/
        └── patient_id, caregiver_id
```

---

## 8. Çevrimdışı-Öncelikli (Offline-First) Mimari

Ağ bağlantısı kesildiğinde uygulama çalışmaya devam eder:

1. **Yüz Embedding:** `LocalDatabase.local_users` tablosunda saklanır → ağ olmadan da kimlik doğrulama yapılabilir.
2. **Çizelge Önbelleği:** `local_schedules` tablosu Firebase'den çekilen verileri saklar.
3. **Sync Kuyruğu:** Çevrimdışıyken oluşan dağıtım logları `sync_queue` tablosuna yazılır. Bağlantı geri geldiğinde `SyncQueueManager` bunları Firebase'e yükler, başarısız yüklemeler için `retry_count` artar.
4. **`connectivity_plus`:** Çevrimiçi/çevrimdışı durum izlenir ve senkronizasyon stratejisi buna göre belirlenir.

---

## 9. Kullanıcı Rolleri ve Akışlar

### Bakıcı (Caregiver) Akışı
```
Giriş → Bakıcı Dashboard
  ├── Hasta Yönetimi (ekle / düzenle / sil)
  ├── İlaç Yönetimi (ilaç ekle, barkod tara, stok güncelle)
  ├── Çizelge Yönetimi (zaman ve doz belirle)
  ├── Dağıtıcı Kontrolü
  │     ├── Slot bağla (hasta → fiziksel slot)
  │     ├── Barkod tarayarak ilaç yükle
  │     ├── Yüklemeyi tamamla
  │     └── Dağıtımı tetikle
  ├── Yüz Kaydı (kameradan hasta yüzü kaydet)
  └── Bulut Senkronizasyon (Pi ↔ AWS)
```

### Hasta Akışı
```
Giriş → Hasta Dashboard
  ├── Günlük ilaç çizelgesini görüntüle
  ├── BLE ile dağıtıcıya bağlan
  ├── Yüz doğrulamayı geç (kamera açılır)
  └── Dağıtıcı slotu otomatik açılır
```

---

## 10. Bağımlılıklar (Flutter)

| Paket | Sürüm | Amaç |
|---|---|---|
| `flutter_blue_plus` | ^1.35.3 | BLE GATT bağlantısı |
| `camera` | ^0.11.1 | Kamera stream'i (yüz doğrulama) |
| `google_mlkit_face_detection` | ^0.12.0 | ML Kit yüz tespiti |
| `local_auth` | ^2.3.0 | Biyometrik yedek kimlik doğrulama |
| `firebase_core` | ^3.13.0 | Firebase başlatma |
| `firebase_database` | ^11.3.4 | Realtime Database |
| `firebase_auth` | ^5.5.2 | Firebase Auth (şu an aktif değil) |
| `sqflite` | ^2.4.2 | Yerel SQLite veritabanı |
| `connectivity_plus` | ^6.1.4 | Ağ bağlantısı izleme |
| `permission_handler` | ^11.4.0 | Runtime izin yönetimi |
| `mobile_scanner` | ^6.0.2 | Kamera tabanlı barkod tarama |
| `http` | ^1.6.0 | HTTP istemcisi |
| `uuid` | ^4.5.1 | UUID üretimi |

---

## 11. Eksik / Yapılacaklar (TODO)

Proje kodunda tespit edilen tamamlanmamış veya geliştirme notu içeren kısımlar:

1. **TFLite Yüz Embedding** — `AuthManager._extractEmbedding()` şu an rastgele vektör döndürüyor. MobileFaceNet gibi bir TFLite modeli entegre edilmeli.
2. **Firebase Auth entegrasyonu** — `firebase_auth` paketi eklenmiş ama henüz kullanılmıyor. Oturum yönetimi `AppSession` singleton ile manuel yapılıyor.
3. **`main.dart`'ta Firebase.initializeApp()** — Firebase başlatma kodu eksik.
4. **Push notification** — İlaç hatırlatmaları için henüz bildirim sistemi yok.
5. **State management** — Yorum ve mimari belgede Provider / ValueNotifier planlandığı belirtilmiş ancak henüz uygulanmamış; durum doğrudan `setState` ile yönetiliyor.
6. **`medication_name` local_schedules'ta boş** — `LocalDatabase.replaceSchedules()` metodunda `medication_name` alanı boş bırakılıyor.
7. **Biometrik yedek auth** — `local_auth` paketi eklenmiş ama `AuthManager`'da fallback olarak henüz devreye alınmamış.

---

## 12. Donanım Özeti

| Bileşen | Model / Özellik | Kullanım Amacı |
|---|---|---|
| Ana kart | **Raspberry Pi 5 — 16 GB RAM** | Flask API, durum makinesi, yüz doğrulama, BLE sunucu, senkronizasyon servislerini çalıştırır |
| Kamera | **Raspberry Pi AI Camera** | Gerçek zamanlı yüz tanıma; dahili ISP + AI işleme hızlandırıcısı sayesinde `face_recognition` + MediaPipe düşük gecikmeli çalışır |
| Ekran | **5 inç Dokunmatik Monitör** | Kiosk uygulaması (`kiosk_app.py` / `display_ui.py`); hasta kimlik doğrulama durumu ve dağıtıcı geri bildirimi gösterilir |
| Motor | **Tower Pro SG90 — 360° Continuous Rotation** | 14 slotlu döner tepsiyi sürer; BCM GPIO 18 üzerinden 50 Hz PWM; CW `%8.5`, CCW `%6.5`, Dur `%7.5` duty cycle |
| Depolama | **Micro SD Kart — 128 GB** | Raspberry Pi OS, Python ortamı, SQLite `faces.db`, MediaPipe model dosyası ve sistem logları |
| Bluetooth | Pi 5 dahili BLE modülü | `ble_server.py` ile GATT sunucu; mobil uygulama ile `SmartDispenser` adıyla keşfedilir |

### Motor Bağlantı Şeması (Tower Pro SG90)

```
Raspberry Pi 5 GPIO Header (BOARD numaralandırma)
  Pin  2  ──►  Servo  +5V  (kırmızı kablo)
  Pin  6  ──►  Servo  GND  (siyah/kahverengi kablo)
  Pin 12  ──►  Servo  PWM  (turuncu/sarı kablo)  ←── BCM GPIO 18
```

### Raspberry Pi AI Camera Notları

Pi AI Camera (Sony IMX500 sensörlü), dahili nöral ağ işleme birimi sayesinde CPU yükünü azaltır. `pi_camera.py` sarmalayıcısı kamera akışını `face_auth_headless.py`'ye iletir. MediaPipe yüz landmark modeli (`face_landmarker.task`) ve `face_recognition` (dlib) bu kamera ile düşük gecikmeli çalışacak şekilde yapılandırılmıştır.

---

## 13. Güvenlik Mimarisi

- **Yüz Doğrulama:** İlaç alımı öncesinde zorunlu (skor ≥ 0.6 / uzaklık ≤ 0.4)
- **Canlılık Tespiti:** Fotoğrafla kandırmayı önlemek için göz kırpma + kafa hareketi
- **Rol tabanlı erişim:** Bakıcı ve hasta farklı ekranlara yönlendirilir
- **Şifre politikası:** Min. 8 karakter, büyük+küçük harf + rakam zorunlu
- **Çevrimdışı embedding:** Yüz verisi cihazda şifreli saklanmaz (potansiyel güvenlik açığı)
- **BLE güvenliği:** Şu an şifreleme/pairing olmadan açık GATT kullanılıyor (TODO)

---

## 14. Özet

MediDispense, birden fazla teknik katmanı bir araya getiren kapsamlı bir IoT + mobil uygulama projesidir. Flutter ile geliştirilen mobil uygulama; BLE, REST API, Firebase ve yerel SQLite üzerinden Raspberry Pi donanımıyla entegre çalışır. Pi tarafında state machine mimarisi, servo motor kontrolü, gerçek zamanlı yüz doğrulama ve AWS bulut senkronizasyonu birlikte çalışmaktadır. Proje; offline-first yaklaşım, rol tabanlı kullanıcı yönetimi ve çift yönlü veri senkronizasyonu açısından üst düzey bir mimari sergilemektedir.
