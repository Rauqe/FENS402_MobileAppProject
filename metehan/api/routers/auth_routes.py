import os
from fastapi import APIRouter, Depends, HTTPException
from api.database import get_aws
from pydantic import BaseModel

router = APIRouter()


class RoleRegisterRequest(BaseModel):
    email:      str
    role_type:  str
    first_name: str = ""
    last_name:  str = ""


@router.post("/register-role")
def register_role(request: RoleRegisterRequest, aws=Depends(get_aws)):
    """
    Called by Pi backend after local signup.
    Registers the user in AWS RDS roles table so FCM token can be linked.
    """
    cur = aws.cursor()

    # Check if already exists
    cur.execute("SELECT role_id FROM roles WHERE email = %s", (request.email,))
    existing = cur.fetchone()

    if existing:
        return {"message": "Role already exists", "role_id": str(existing["role_id"])}

    cur.execute("""
        INSERT INTO roles (role_type, first_name, last_name, email, password)
        VALUES (%s, %s, %s, %s, %s)
        RETURNING role_id
    """, (
        request.role_type,
        request.first_name,
        request.last_name,
        request.email,
        "pi_managed",  # password Pi'da yönetiliyor
    ))
    aws.commit()
    result = cur.fetchone()

    return {
        "message": "Role registered successfully",
        "role_id": str(result["role_id"]),
        "email":   request.email,
    }