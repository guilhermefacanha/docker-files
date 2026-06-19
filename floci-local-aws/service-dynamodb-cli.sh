#!/bin/bash

# Configuration for Floci
export AWS_ENDPOINT_URL="http://localhost:4566"
export AWS_ACCESS_KEY_ID="test"
export AWS_SECRET_ACCESS_KEY="test"
export AWS_DEFAULT_REGION="us-east-1"

TABLE_NAME="Users"

# Function to check if a command exists
command_exists () {
  command -v "$1" >/dev/null 2>&1
}

# Check for jq dependency
if ! command_exists jq; then
  echo "Error: 'jq' is not installed. Please install it to run this script."
  echo "  On macOS: brew install jq"
  echo "  On Debian/Ubuntu: sudo apt-get install jq"
  exit 1
fi

# Function to list DynamoDB tables
list_tables() {
  echo "--- Listing DynamoDB Tables ---"
  aws dynamodb list-tables --endpoint-url "$AWS_ENDPOINT_URL" --no-cli-pager
  echo "-------------------------------"
}

# Function to create the Users table if it doesn't exist
create_users_table_if_not_exists() {
  echo "--- Checking/Creating Users Table ---"
  if aws dynamodb list-tables --endpoint-url "$AWS_ENDPOINT_URL" --no-cli-pager | grep -q "\"$TABLE_NAME\""; then
    echo "Table '$TABLE_NAME' already exists."
  else
    echo "Table '$TABLE_NAME' does not exist. Creating..."
    aws dynamodb create-table \
      --table-name "$TABLE_NAME" \
      --attribute-definitions AttributeName=id,AttributeType=S \
      --key-schema AttributeName=id,KeyType=HASH \
      --billing-mode PAY_PER_REQUEST \
      --endpoint-url "$AWS_ENDPOINT_URL" \
      --no-cli-pager

    echo "Waiting for table '$TABLE_NAME' to become ACTIVE..."
    aws dynamodb wait table-exists --table-name "$TABLE_NAME" --endpoint-url "$AWS_ENDPOINT_URL"
    echo "Table '$TABLE_NAME' is now ACTIVE."
  fi
  echo "-------------------------------------"
}

# Function to list data from the Users table
list_users_data() {
  echo "--- Listing All Data from '$TABLE_NAME' ---"
  create_users_table_if_not_exists # Ensure table exists before scanning
  aws dynamodb scan \
    --table-name "$TABLE_NAME" \
    --endpoint-url "$AWS_ENDPOINT_URL" \
    --no-cli-pager \
    --query "Items[*].{ID:id.S, Name:userName.S, Email:email.S}" # Customize query for better readability
  echo "----------------------------------------"
}

# Function to add new sample user data
add_sample_user_data() {
  echo "--- Adding Sample User Data to '$TABLE_NAME' ---"
  create_users_table_if_not_exists # Ensure table exists before adding data

  read -p "How many users to add? (e.g., 5): " num_to_add
  if ! [[ "$num_to_add" =~ ^[0-9]+$ ]] || [ "$num_to_add" -eq 0 ]; then
    echo "Invalid number. Please enter a positive integer."
    return 1
  fi

  for ((i=1; i<=num_to_add; i++)); do
    # Get the current highest user number
    local last_user_num=0
    local existing_users=$(aws dynamodb scan \
      --table-name "$TABLE_NAME" \
      --endpoint-url "$AWS_ENDPOINT_URL" \
      --no-cli-pager \
      --query "Items[*].userName.S" \
      --output json)

    if [ "$(echo "$existing_users" | jq '. | length')" -gt 0 ]; then
      for user_name_val in $(echo "$existing_users" | jq -r '.[]'); do
        if [[ "$user_name_val" =~ User([0-9]+) ]]; then
          current_num="${BASH_REMATCH[1]}"
          if (( current_num > last_user_num )); then
            last_user_num="$current_num"
          fi
        fi
      done
    fi

    local new_user_num=$((last_user_num + 1))
    local user_id=$(uuidgen) # Generate a unique ID
    local user_name="User$new_user_num"
    local user_email="user$new_user_num@example.com"

    echo "Adding user $i/$num_to_add: ID=$user_id, Name=$user_name, Email=$user_email"

    aws dynamodb put-item \
      --table-name "$TABLE_NAME" \
      --item "{\"id\": {\"S\": \"$user_id\"}, \"userName\": {\"S\": \"$user_name\"}, \"email\": {\"S\": \"$user_email\"}}" \
      --endpoint-url "$AWS_ENDPOINT_URL" \
      --no-cli-pager
  done

  echo "$num_to_add user(s) added."
  echo "--------------------------------------------"
}

# Function to query data by name
query_data_by_name() {
  echo "--- Query Data from '$TABLE_NAME' by Name ---"
  create_users_table_if_not_exists # Ensure table exists before querying

  read -p "Enter search string for user name (case-sensitive): " search_string
  if [ -z "$search_string" ]; then
    echo "Search string cannot be empty."
    return 1
  fi

  aws dynamodb scan \
    --table-name "$TABLE_NAME" \
    --filter-expression "contains(userName, :search_string)" \
    --expression-attribute-values "{\":search_string\": {\"S\": \"$search_string\"}}" \
    --endpoint-url "$AWS_ENDPOINT_URL" \
    --no-cli-pager \
    --query "Items[*].{ID:id.S, Name:userName.S, Email:email.S}"

  echo "--------------------------------------------"
}


# Main interactive menu
while true; do
  echo -e "\n--- DynamoDB CLI for Floci ---"
  echo "1. List all DynamoDB Tables"
  echo "2. Create '$TABLE_NAME' Table (if not exists)"
  echo "3. List All Data from '$TABLE_NAME' Table"
  echo "4. Add Sample User Data to '$TABLE_NAME' Table"
  echo "5. Query Data from '$TABLE_NAME' by Name"
  echo "6. Exit"
  echo "------------------------------"
  read -p "Enter your choice: " choice

  case "$choice" in
    1) list_tables ;;
    2) create_users_table_if_not_exists ;;
    3) list_users_data ;;
    4) add_sample_user_data ;;
    5) query_data_by_name ;;
    6) echo "Exiting."; exit 0 ;;
    *) echo "Invalid choice. Please try again." ;;
  esac
done