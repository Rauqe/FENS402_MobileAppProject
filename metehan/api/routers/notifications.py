import boto3
import json
import os
import urllib.request
import urllib.parse
from fastapi import APIRouter, Depends
from api.database import get_aws
from pydantic import BaseModel

router = APIRouter()

sns = boto3.client("sns", region_name=os.getenv("APP_REGION", "eu-north-1"))
s3  = boto3.client("s3",  region_name=os.getenv("APP_REGION", "eu-north-1"))

SNS_TOPIC_ARN     = os.getenv("SNS_TOPIC_ARN")
FIREBASE_SA_BUCKET = "drug-dispenser-analytics-datalake"
FIREBASE_SA_KEY    = "config/firebase-service-account.json"


def _get_firebase_access_token() -> str:
    """Gets OAuth2 access token from Firebase service account stored in S3."""
    import google.oauth2.service_account
    import google.auth.transport.requests

    obj = s3.get_object(Bucket=FIREBASE_SA_BUCKET, Key=FIREBASE_SA_KEY)
    sa_info = json.loads(obj["Body"].read().decode("utf-8"))

    credentials = google.oauth2.service_account.Credentials.from_service_account_info(
        sa_info,
        scopes=["https://www.googleapis.com/auth/firebase.messaging"],
    )
    credentials.refresh(google.auth.transport.requests.Request())
    return credentials.token


def _send_fcm_push(fcm_token: str, title: str, body: str):
    """Sends push notification to a single device via FCM v1 API."""
    project_id = "drug-dispenser-7f379"
    access_token = _get_firebase_access_token()

    url = f"https://fcm.googleapis.com/v1/projects/{project_id}/messages:send"
    payload = json.dumps({
        "message": {
            "token": fcm_token,
            "notification": {
                "title": title,
                "body": body,
            },
            "android": {
                "priority": "HIGH",
            },
        }
    }).encode("utf-8")

    req = urllib.request.Request(
        url,
        data=payload,
        headers={
            "Authorization": f"Bearer {access_token}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read().decode("utf-8"))


class FcmTokenRequest(BaseModel):
    fcm_token: str
    role_id:   str | None = None
    email:     str | None = None


@router.post("/register-token")
def register_fcm_token(request: FcmTokenRequest, aws=Depends(get_aws)):
    """
    Receives FCM token from Flutter app and saves it to RDS roles table.
    Called on every app startup and after login.
    """
    cur = aws.cursor()

    if request.role_id:
        # role_id varsa direkt güncelle
        cur.execute(
            "UPDATE roles SET fcm_token = %s WHERE role_id = %s",
            (request.fcm_token, request.role_id),
        )
    elif request.email:
        # email varsa role bul, token kaydet
        cur.execute(
            "UPDATE roles SET fcm_token = %s WHERE email = %s",
            (request.fcm_token, request.email),
        )
    else:
        # ikisi de yoksa kaydetme
        return {"message": "FCM token registered (no user linked yet)"}

    aws.commit()
    return {"message": "FCM token registered successfully"}



@router.post("/send-push")
def send_push_to_all(aws=Depends(get_aws)):
    """
    Sends push notification to all caregivers with registered FCM tokens.
    """
    cur = aws.cursor()
    cur.execute("SELECT fcm_token FROM roles WHERE fcm_token IS NOT NULL")
    rows = cur.fetchall()

    if not rows:
        return {"message": "No registered devices found", "sent": 0}

    sent  = 0
    failed = 0
    for row in rows:
        try:
            _send_fcm_push(
                fcm_token=row["fcm_token"],
                title="💊 Drug Dispenser Alert",
                body="A patient has been flagged as high risk. Please check the app.",
            )
            sent += 1
        except Exception as e:
            print(f"[FCM] Push failed: {e}")
            failed += 1

    return {"message": f"Push sent to {sent} devices", "sent": sent, "failed": failed}


@router.post("/test-push")
def test_push_notification(aws=Depends(get_aws)):
    """
    Sends a test push notification to all registered devices.
    Use from Swagger to verify FCM setup without needing risk scores.
    """
    cur = aws.cursor()
    cur.execute("SELECT fcm_token FROM roles WHERE fcm_token IS NOT NULL")
    rows = cur.fetchall()

    if not rows:
        return {"message": "No registered devices. Open the Flutter app first to register.", "sent": 0}

    sent = 0
    for row in rows:
        try:
            _send_fcm_push(
                fcm_token=row["fcm_token"],
                title="🧪 Test Notification",
                body="Drug Dispenser push notification is working correctly!",
            )
            sent += 1
        except Exception as e:
            print(f"[FCM] Test push failed: {e}")

    return {"message": f"Test push sent to {sent} devices", "sent": sent}