#!/bin/bash
# Quick setup verification script for Pi backend

echo "🔍 Checking Pi Backend Setup..."
echo

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

checks_passed=0
checks_total=0

# Python version
checks_total=$((checks_total + 1))
if python3 --version &>/dev/null; then
    version=$(python3 --version)
    echo "✓ Python: $version"
    checks_passed=$((checks_passed + 1))
else
    echo "✗ Python 3 not found"
fi

# Required packages
packages=("sqlite3" "cv2" "face_recognition" "numpy")
for pkg in "${packages[@]}"; do
    checks_total=$((checks_total + 1))
    if python3 -c "import $pkg" 2>/dev/null; then
        echo "✓ Module: $pkg"
        checks_passed=$((checks_passed + 1))
    else
        echo "✗ Missing: $pkg (install: pip3 install $pkg)"
    fi
done

# Database
checks_total=$((checks_total + 1))
if [ -f "faces.db" ]; then
    echo "✓ Database: faces.db exists"
    checks_passed=$((checks_passed + 1))
else
    echo "✗ Database: faces.db not found (run: python3 bootstrap_pi_backend.py)"
fi

# Face model
checks_total=$((checks_total + 1))
if [ -f "face_landmarker.task" ]; then
    echo "✓ Model: face_landmarker.task exists"
    checks_passed=$((checks_passed + 1))
else
    echo "✗ Model: face_landmarker.task not found (run: python3 bootstrap_pi_backend.py)"
fi

# Source files
files=("state_machine.py" "api_server.py" "register.py" "face_auth_headless.py" "motor_controller.py" "ble_server.py")
for file in "${files[@]}"; do
    checks_total=$((checks_total + 1))
    if [ -f "$file" ]; then
        echo "✓ File: $file"
        checks_passed=$((checks_passed + 1))
    else
        echo "✗ Missing: $file"
    fi
done

echo
echo "=========================================="
result="$checks_passed/$checks_total checks passed"
if [ "$checks_passed" -eq "$checks_total" ]; then
    echo "✓ Setup OK! Ready to test."
    echo
    echo "Next steps:"
    echo "  1. Run tests: python3 test_integration.py"
    echo "  2. Start API: python3 api_server.py"
    echo "  3. Test API: python3 test_api.py"
    exit 0
else
    echo "✗ Setup incomplete: $result"
    echo
    echo "To fix:"
    echo "  python3 bootstrap_pi_backend.py"
    echo "  pip3 install -r requirements.txt  (if you have one)"
    exit 1
fi
