import boto3
import json
import os
from fastapi import APIRouter

router = APIRouter()

s3 = boto3.client(
    "s3",
    region_name=os.getenv("APP_REGION", "eu-north-1"),
)

sns = boto3.client(
    "sns",
    region_name=os.getenv("APP_REGION", "eu-north-1"),
)

BUCKET         = "drug-dispenser-analytics-datalake"
SCORES_PREFIX  = "sagemaker/scores/"
RISK_THRESHOLD = 70
SNS_TOPIC_ARN  = os.getenv("SNS_TOPIC_ARN")


def _send_sns(subject: str, message: str):
    """Publishes a message to SNS topic — sends email, SMS, push."""
    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject=subject,
        Message=message,
    )


def _read_scores_from_s3() -> list[dict]:
    """Reads risk scores from S3 and returns list of patient scores."""
    response = s3.list_objects_v2(Bucket=BUCKET, Prefix=SCORES_PREFIX)

    if "Contents" not in response:
        return []

    scores = []
    for obj in response["Contents"]:
        if not obj["Key"].endswith(".out"):
            continue

        file_obj = s3.get_object(Bucket=BUCKET, Key=obj["Key"])
        content  = file_obj["Body"].read().decode("utf-8")

        for line in content.strip().split("\n"):
            if not line:
                continue
            try:
                score = float(line.strip())
                scores.append({"raw_score": score})
            except:
                continue

    return scores


@router.get("/risk-scores")
def get_risk_scores():
    """
    Returns latest risk scores for all patients from S3.
    Flutter app or caregiver dashboard can call this.
    """
    scores = _read_scores_from_s3()

    if not scores:
        return {"message": "No scores available yet. Run batch transform first.", "scores": []}

    return {
        "total_patients":  len(scores),
        "high_risk_count": sum(1 for s in scores if s["raw_score"] * 100 >= RISK_THRESHOLD),
        "scores":          scores,
    }


@router.post("/send-notifications")
def send_risk_notifications():
    """
    Reads risk scores from S3, sends SNS notifications to high-risk patients.
    Called by EventBridge every night after Batch Transform completes.
    """
    scores = _read_scores_from_s3()

    if not scores:
        return {"message": "No scores found.", "notified": 0}

    notified = 0
    high_risk = []

    for s in scores:
        risk_score = round(s["raw_score"] * 100, 1)

        if risk_score >= RISK_THRESHOLD:
            high_risk.append({
                "risk_score": risk_score,
                "risk_level": "HIGH" if risk_score >= 85 else "MEDIUM",
            })
            notified += 1

            _send_sns(
                subject=f"⚠️ High Medication Risk Alert",
                message=(
                    f"ALERT: A patient has been flagged as high risk.\n"
                    f"Risk Score: {risk_score}/100\n"
                    f"Risk Level: {'HIGH' if risk_score >= 85 else 'MEDIUM'}\n"
                    f"Please check the Drug Dispenser app immediately."
                )
            )
            print(f"[SNS] Notification sent. Score: {risk_score}")

    return {
        "message":   f"{notified} high-risk patients notified via SNS.",
        "notified":  notified,
        "high_risk": high_risk,
        "threshold": RISK_THRESHOLD,
    }


@router.post("/test-notification")
def test_notification():
    """
    Sends a test SNS notification to verify email/SMS setup.
    Call this from Swagger to test without needing SageMaker scores.
    """
    _send_sns(
        subject="🧪 Drug Dispenser - Test Notification",
        message=(
            "This is a test notification from the Drug Dispenser Early Warning System.\n"
            "If you received this, SNS is working correctly!\n\n"
            "System: Erken Uyarı Sistemi\n"
            "Status: Active"
        )
    )
    return {"message": "Test notification sent. Check your email/SMS."}