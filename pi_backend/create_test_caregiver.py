#!/usr/bin/env python3
"""
Quick script to create a test Caregiver account on the Pi.
Run this once, then use the credentials to login on the iPhone app.
"""

from auth import create_user

# Create test caregiver
result = create_user(
    email="caregiver@test.com",
    password="TestPass123",
    role="caregiver",
)

if not result.get("ok"):
    print(f"\n❌ Error: {result.get('message')}")
    print("\nMake sure you ran: python3 bootstrap_pi_backend.py")
    exit(1)

print("\n✅ Test Caregiver Account Created")
print(f"Email:    {result.get('email', 'caregiver@test.com')}")
print(f"Password: TestPass123")
print(f"Role:     {result.get('role', 'caregiver')}")
print("\nUse these credentials to login on the iPhone app.\n")
