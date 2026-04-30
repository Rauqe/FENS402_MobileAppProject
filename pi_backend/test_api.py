#!/usr/bin/env python3
"""
Test the Flask API endpoints.

Run the API server in one terminal:
    python3 api_server.py

Then in another terminal:
    python3 test_api.py
"""

import os
import requests
import json
import time
from typing import Any

BASE_URL = 'http://localhost:5000'
TIMEOUT = 5

class Colors:
    PASS = '\033[92m'
    FAIL = '\033[91m'
    INFO = '\033[94m'
    RESET = '\033[0m'


def log(msg: str, level: str = 'info'):
    prefix = {
        'info': f'{Colors.INFO}[api-test]{Colors.RESET}',
        'pass': f'{Colors.PASS}[✓]{Colors.RESET}',
        'fail': f'{Colors.FAIL}[✗]{Colors.RESET}',
    }.get(level, '[api-test]')
    print(f'{prefix} {msg}')


def test_endpoint(method: str, path: str, body: dict = None, expect_ok: bool = True) -> Any:
    """Test a single endpoint."""
    url = f'{BASE_URL}{path}'
    try:
        if method == 'GET':
            resp = requests.get(url, timeout=TIMEOUT)
        elif method == 'POST':
            resp = requests.post(url, json=body or {}, timeout=TIMEOUT)
        else:
            raise ValueError(f'Unknown method: {method}')

        data = resp.json()
        ok = data.get('ok', False)

        if ok == expect_ok:
            log(f'{method} {path} → ok={ok}', 'pass')
        else:
            log(f'{method} {path} → expected ok={expect_ok}, got ok={ok}', 'fail')

        return data
    except requests.exceptions.ConnectionError:
        log(f'{method} {path} → connection failed (is API running?)', 'fail')
        return None
    except Exception as e:
        log(f'{method} {path} → error: {e}', 'fail')
        return None


def test_full_api():
    """Test the full API workflow."""
    log('Starting API endpoint tests', 'info')
    print()

    # Health check
    log('1. Health check', 'info')
    test_endpoint('GET', '/api/health', expect_ok=True)
    print()

    # Get initial state
    log('2. Get initial state', 'info')
    state = test_endpoint('GET', '/api/state')
    print()

    # Bind slot
    log('3. Bind slot', 'info')
    result = test_endpoint('POST', '/api/bind-slot', {
        'patient_id': 'patient-001',
        'slot_id': 1,
        'patient_name': 'Alice Brown',
    }, expect_ok=True)
    time.sleep(1)
    print()

    # Scan barcodes
    log('4. Scan barcodes (3x)', 'info')
    for i in range(3):
        barcode = f'barcode-{i+1:03d}'
        test_endpoint('POST', '/api/barcode', {
            'barcode': barcode,
        }, expect_ok=True)
        time.sleep(0.2)
    print()

    # Check state after barcodes
    log('5. Check state after barcodes', 'info')
    state = test_endpoint('GET', '/api/state')
    if state:
        count = state.get('barcode_count', 0)
        log(f'  barcode_count = {count}', 'info')
    print()

    # Commit slot
    log('6. Commit slot', 'info')
    test_endpoint('POST', '/api/commit-slot', {}, expect_ok=True)
    time.sleep(0.5)
    print()

    # Get slots
    log('7. Get all slots', 'info')
    slots = test_endpoint('GET', '/api/slots')
    if slots:
        slot_list = slots.get('slots', [])
        log(f'  Found {len(slot_list)} slot(s)', 'info')
    print()

    # Get slot medications
    log('8. Get medications for slot 1', 'info')
    meds = test_endpoint('GET', '/api/slots/1/medications')
    if meds:
        med_list = meds.get('medications', [])
        log(f'  Found {len(med_list)} medication(s)', 'info')
    print()

    # Trigger dispense
    log('9. Trigger dispense', 'info')
    test_endpoint('POST', '/api/trigger-dispense', {
        'patient_id': 'patient-001',
        'window_seconds': 5,
    }, expect_ok=True)
    time.sleep(0.5)
    print()

    # Check state (should be waiting for patient)
    log('10. Check state (should be WAITING_FOR_PATIENT)', 'info')
    state = test_endpoint('GET', '/api/state')
    if state:
        current_state = state.get('state', 'unknown')
        log(f'  Current state: {current_state}', 'info')
    print()

    # Simulate face match
    log('11. Simulate face authentication (via Python, not HTTP)', 'info')
    log('  (This would normally come from face_auth_headless.py)', 'info')
    try:
        from state_machine import DispenserStateMachine
        import sqlite3
        db_file = os.path.join(os.path.dirname(__file__), 'faces.db')
        # We can't easily call on_face_matched via HTTP, skip for now
        log('  Skipping (requires direct state machine access)', 'info')
    except Exception as e:
        log(f'  Error: {e}', 'fail')
    print()

    # Get face auth logs
    log('12. Get face auth logs (last 10)', 'info')
    logs = test_endpoint('GET', '/api/face-auth-logs?limit=10')
    if logs:
        log_list = logs.get('logs', [])
        log(f'  Found {len(log_list)} log entry/entries', 'info')
    print()

    # Reset
    log('13. Reset to IDLE', 'info')
    test_endpoint('POST', '/api/reset', {}, expect_ok=True)
    print()

    # Final state check
    log('14. Final state check', 'info')
    state = test_endpoint('GET', '/api/state')
    if state:
        current_state = state.get('state', 'unknown')
        log(f'  Final state: {current_state}', 'info')
    print()

    print('=' * 60)
    log('API tests complete!', 'pass')


if __name__ == '__main__':
    try:
        test_full_api()
    except KeyboardInterrupt:
        print()
        log('Tests interrupted', 'fail')
    except Exception as e:
        log(f'Unexpected error: {e}', 'fail')
        import traceback
        traceback.print_exc()
