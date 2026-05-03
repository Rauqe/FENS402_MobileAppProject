from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from typing import Optional, List
from api.database import get_aws

router = APIRouter()


class SlotMedicationItem(BaseModel):
    medication_id: str
    medication_name: str
    barcode: Optional[str] = None
    target_count: int = 0
    loaded_count: int = 0


class SetSlotMedicationsRequest(BaseModel):
    patient_id: Optional[str] = None
    medications: List[SlotMedicationItem] = []


class BindSlotRequest(BaseModel):
    patient_id: str
    status: str = "empty"


@router.get("")
@router.get("/")
def get_all_slots(aws=Depends(get_aws)):
    cur = aws.cursor()
    cur.execute("""
        SELECT sb.slot_id, sb.patient_id, sb.status, sb.updated_at,
               p.first_name, p.last_name
        FROM slot_bindings sb
        LEFT JOIN patients p ON p.patient_id::text = sb.patient_id
        ORDER BY sb.slot_id
    """)
    rows = cur.fetchall()

    slots = []
    for r in rows:
        cur.execute("""
            SELECT id, medication_id, medication_name, barcode,
                   target_count, loaded_count
            FROM slot_medications
            WHERE slot_id = %s
            ORDER BY id
        """, (r["slot_id"],))
        meds = cur.fetchall()
        slots.append({
            "slot_id": r["slot_id"],
            "patient_id": r["patient_id"],
            "patient_name": f"{r['first_name'] or ''} {r['last_name'] or ''}".strip(),
            "status": r["status"],
            "updated_at": str(r["updated_at"]),
            "medications": [dict(m) for m in meds],
        })

    return {"slots": slots}


@router.get("/available")
def get_available_slots(aws=Depends(get_aws)):
    cur = aws.cursor()
    cur.execute("""
        SELECT slot_id, patient_id, status
        FROM slot_bindings
        ORDER BY slot_id
    """)
    rows = cur.fetchall()

    available = []
    occupied = []
    for r in rows:
        sid = r["slot_id"]
        pid = r["patient_id"]
        st = r["status"] or ""
        if pid is None or st == "empty":
            available.append({"slot_id": sid, "available": True})
        else:
            occupied.append({
                "slot_id": sid,
                "available": False,
                "patient_id": str(pid) if pid is not None else None,
                "status": st,
            })

    return {"available": available, "occupied": occupied}


@router.get("/{slot_id}/medications")
def get_slot_medications(slot_id: int, aws=Depends(get_aws)):
    cur = aws.cursor()
    cur.execute("""
        SELECT id, medication_id, medication_name, barcode,
               target_count, loaded_count
        FROM slot_medications
        WHERE slot_id = %s
        ORDER BY id
    """, (slot_id,))
    rows = cur.fetchall()
    return {"medications": [dict(r) for r in rows]}


@router.post("/{slot_id}/medications")
def set_slot_medications(
    slot_id: int,
    body: SetSlotMedicationsRequest,
    aws=Depends(get_aws),
):
    cur = aws.cursor()

    patient_id = body.patient_id
    if not patient_id:
        cur.execute(
            "SELECT patient_id FROM slot_bindings WHERE slot_id = %s",
            (slot_id,),
        )
        row = cur.fetchone()
        patient_id = str(row["patient_id"]) if row and row["patient_id"] else None

    cur.execute("DELETE FROM slot_medications WHERE slot_id = %s", (slot_id,))

    for med in body.medications:
        cur.execute("""
            INSERT INTO slot_medications
                (slot_id, patient_id, medication_id, medication_name,
                 barcode, target_count, loaded_count)
            VALUES (%s, %s, %s, %s, %s, %s, %s)
        """, (
            slot_id,
            patient_id,
            med.medication_id,
            med.medication_name,
            med.barcode,
            med.target_count,
            med.loaded_count,
        ))

    if body.medications:
        all_loaded = all(
            m.loaded_count >= m.target_count for m in body.medications
        )
        new_status = "loaded" if all_loaded else "empty"
    else:
        new_status = "empty"

    cur.execute("""
        UPDATE slot_bindings
        SET status = %s, updated_at = NOW()
        WHERE slot_id = %s
    """, (new_status, slot_id))

    aws.commit()
    return {"message": "Slot medications updated successfully", "slot_id": slot_id}


@router.post("/{slot_id}/bind")
def bind_slot(slot_id: int, body: BindSlotRequest, aws=Depends(get_aws)):
    cur = aws.cursor()
    st = body.status if body.status in ("empty", "loaded", "dispensed") else "empty"
    cur.execute("""
        INSERT INTO slot_bindings (slot_id, patient_id, status, updated_at)
        VALUES (%s, %s, %s, NOW())
        ON CONFLICT (slot_id) DO UPDATE
        SET patient_id = EXCLUDED.patient_id,
            status = EXCLUDED.status,
            updated_at = NOW()
    """, (slot_id, body.patient_id, st))
    aws.commit()
    return {
        "message": "Slot bound successfully",
        "slot_id": slot_id,
        "patient_id": body.patient_id,
    }


@router.delete("/{slot_id}")
def delete_slot(slot_id: int, aws=Depends(get_aws)):
    cur = aws.cursor()
    cur.execute("DELETE FROM slot_medications WHERE slot_id = %s", (slot_id,))
    cur.execute("""
        UPDATE slot_bindings
        SET patient_id = NULL, status = 'empty', updated_at = NOW()
        WHERE slot_id = %s
    """, (slot_id,))
    aws.commit()
    return {"message": "Slot cleared successfully", "slot_id": slot_id}
