import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq
from faker import Faker
import random
import uuid
import datetime
import sys

# Initialize Faker for generating realistic-looking data
fake = Faker()

def generate_record():
    """Generates a single record based on the schema."""
    return {
        "analyzedClientIP": fake.ipv4(),
        "appUserName": fake.user_name(),
        "assetId": f"arn:aws:rds:{fake.state_abbr()}:{random.randint(100000000000, 999999999999)}:db:{fake.word()}",
        "auditPolicy": f"SONAR_POLICY_{fake.word().upper()}",
        "clientHostName": fake.domain_name(),
        "clientPort": str(random.randint(1000, 65535)),
        "collectionPlatform": "Sonar",
        "databaseName": fake.word().upper(),
        "dbId": random.randint(1, 1000000000),
        "dbUserName": fake.user_name().upper(),
        "failedSqls": random.randint(0, 10),
        "gatewayEventTime": int(datetime.datetime.now().timestamp() * 1000),
        "id": str(uuid.uuid4()),
        "objectsAndVerbs": f"{fake.word()} {fake.word().upper()}",
        "objectsAndVerbsClassifications": {
            "Audit Related": fake.word().upper(),
            "SQL Statement Type": fake.word().upper()
        },
        "originalSql": f"SELECT '{fake.word()}' FROM DUAL",
        "osUser": fake.user_name(),
        "periodStart": int(datetime.datetime.now().timestamp() * 1000) - random.randint(100000, 1000000),
        "serverHostName": fake.domain_name(),
        "serverIP": fake.ipv4(),
        "serverPort": str(random.randint(1000, 65535)),
        "serverType": f"AWS RDS {fake.word().upper()}",
        "serviceName": fake.word().upper(),
        "sessionId": random.randint(1, 10000000),
        "sonarGSource": f"{fake.domain_name()}_{str(uuid.uuid4())}",
        "sourceProgram": fake.word().capitalize(),
        "successfulSqls": random.randint(0, 10),
        "terminal": fake.word(),
        "timestamp": int(datetime.datetime.now().timestamp() * 1000),
        "totalRecordsAffected": random.randint(1, 100),
        "utcOffset": random.randint(-12, 12),
        "vendor": f"{fake.company().upper()}"
    }

if __name__ == "__main__":
    # Check if the number of records is provided as an argument
    if len(sys.argv) < 2:
        print("Usage: python generate-events-parquet.py <number_of_records> [output_file_name.parquet]")
        sys.exit(1)

    try:
        num_records = int(sys.argv[1])
        if num_records <= 0:
            raise ValueError("Number of records must be a positive integer.")
    except ValueError as e:
        print(f"Error: Invalid number of records provided. {e}")
        print("Usage: python generate-events-parquet.py <number_of_records> [output_file_name.parquet]")
        sys.exit(1)

    # Determine output file name
    if len(sys.argv) >= 3:
        output_parquet_file = sys.argv[2]
        if not output_parquet_file.lower().endswith(".parquet"):
            output_parquet_file += ".parquet"
    else:
        output_parquet_file = f"events_data_{num_records}.parquet"

    print(f"Generating {num_records} records...")
    # Generate data using a list comprehension for efficiency
    data = [generate_record() for _ in range(num_records)]
    df = pd.DataFrame(data)

    # Convert DataFrame to an Arrow Table
    table = pa.Table.from_pandas(df)

    print(f"Writing {num_records} records to {output_parquet_file}...")
    pq.write_table(table, output_parquet_file)
    print("Done.")

    print(f"\nTo verify the number of records using parquet-tools, run:")
    print(f"parquet-tools row-count {output_parquet_file}")