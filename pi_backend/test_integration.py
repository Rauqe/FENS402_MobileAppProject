#!/usr/bin/env python3
"""
Integration test for the full MediDispense workflow.

Tests state machine transitions without hardware (dry-run mode).
Simulates: bind slot → scan barcodes → commit → trigger dispense → face auth → dispense → reset
"""

import sys
import os
import json
from datetime import datetime

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _SCRIPT_DIR)

from state_machine import DispenserStateMachine, DispenserState


class Colors:
    PASS = '\033[92m'
    FAIL = '\033[91m'
    INFO = '\033[94m'
    RESET = '\033[0m'


def log(msg: str, level: str = 'info'):
    prefix = {
        'info': f'{Colors.INFO}[test]{Colors.RESET}',
        'pass': f'{Colors.PASS}[✓]{Colors.RESET}',
        'fail': f'{Colors.FAIL}[✗]{Colors.RESET}',
    }.get(level, '[test]')
    print(f'{prefix} {msg}')


def assert_state(sm: DispenserStateMachine, expected: DispenserState, msg: str):
    if sm.state == expected:
        log(f'{msg} → state={expected.value}', 'pass')
        return True
    else:
        log(f'{msg} → expected {expected.value}, got {sm.state.value}', 'fail')
        return False


def test_full_workflow():
    """Run the complete workflow: bind → barcode → commit → dispense → reset."""
    log('Starting full integration test', 'info')
    print()

    sm = DispenserStateMachine(motor_controller=None)
    tests_passed = 0
    tests_total = 0

    # Test 1: Initial state
    tests_total += 1
    if assert_state(sm, DispenserState.IDLE, 'Initial state'):
        tests_passed += 1
    print()

    # Test 2: Bind slot
    tests_total += 1
    log('Binding patient to slot 2...', 'info')
    result = sm.bind_slot(
        patient_id='patient-001',
        slot_id=2,
        patient_name='John Doe'
    )
    log(f'Result: {result["message"]}', 'info')
    if assert_state(sm, DispenserState.ROTATING, 'After bind_slot'):
        tests_passed += 1
    print()

    # Wait for motor (it runs in background thread, simulated instantly)
    import time
    time.sleep(0.5)
    tests_total += 1
    if assert_state(sm, DispenserState.LOADING_MODE, 'After rotation completes'):
        tests_passed += 1
    print()

    # Test 3: Scan barcodes
    tests_total += 1
    log('Scanning 3 pills...', 'info')
    barcodes = ['4006381333931', '5412810169298', '6900002512341']
    for i, barcode in enumerate(barcodes, 1):
        result = sm.increment_barcode(barcode)
        log(f'  Pill {i}: {barcode} → count={result["count"]}', 'info')

    if sm.snapshot.barcode_count == 3:
        log(f'Barcode count correct: {sm.snapshot.barcode_count}', 'pass')
        tests_passed += 1
    else:
        log(f'Expected 3 barcodes, got {sm.snapshot.barcode_count}', 'fail')
    print()

    # Test 4: Commit slot
    tests_total += 1
    log('Committing slot...', 'info')
    result = sm.commit_slot()
    log(f'Result: {result["message"]}', 'info')
    if assert_state(sm, DispenserState.SLOT_READY, 'After commit_slot'):
        tests_passed += 1
    print()

    # Test 5: Trigger dispense
    tests_total += 1
    log('Triggering dispense (5-min window)...', 'info')
    result = sm.trigger_dispense(patient_id='patient-001', window_seconds=5)
    log(f'Result: {result["message"]}', 'info')
    if assert_state(sm, DispenserState.WAITING_FOR_PATIENT, 'After trigger_dispense'):
        tests_passed += 1
    print()

    # Test 6: Face authentication success
    tests_total += 1
    log('Simulating successful face recognition...', 'info')
    result = sm.on_face_matched(
        matched_patient_id='patient-001',
        score=0.85,
        name='John Doe',
        liveness_ok=True
    )
    log(f'Result: {result["message"]}', 'info')
    if assert_state(sm, DispenserState.FACE_MATCHED, 'After on_face_matched'):
        tests_passed += 1
    print()

    # Test 7: Dispense
    tests_total += 1
    log('Dispensing medication...', 'info')
    result = sm.dispense()
    log(f'Result: {result["message"]}', 'info')
    time.sleep(0.5)  # Wait for dispense thread
    if assert_state(sm, DispenserState.IDLE, 'After dispense completes'):
        tests_passed += 1
    print()

    # Test 8: Query endpoints
    tests_total += 1
    log('Testing query endpoints...', 'info')
    slots = DispenserStateMachine.get_all_slots()
    log(f'  get_all_slots() → {len(slots)} slot(s)', 'info')
    meds = DispenserStateMachine.get_slot_medications(2)
    log(f'  get_slot_medications(2) → {len(meds)} medication(s)', 'info')
    if len(meds) == 3:
        log('Medications query correct', 'pass')
        tests_passed += 1
    else:
        log(f'Expected 3 meds, got {len(meds)}', 'fail')
    print()

    # Test 9: Reset from IDLE
    tests_total += 1
    log('Resetting from IDLE...', 'info')
    result = sm.reset()
    if assert_state(sm, DispenserState.IDLE, 'After reset from IDLE'):
        tests_passed += 1
    print()

    # Test 10: Error recovery
    tests_total += 1
    log('Testing error recovery...', 'info')
    sm.bind_slot(patient_id='patient-002', slot_id=3, patient_name='Jane Smith')
    time.sleep(0.5)
    sm._set_state(DispenserState.ERROR, 'simulated error')
    log(f'  State is now: {sm.state.value}', 'info')
    result = sm.reset()
    if assert_state(sm, DispenserState.IDLE, 'After reset from ERROR'):
        tests_passed += 1
    print()

    # Summary
    print('=' * 60)
    pct = (tests_passed / tests_total * 100) if tests_total > 0 else 0
    summary = f'{tests_passed}/{tests_total} tests passed ({pct:.0f}%)'
    if tests_passed == tests_total:
        log(summary, 'pass')
        return 0
    else:
        log(summary, 'fail')
        return 1


if __name__ == '__main__':
    try:
        exit_code = test_full_workflow()
        sys.exit(exit_code)
    except Exception as e:
        log(f'Test crashed: {e}', 'fail')
        import traceback
        traceback.print_exc()
        sys.exit(1)
