import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq
from faker import Faker
import datetime
import random
import sys # Import sys to access command-line arguments

# Initialize Faker for generating realistic-looking data
fake = Faker()

def generate_record(i):
    """Generates a single record similar to your alltypes_plain.parquet schema."""
    # Ensure 'id' is distinct for each record
    return {
        "id": i,
        "bool_col": bool(random.getrandbits(1)),
        "tinyint_col": random.randint(0, 127),
        "smallint_col": random.randint(-32768, 32767),
        "int_col": random.randint(-2147483648, 2147483647),
        "bigint_col": random.randint(-9223372036854775808, 9223372036854775807),
        "float_col": random.uniform(-1000.0, 1000.0),
        "double_col": random.uniform(-10000.0, 10000.0),
        "date_string_col": (datetime.date(2009, 1, 1) + datetime.timedelta(days=random.randint(0, 365*5))).strftime("%m/%d/%y"),
        "string_col": fake.word(),
        # Use random minutes for timestamp to ensure variety
        "timestamp_col": (datetime.datetime(2009, 1, 1, 0, 0, 0, tzinfo=datetime.timezone.utc) + datetime.timedelta(minutes=i)).isoformat(),
    }

if __name__ == "__main__":
    # Check if the number of records is provided as an argument
    if len(sys.argv) < 2:
        print("Usage: python generate_parquet_data.py <number_of_records> [output_file_name.parquet]")
        sys.exit(1)

    try:
        num_records = int(sys.argv[1])
        if num_records <= 0:
            raise ValueError("Number of records must be a positive integer.")
    except ValueError as e:
        print(f"Error: Invalid number of records provided. {e}")
        print("Usage: python generate_parquet_data.py <number_of_records> [output_file_name.parquet]")
        sys.exit(1)

    # Determine output file name
    if len(sys.argv) >= 3:
        # Use provided output file name
        output_parquet_file = sys.argv[2]
        # Ensure it ends with .parquet if not already
        if not output_parquet_file.lower().endswith(".parquet"):
            output_parquet_file += ".parquet"
    else:
        # Generate generic one if not provided
        output_parquet_file = f"generated_data_{num_records}.parquet"


    print(f"Generating {num_records} records...")
    # Generate data using a list comprehension for efficiency
    data = [generate_record(i) for i in range(num_records)]
    df = pd.DataFrame(data)

    # Convert DataFrame to an Arrow Table
    table = pa.Table.from_pandas(df)

    print(f"Writing {num_records} records to {output_parquet_file}...")
    pq.write_table(table, output_parquet_file)
    print("Done.")

    print(f"\nTo verify the number of records using parquet-tools, run:")
    print(f"parquet-tools row-count {output_parquet_file}")
