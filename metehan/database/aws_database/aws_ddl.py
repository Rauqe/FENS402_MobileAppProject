import os
from aws_connect import get_connection

SCHEMA_PATH = os.path.join(os.path.dirname(__file__), "ddl_schema.sql")


def create_tables():
    """Read ddl_schema.sql and execute it against the database."""
    with open(SCHEMA_PATH, "r") as f:
        sql = f.read()

    conn = get_connection()

    try:
        cursor = conn.cursor()
        cursor.execute(sql)
        conn.commit()
        print("Tables created successfully.")
        
    except Exception as e:
        conn.rollback()
        print(f"Error creating tables: {e}")
        
    finally:
        cursor.close()
        conn.close()


if __name__ == "__main__":
    create_tables()