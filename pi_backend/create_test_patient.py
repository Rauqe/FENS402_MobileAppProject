#!/usr/bin/env python3
"""
Quick script to create a test Patient account + data on the Pi.
"""

from auth import create_user
import sqlite3
import os
from datetime import datetime, timezone

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LOCAL_DB = os.path.join(_SCRIPT_DIR, "faces.db")

# Create test patient account
result = create_user(
    email="patient@test.com",
    password="Patient123",
    role="patient",
)

if not result.get("ok"):
    print(f"\n❌ Error: {result.get('message')}")
    print("Make sure you ran: python3 bootstrap_pi_backend.py")
    exit(1)

# Also add to patients table for the app
try:
    conn = sqlite3.connect(LOCAL_DB)
    conn.execute(
        """
        INSERT INTO patients (patient_id, first_name, last_name, date_of_birth, created_at)
        VALUES (?, ?, ?, ?, ?)
        """,
        ("test-patient-001", "John", "Doe", "1990-05-15", datetime.now(timezone.utc).isoformat()),
    )
    conn.commit()
    conn.close()
except Exception as e:
    print(f"⚠️ Warning adding to patients table: {e}")

print("\n✅ Test Patient Account Created")
print(f"Email:    {result.get('email', 'patient@test.com')}")
print(f"Password: Patient123")
print(f"Role:     {result.get('role', 'patient')}")
print(f"\nPatient ID: test-patient-001")
print("First Name: John")
print("Last Name: Doe")
print("\nUse these credentials to login on the iPhone app.\n")
