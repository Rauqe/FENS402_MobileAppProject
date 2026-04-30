-- Enable UUID generation
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ─────────────────────────────────────────
-- Roles
-- ─────────────────────────────────────────
CREATE TABLE roles (
    role_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    role_type        VARCHAR(50) NOT NULL,   -- 'doctor', 'nurse', 'caregiver', 'admin'
    first_name       VARCHAR(50) NOT NULL,
    last_name        VARCHAR(50) NOT NULL,
    phone_number     VARCHAR(20),
    email            VARCHAR(100) UNIQUE NOT NULL,
    password         VARCHAR(255) NOT NULL,  -- hashed
    app_last_login   TIMESTAMP
);

-- ─────────────────────────────────────────
-- Patients
-- ─────────────────────────────────────────
CREATE TABLE patients (
    patient_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    first_name           VARCHAR(50) NOT NULL,
    last_name            VARCHAR(50) NOT NULL,
    date_of_birth        DATE,
    timezone             VARCHAR(50) DEFAULT 'Europe/Istanbul',
    device_serial_number VARCHAR(100) UNIQUE,
    battery_level        SMALLINT,
    is_online            BOOLEAN DEFAULT FALSE,
    last_seen_at         TIMESTAMP
);

-- ─────────────────────────────────────────
-- Patient_Caregivers (Roles ↔ Patients)
-- ─────────────────────────────────────────
CREATE TABLE patient_caregivers (
    mapping_id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id            UUID NOT NULL REFERENCES patients(patient_id) ON DELETE CASCADE,
    role_id               UUID NOT NULL REFERENCES roles(role_id) ON DELETE CASCADE,
    access_level          VARCHAR(50),        -- 'read', 'write', 'admin'
    relationship_type     VARCHAR(50),        -- 'doctor', 'family', 'nurse'
    notification_settings JSONB
);

-- ─────────────────────────────────────────
-- Medications
-- ─────────────────────────────────────────
CREATE TABLE medications (
    medication_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id          UUID NOT NULL REFERENCES patients(patient_id) ON DELETE CASCADE,
    medication_name     VARCHAR(100) NOT NULL,
    pill_image_url      VARCHAR(500),         -- S3 URL
    pill_box_image      VARCHAR(500),         -- S3 URL
    pill_barcode        VARCHAR(100),
    pill_color_shape    VARCHAR(100),
    remaining_count     SMALLINT DEFAULT 0,
    low_stock_threshold SMALLINT DEFAULT 5,
    expiry_date         DATE
);

-- ─────────────────────────────────────────
-- Medication_Schedules
-- ─────────────────────────────────────────
CREATE TABLE medication_schedules (
    schedule_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    medication_id   UUID NOT NULL REFERENCES medications(medication_id) ON DELETE CASCADE,
    planned_time    TIME NOT NULL,
    dosage_quantity SMALLINT DEFAULT 1,
    is_active       BOOLEAN DEFAULT TRUE,
    start_date      DATE NOT NULL,
    end_date        DATE
);

-- ─────────────────────────────────────────
-- Dispensing_Logs
-- ─────────────────────────────────────────
CREATE TABLE dispensing_logs (
    log_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id       UUID NOT NULL REFERENCES patients(patient_id) ON DELETE CASCADE,
    schedule_id      UUID REFERENCES medication_schedules(schedule_id),
    status           VARCHAR(20) NOT NULL,    -- 'dispensed', 'taken', 'missed', 'error'
    face_auth_score  FLOAT,                   -- face recognition distance score
    dispensing_at    TIMESTAMP DEFAULT NOW(), -- when machine dispensed the pill
    taken_at         TIMESTAMP,              -- when patient actually took the pill
    device_timestamp TIMESTAMP,              -- timestamp from the Pi device
    error_details    TEXT
);