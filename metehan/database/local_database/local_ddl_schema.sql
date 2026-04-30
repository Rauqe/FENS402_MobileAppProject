-- Local Users (face embeddings)
CREATE TABLE IF NOT EXISTS local_users (
    patient_id   TEXT PRIMARY KEY,  -- matches cloud patients.patient_id (UUID)
    first_name   TEXT NOT NULL,
    last_name    TEXT NOT NULL,
    vector       BLOB NOT NULL      -- face_recognition 128-dim embedding
);

-- Local Schedules (synced from cloud, used offline)
CREATE TABLE IF NOT EXISTS local_schedules (
    schedule_id     TEXT PRIMARY KEY,  -- matches cloud medication_schedules.schedule_id
    patient_id      TEXT NOT NULL,
    planned_time    TEXT NOT NULL,     -- HH:MM format
    dosage_quantity INTEGER DEFAULT 1,
    is_active       INTEGER DEFAULT 1, -- SQLite has no BOOLEAN, 0/1
    start_date      TEXT NOT NULL,     -- YYYY-MM-DD
    end_date        TEXT               -- YYYY-MM-DD
);

-- Sync Queue (logs waiting to be sent to cloud)
CREATE TABLE IF NOT EXISTS sync_queue (
    log_id           TEXT PRIMARY KEY,  -- UUID generated locally
    schedule_id      TEXT,
    patient_id       TEXT NOT NULL,
    status           TEXT NOT NULL,     -- 'dispensed', 'taken', 'missed', 'error'
    face_auth_score  REAL,
    dispensing_at    TEXT,              -- ISO timestamp
    taken_at         TEXT,              -- ISO timestamp
    device_timestamp TEXT,
    error_details    TEXT,
    is_synced        INTEGER DEFAULT 0, -- 0 = waiting, 1 = synced
    retry_count      INTEGER DEFAULT 0
);