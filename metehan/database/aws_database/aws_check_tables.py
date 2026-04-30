from aws_connect import get_connection

conn = get_connection()
cursor = conn.cursor()

cursor.execute("""
    SELECT table_name 
    FROM information_schema.tables 
    WHERE table_schema = 'public'
""")

tables = cursor.fetchall()
for table in tables:
    print(table[0])

cursor.close()
conn.close()