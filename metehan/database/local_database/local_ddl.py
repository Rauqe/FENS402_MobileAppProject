import os
import sqlite3


DB_PATH = os.path.join(os.path.dirname(__file__), "..", "..", "faces.db")
SCHEMA_PATH = os.path.join(os.path.dirname(__file__), "local_ddl_schema.sql")


def create_local_tables():
    """Read local_schema.sql and execute it against the local SQLite database."""
    with open(SCHEMA_PATH, "r") as f:
        sql = f.read()

    conn = sqlite3.connect(DB_PATH)
    
    try:
        conn.executescript(sql)
        conn.commit()
        print("Local tables created successfully.")

        # Show all tables
        tables = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        ).fetchall()
        print("Tables in faces.db:")
        for t in tables:
            print(f"  - {t[0]}")

    except Exception as e:
        print(f"Error creating local tables: {e}")

    finally:
        conn.close()

if __name__ == "__main__":
    create_local_tables()