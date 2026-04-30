-- =============================================================================
-- MediDispense — SAFE AWS Migration
-- Mevcut tablolara dokunmaz, sadece eksik sütun/tablo ekler.
-- Mobil uygulama API'lerini bozmaz.
-- pgAdmin Query Tool'da F5 ile çalıştır.
-- =============================================================================

-- =============================================================================
-- 1. patients — eksik sync sütunlarını ekle
--    (email, password, token, timezone, device_serial_number vb. KORUNUR)
-- =============================================================================
ALTER TABLE patients ADD COLUMN IF NOT EXISTS deleted_at      TEXT;
ALTER TABLE patients ADD COLUMN IF NOT EXISTS cloud_synced_at TEXT;
ALTER TABLE patients ADD COLUMN IF NOT EXISTS created_at      TEXT;

-- =============================================================================
-- 2. medications — eksik sync sütunlarını ekle
--    Orijinal şemada slot_id zaten var, onu koruyoruz.
-- =============================================================================
ALTER TABLE medications ADD COLUMN IF NOT EXISTS cloud_synced_at TEXT;
ALTER TABLE medications ADD COLUMN IF NOT EXISTS created_at      TEXT;

-- =============================================================================
-- 3. medication_schedules — KRİTİK DÜZELTME
--    medication_id NOT NULL eski şemadan kalma; Pi artık slot-centric çalışıyor
--    ve medication_id göndermez. Bu kısıt olmadan her schedule push fail olur.
-- =============================================================================
ALTER TABLE medication_schedules ALTER COLUMN medication_id DROP NOT NULL;

-- start_date da NOT NULL olabilir, onu da kaldır
ALTER TABLE medication_schedules ALTER COLUMN start_date DROP NOT NULL;

-- Slot-centric mimarinin gerektirdiği yeni sütunlar
ALTER TABLE medication_schedules ADD COLUMN IF NOT EXISTS patient_id      VARCHAR(255);
ALTER TABLE medication_schedules ADD COLUMN IF NOT EXISTS slot_id         INTEGER;
ALTER TABLE medication_schedules ADD COLUMN IF NOT EXISTS frequency_type  TEXT    DEFAULT 'daily';
ALTER TABLE medication_schedules ADD COLUMN IF NOT EXISTS week_days       TEXT    DEFAULT '';
ALTER TABLE medication_schedules ADD COLUMN IF NOT EXISTS window_seconds  INTEGER DEFAULT 300;
ALTER TABLE medication_schedules ADD COLUMN IF NOT EXISTS group_id        VARCHAR(255);

-- =============================================================================
-- 4. dispensing_logs — eksik sütun kontrolü (genellikle tam, yine de güvenli)
-- =============================================================================
ALTER TABLE dispensing_logs ADD COLUMN IF NOT EXISTS device_timestamp TEXT;
ALTER TABLE dispensing_logs ADD COLUMN IF NOT EXISTS error_details    TEXT;

-- =============================================================================
-- 5. YENİ TABLOLAR — sadece yoksa oluştur
-- =============================================================================

-- slot_bindings: Pi'deki fiziksel slot ↔ hasta eşleşmesi
CREATE TABLE IF NOT EXISTS slot_bindings (
    slot_id    INTEGER      PRIMARY KEY,
    patient_id VARCHAR(255),
    status     VARCHAR(50)  DEFAULT 'empty',
    updated_at TEXT
);

-- slot_medications: slota yüklenen ilaçlar
CREATE TABLE IF NOT EXISTS slot_medications (
    id              SERIAL       PRIMARY KEY,
    slot_id         INTEGER      NOT NULL,
    patient_id      VARCHAR(255),
    medication_id   VARCHAR(255) NOT NULL,
    medication_name TEXT,
    barcode         TEXT,
    target_count    INTEGER      DEFAULT 1,
    loaded_count    INTEGER      DEFAULT 0,
    updated_at      TEXT
);

-- users: uygulama hesapları (Pi tarafından yönetilir)
CREATE TABLE IF NOT EXISTS users (
    id              SERIAL       PRIMARY KEY,
    email           VARCHAR(255) UNIQUE NOT NULL,
    password_hash   TEXT         NOT NULL,
    role            VARCHAR(50)  NOT NULL DEFAULT 'patient',
    patient_id      VARCHAR(255),
    created_at      TEXT,
    cloud_synced_at TEXT
);

-- =============================================================================
-- 6. İndeksler — sorgu performansı için
-- =============================================================================
CREATE INDEX IF NOT EXISTS idx_medications_patient     ON medications (patient_id);
CREATE INDEX IF NOT EXISTS idx_schedules_patient       ON medication_schedules (patient_id);
CREATE INDEX IF NOT EXISTS idx_schedules_slot          ON medication_schedules (slot_id);
CREATE INDEX IF NOT EXISTS idx_schedules_group         ON medication_schedules (group_id);
CREATE INDEX IF NOT EXISTS idx_slot_meds_slot          ON slot_medications (slot_id);
CREATE INDEX IF NOT EXISTS idx_dispensing_logs_patient ON dispensing_logs (patient_id);

-- =============================================================================
-- Doğrulama: Çalıştırdıktan sonra şu tabloların var olduğunu kontrol et:
--   SELECT table_name FROM information_schema.tables
--   WHERE table_schema = 'public' ORDER BY table_name;
-- Beklenen tablolar:
--   dispensing_logs, medication_schedules, medications, patient_caregivers,
--   patients, roles, slot_bindings, slot_medications, users
-- =============================================================================
