#!/bin/bash

# Configuration for Floci
export AWS_ENDPOINT_URL="http://localhost:4566"
export AWS_ACCESS_KEY_ID="test"
export AWS_SECRET_ACCESS_KEY="test"
export AWS_DEFAULT_REGION="us-east-1"

# Athena needs an S3 bucket for query results
ATHENA_OUTPUT_LOCATION="s3://my-data-lake/athena-results/"
S3_DATA_LAKE_BUCKET="my-data-lake"
GLUE_DATABASE_NAME="analytics"
GLUE_TABLE_NAME="orders"

# Function to check if a command exists
command_exists () {
  command -v "$1" >/dev/null 2>&1
}

generate_uuid() {
  python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || uuidgen | tr '[:upper:]' '[:lower:]'
}

# Check for jq dependency
if ! command_exists jq; then
  echo "Error: 'jq' is not installed. Please install it to run this script." >&2
  echo "  On macOS: brew install jq" >&2
  echo "  On Debian/Ubuntu: sudo apt-get install jq" >&2
  exit 1
fi

# Helper function to run Athena query and wait for results
# Usage: execute_athena_query "SQL_QUERY" "OUTPUT_LOCATION" [raw_output_boolean]
# If raw_output_boolean is true, only the raw JSON from get-query-results is output to stdout.
# Otherwise, it's formatted with jq.
execute_athena_query() {
  local query_string="$1"
  local output_location="$2"
  local raw_output="${3:-false}" # Optional: set to true to get raw JSON output

  # Ensure the Athena output location exists
  if ! aws s3 ls "$output_location" --endpoint-url "$AWS_ENDPOINT_URL" > /dev/null 2>&1; then
    echo "Creating Athena results S3 bucket: $output_location" >&2
    aws s3 mb "$output_location" --endpoint-url "$AWS_ENDPOINT_URL" >&2
  fi

  echo "Starting query execution..." >&2
  QUERY_ID=$(aws athena start-query-execution \
    --query-string "$query_string" \
    --query-execution-context Database="$GLUE_DATABASE_NAME" \
    --result-configuration "OutputLocation=$output_location" \
    --endpoint-url "$AWS_ENDPOINT_URL" \
    --query 'QueryExecutionId' \
    --output text \
    --no-cli-pager)

  if [ -z "$QUERY_ID" ]; then
    echo "Failed to start query execution." >&2
    return 1
  fi

  echo "Query ID: $QUERY_ID" >&2
  echo "Polling query status..." >&2

  local result_json=""
  while true; do
    STATE=$(aws athena get-query-execution \
      --query-execution-id "$QUERY_ID" \
      --endpoint-url "$AWS_ENDPOINT_URL" \
      --query 'QueryExecution.Status.State' \
      --output text \
      --no-cli-pager)

    echo "Current state: $STATE" >&2
    case "$STATE" in
      SUCCEEDED)
        echo "Query SUCCEEDED. Fetching results..." >&2
        result_json=$(aws athena get-query-results \
          --query-execution-id "$QUERY_ID" \
          --endpoint-url "$AWS_ENDPOINT_URL" \
          --no-cli-pager)

        if [ "$raw_output" = "true" ]; then
          echo "$result_json" # Raw JSON to stdout
        else
          echo "$result_json" | \
            jq -c '.ResultSet |
              ( .Rows[0].Data | map(.VarCharValue) ) as $headers |
              .Rows[1:] |
              map(
                .Data |
                map(.VarCharValue) |
                to_entries |
                map( .key |= $headers[.] ) |
                from_entries
              )' # Formatted JSON to stdout
        fi
        break
        ;;
      FAILED|CANCELLED)
        ERROR_MESSAGE=$(aws athena get-query-execution \
          --query-execution-id "$QUERY_ID" \
          --endpoint-url "$AWS_ENDPOINT_URL" \
          --query 'QueryExecution.Status.StateChangeReason' \
          --output text \
          --no-cli-pager)
        echo "Query $STATE. Reason: $ERROR_MESSAGE" >&2
        return 1
        ;;
      *)
        sleep 2
        ;;
    esac
  done
  return 0
}

# Function to create the 'orders' table and upload data
create_orders_table_if_not_exists() {
  echo "--- Checking/Creating Athena 'orders' Table ---" >&2

  # Ensure S3 data lake bucket exists
  if ! aws s3 ls s3://"$S3_DATA_LAKE_BUCKET" --endpoint-url "$AWS_ENDPOINT_URL" > /dev/null 2>&1; then
    echo "S3 data lake bucket '$S3_DATA_LAKE_BUCKET' not found. Creating..." >&2
    aws s3 mb s3://"$S3_DATA_LAKE_BUCKET" --endpoint-url "$AWS_ENDPOINT_URL" >&2
    echo "S3 data lake bucket '$S3_DATA_LAKE_BUCKET' created." >&2
  else
    echo "S3 data lake bucket '$S3_DATA_LAKE_BUCKET' already exists." >&2
  fi

  # Check if Glue database exists
  if ! aws glue get-database --name "$GLUE_DATABASE_NAME" --endpoint-url "$AWS_ENDPOINT_URL" > /dev/null 2>&2; then
    echo "Glue database '$GLUE_DATABASE_NAME' not found. Creating..." >&2
    aws glue create-database \
      --database-input "{\"Name\":\"$GLUE_DATABASE_NAME\"}" \
      --endpoint-url "$AWS_ENDPOINT_URL" \
      --no-cli-pager >&2
    echo "Glue database '$GLUE_DATABASE_NAME' created." >&2
  else
    echo "Glue database '$GLUE_DATABASE_NAME' already exists." >&2
  fi

  # Check if table exists
  if aws glue get-table --database-name "$GLUE_DATABASE_NAME" --name "$GLUE_TABLE_NAME" --endpoint-url "$AWS_ENDPOINT_URL" > /dev/null 2>&2; then
    echo "Athena table '$GLUE_TABLE_NAME' already exists in Glue database '$GLUE_DATABASE_NAME'." >&2
  else
    echo "Athena table '$GLUE_TABLE_NAME' does not exist. Creating..." >&2
    aws glue create-table \
      --database-name "$GLUE_DATABASE_NAME" \
      --table-input "{
        \"Name\": \"$GLUE_TABLE_NAME\",
        \"StorageDescriptor\": {
          \"Location\": \"s3://$S3_DATA_LAKE_BUCKET/orders/\",
          \"InputFormat\": \"org.apache.hadoop.mapred.TextInputFormat\",
          \"OutputFormat\": \"org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat\",
          \"SerdeInfo\": {
            \"SerializationLibrary\": \"org.openx.data.jsonserde.JsonSerDe\"
          },
          \"Columns\": [
            {\"Name\": \"id\",     \"Type\": \"string\"},
            {\"Name\": \"amount\", \"Type\": \"double\"}
          ]
        }
      }" \
      --endpoint-url "$AWS_ENDPOINT_URL" \
      --no-cli-pager >&2
    echo "Athena table '$GLUE_TABLE_NAME' created." >&2

    # Upload initial sample data ONLY when the table is newly created
    echo "S3: Uploading initial sample data to s3://$S3_DATA_LAKE_BUCKET/orders/data.json..." >&2
    {
      printf '{"id":"%s","amount":10.0}\n' "$(generate_uuid)"
      printf '{"id":"%s","amount":20.0}\n' "$(generate_uuid)"
      printf '{"id":"%s","amount":30.0}\n' "$(generate_uuid)"
    } | aws s3 cp - s3://"$S3_DATA_LAKE_BUCKET"/orders/data.json --endpoint-url "$AWS_ENDPOINT_URL" >&2
  fi
  echo "---------------------------------------------" >&2
}

# Function to list all data from the 'orders' table
list_orders_data() {
  echo "--- Listing All Data from '$GLUE_TABLE_NAME' Table ---" >&2
  create_orders_table_if_not_exists # Ensure table exists
  execute_athena_query "SELECT * FROM $GLUE_TABLE_NAME" "$ATHENA_OUTPUT_LOCATION"
  echo "----------------------------------------------------" >&2
}

# Function to query data by amount (using 'amount' as the queryable field)
query_orders_by_amount() {
  echo "--- Query Data from '$GLUE_TABLE_NAME' by Amount ---" >&2
  create_orders_table_if_not_exists # Ensure table exists

  read -p "Enter minimum amount to query (e.g., 20.0): " min_amount
  if [ -z "$min_amount" ]; then
    echo "Minimum amount cannot be empty." >&2
    return 1
  fi

  # Basic validation for numeric input
  if ! [[ "$min_amount" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    echo "Invalid amount. Please enter a numeric value." >&2
    return 1
  fi

  echo "Querying for orders with amount >= $min_amount..." >&2
  execute_athena_query "SELECT * FROM $GLUE_TABLE_NAME WHERE amount >= $min_amount" "$ATHENA_OUTPUT_LOCATION"
  echo "----------------------------------------------------" >&2
}

# Function to add more data to the 'orders' table
add_more_orders_data() {
  echo "--- Adding More Data to '$GLUE_TABLE_NAME' Table ---" >&2
  create_orders_table_if_not_exists # Ensure table exists

  read -p "How many records to add? " num_records
  if ! [[ "$num_records" =~ ^[0-9]+$ ]] || [ "$num_records" -eq 0 ]; then
    echo "Invalid number. Please enter a positive integer." >&2
    return 1
  fi

  local filename="data_$(date +%s).json"

  echo "Generating $num_records new records..." >&2
  {
    for ((i=0; i<num_records; i++)); do
      local whole_amount=$(( RANDOM % 999 + 1 ))
      local decimal_amount=$(printf "%02d" $(( RANDOM % 100 )))
      printf '{"id":"%s","amount":%d.%s}\n' "$(generate_uuid)" "$whole_amount" "$decimal_amount"
    done
  } | aws s3 cp - s3://"$S3_DATA_LAKE_BUCKET"/orders/"$filename" --endpoint-url "$AWS_ENDPOINT_URL" >&2

  echo "$num_records new records added. Athena will discover them automatically." >&2
  echo "---------------------------------------------" >&2
}

# Function to reset 'orders' table data
reset_orders_data() {
  echo "--- Resetting 'orders' Table Data ---" >&2
  read -p "WARNING: This will delete all data in s3://my-data-lake/orders/ and re-upload initial samples. Are you sure? (y/N): " confirmation
  if [[ ! "$confirmation" =~ ^[yY]$ ]]; then
    echo "Reset cancelled." >&2
    return 0
  fi

  echo "Deleting all objects from s3://$S3_DATA_LAKE_BUCKET/orders/..." >&2
  aws s3 rm s3://"$S3_DATA_LAKE_BUCKET"/orders/ --recursive --endpoint-url "$AWS_ENDPOINT_URL" >&2

  echo "Dropping Glue table '$GLUE_TABLE_NAME' to recreate schema..." >&2
  AWS_PAGER="" aws glue delete-table \
    --database-name "$GLUE_DATABASE_NAME" \
    --name "$GLUE_TABLE_NAME" \
    --endpoint-url "$AWS_ENDPOINT_URL" \
    2>/dev/null || true

  create_orders_table_if_not_exists

  echo "'orders' table data reset to initial samples." >&2
  echo "---------------------------------------------" >&2
}


# Function to run a custom Athena query interactively
run_athena_query() {
  echo "--- Run a Custom Athena Query ---" >&2
  read -p "Enter your SQL query: " user_query
  if [ -z "$user_query" ]; then
    echo "Query cannot be empty." >&2
    return 1
  fi
  execute_athena_query "$user_query" "$ATHENA_OUTPUT_LOCATION"
  echo "---------------------------------" >&2
}

# Main interactive menu
while true; do
  echo -e "\n--- Athena CLI for Floci ---"
  echo "1. Run a Custom Athena Query"
  echo "2. Create/Ensure 'orders' Table and Upload Initial Sample Data"
  echo "3. List All Data from 'orders' Table"
  echo "4. Query 'orders' Table by Minimum Amount"
  echo "5. Add More Data to 'orders' Table"
  echo "6. Reset 'orders' Table Data"
  echo "7. Exit"
  echo "----------------------------"
  read -p "Enter your choice: " choice

  case "$choice" in
    1) run_athena_query ;;
    2) create_orders_table_if_not_exists ;;
    3) list_orders_data ;;
    4) query_orders_by_amount ;;
    5) add_more_orders_data ;;
    6) reset_orders_data ;;
    7) echo "Exiting."; exit 0 ;;
    *) echo "Invalid choice. Please try again." ;;
  esac
done