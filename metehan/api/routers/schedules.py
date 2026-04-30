from fastapi import APIRouter, Depends, HTTPException
from api.database import get_aws
from pydantic import BaseModel
from typing import Optional

router = APIRouter()


class ScheduleCreate(BaseModel):
    """
    Schedule creation data.
    Will be used to create a new schedule in the AWS database.
    """
    medication_id:   str
    planned_time:    str        # "HH:MM" format
    dosage_quantity: Optional[int] = 1
    is_active:       Optional[bool] = True
    start_date:      str        # "YYYY-MM-DD" format
    end_date:        Optional[str] = None


class ScheduleUpdate(BaseModel):
    """
    Schedule update data.
    Will be used to update an existing schedule in the AWS database.
    """
    planned_time:    Optional[str]  = None
    dosage_quantity: Optional[int]  = None
    is_active:       Optional[bool] = None
    end_date:        Optional[str]  = None



@router.get("/{patient_id}")
def get_patient_schedules(patient_id: str, aws=Depends(get_aws)):
    """
    Get active medication schedules for a patient from AWS database.
    AWS schedules table doesn't have patient_id due to normalization, 
    So we need to join with medications and patients to get the patient_id.
    """
    cur = aws.cursor()
    cur.execute("""
        SELECT
            ms.schedule_id,
            ms.planned_time,
            ms.dosage_quantity,
            ms.is_active,
            ms.start_date,
            ms.end_date,
            m.medication_name,
            m.remaining_count
        FROM medication_schedules ms
        JOIN medications m ON ms.medication_id = m.medication_id
        WHERE m.patient_id = %s
          AND ms.is_active = TRUE
          AND ms.start_date <= CURRENT_DATE
          AND (ms.end_date IS NULL OR ms.end_date >= CURRENT_DATE)
        ORDER BY ms.planned_time
    """, (patient_id,))

    schedules = cur.fetchall()

    if not schedules:
        raise HTTPException(
            status_code=404,
            detail="No active schedules found for this patient"
        )

    return {"schedules": [dict(s) for s in schedules]}


@router.post("")
@router.post("/")
def create_schedule(schedule: ScheduleCreate, aws=Depends(get_aws)):
    """Creates a new schedule for an existing medication in the AWS database."""
    cur = aws.cursor()
    cur.execute("""
        INSERT INTO medication_schedules
            (medication_id, planned_time, dosage_quantity, is_active, start_date, end_date)
        VALUES (%s, %s::time, %s, %s, %s::date, %s::date)
        RETURNING schedule_id, planned_time
    """, (
        schedule.medication_id,
        schedule.planned_time,
        schedule.dosage_quantity,
        schedule.is_active,
        schedule.start_date,
        schedule.end_date,
    ))
    aws.commit()
    result = cur.fetchone()
    return {
        "message":     "Schedule created",
        "schedule_id": str(result["schedule_id"]),
        "planned_time": str(result["planned_time"]),
    }


@router.put("/{schedule_id}")
def update_schedule(schedule_id: str, schedule: ScheduleUpdate, aws=Depends(get_aws)):
    """Updates the existing schedule's information."""
    cur = aws.cursor()
    cur.execute("""
        UPDATE medication_schedules SET
            planned_time    = COALESCE(%s::time, planned_time),
            dosage_quantity = COALESCE(%s, dosage_quantity),
            is_active       = COALESCE(%s, is_active),
            end_date        = COALESCE(%s::date, end_date)
        WHERE schedule_id = %s
        RETURNING schedule_id, planned_time
    """, (
        schedule.planned_time,
        schedule.dosage_quantity,
        schedule.is_active,
        schedule.end_date,
        schedule_id,
    ))
    aws.commit()
    result = cur.fetchone()

    if not result:
        raise HTTPException(status_code=404, detail="Schedule not found")
    return {"message": "Schedule updated", "schedule_id": str(result["schedule_id"])}


@router.delete("/{schedule_id}")
def delete_schedule(schedule_id: str, aws=Depends(get_aws)):
    """Deletes the schedule."""
    cur = aws.cursor()
    cur.execute("DELETE FROM medication_schedules WHERE schedule_id = %s RETURNING schedule_id", (schedule_id,))
    aws.commit()
    result = cur.fetchone()
    
    if not result:
        raise HTTPException(status_code=404, detail="Schedule not found")
    return {"message": "Schedule deleted", "schedule_id": schedule_id}