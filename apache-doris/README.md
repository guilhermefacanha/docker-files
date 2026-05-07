# Apache Doris Docker Development Environment

This repository provides a Docker-based development environment for Apache Doris, allowing you to quickly set up and experiment with Doris.

## Getting Started

To set up and start the Apache Doris cluster, run the `setup.sh` script:

```bash
sh setup.sh
```

This script performs the following actions:
1.  **Checks Environment**: Verifies that Docker and `docker-compose` (or `docker compose`) are installed on your system.
2.  **Detects OS**: Determines your operating system (Linux or macOS) to generate the appropriate `docker-compose` configuration.
3.  **Generates `docker-compose-doris.yaml`**: Creates a `docker-compose-doris.yaml` file tailored for your OS.
    *   **Linux**: Uses `network_mode: host` for direct access.
    *   **macOS**: Sets up a custom bridge network with specific IP addresses and port mappings.
4.  **Starts Services**: Brings up the Doris FrontEnd (FE) and BackEnd (BE) services using the generated `docker-compose` file.

### Configuration

You can specify the Apache Doris version to use by passing the `-v` flag to the `setup.sh` script:

```bash
sh setup.sh -v 2.1.9 # Example: Use Doris version 2.1.9 (default if not specified)
```

## Connecting to Apache Doris

Once the cluster is started, you can connect to it using the MySQL client.

**MySQL Client Connection:**

```bash
mysql -uroot -P9030 -h127.0.0.1
```

**Web Interface Access:**

The Doris web interfaces (FE and BE) can be accessed via HTTP. The exact address depends on your operating system:

*   **Linux:**
    *   FE: `http://127.0.0.1:8030`
    *   BE: `http://127.0.0.1:8040`
*   **macOS:**
    *   FE: `http://docker.for.mac.localhost:8030` (or `http://127.0.0.1:8030` if the former fails)
    *   BE: `http://docker.for.mac.localhost:8040` (or `http://127.0.0.1:8040` if the former fails)

## Managing the Cluster

*   **Stop Cluster:**
    ```bash
    docker compose -f docker-compose-doris.yaml down
    ```
*   **View Logs:**
    ```bash
    docker compose -f docker-compose-doris.yaml logs -f
    ```

## Test the Connections

Ensure that both the FrontEnd (FE) and BackEnd (BE) services are running and healthy.

### Check FE Status

```bash
mysql -uroot -P9030 -h127.0.0.1 -e 'SELECT `host`, `join`, `alive` FROM frontends()'
```

Expected Output:
```
+-----------+------+-------+
| host      | join | alive |
+-----------+------+-------+
| 127.0.0.1 | true | true  |
+-----------+------+-------+
```

### Check BE Status

```bash
mysql -uroot -P9030 -h127.0.0.1 -e 'SELECT `host`, `alive` FROM backends()'
```

Expected Output:
```
+-----------+-------+
| host      | alive |
+-----------+-------+
| 127.0.0.1 |     1 |
+-----------+-------+
```

## Load Test Data from Parquet

This section describes how to create tables and load sample Parquet data into your Doris cluster.

### Create Database and Tables

First, connect to Doris using the MySQL client and create a database and the necessary tables:

```sql
CREATE DATABASE IF NOT EXISTS my_database;

-- Create sample table for generic parquet data
CREATE TABLE `parquet_data` (
  `id` int NULL,
  `bool_col` boolean NULL,
  `tinyint_col` tinyint NULL,
  `smallint_col` smallint NULL,
  `int_col` int NULL,
  `bigint_col` bigint NULL,
  `float_col` float NULL,
  `double_col` double NULL,
  `date_string_col` varchar(20) NULL,
  `string_col` varchar(256) NULL,
  `timestamp_col` datetime NULL
) ENGINE=OLAP
DUPLICATE KEY(`id`)
DISTRIBUTED BY HASH(`id`) BUCKETS 10
PROPERTIES (
"replication_allocation" = "tag.location.default: 1",
"min_load_replica_num" = "-1",
"is_being_synced" = "false",
"storage_medium" = "hdd",
"storage_format" = "V2",
"inverted_index_storage_format" = "V1",
"light_schema_change" = "true",
"disable_auto_compaction" = "false",
"enable_single_replica_compaction" = "false",
"group_commit_interval_ms" = "10000",
"group_commit_data_bytes" = "134217728"
);


-- Create events table
CREATE TABLE events (
                        analyzedClientIP VARCHAR(255),
                        appUserName VARCHAR(255),
                        assetId VARCHAR(255),
                        auditPolicy VARCHAR(255),
                        clientHostName VARCHAR(255),
                        clientPort VARCHAR(255),
                        collectionPlatform VARCHAR(255),
                        databaseName VARCHAR(255),
                        dbId BIGINT,
                        dbUserName VARCHAR(255),
                        failedSqls INT,
                        gatewayEventTime DATETIME,
                        id VARCHAR(255),
                        objectsAndVerbs VARCHAR(255),
                        objectsAndVerbsClassifications JSON,
                        originalSql VARCHAR(255),
                        osUser VARCHAR(255),
                        periodStart BIGINT,
                        serverHostName VARCHAR(255),
                        serverIP VARCHAR(255),
                        serverPort VARCHAR(255),
                        serverType VARCHAR(255),
                        serviceName VARCHAR(255),
                        sessionId BIGINT,
                        sonarGSource VARCHAR(255),
                        sourceProgram VARCHAR(255),
                        successfulSqls INT,
                        terminal VARCHAR(255),
                        timestamp DATETIME,
                        totalRecordsAffected INT,
                        utcOffset INT,
                        vendor VARCHAR(255)
)
    DISTRIBUTED BY HASH(timestamp) BUCKETS 10
PROPERTIES (
    "replication_num" = "1"
);
```

### Generate Parquet Data

You can generate sample Parquet data using either Go or Python.

#### Generate with Go

Navigate to the `load-test-data` directory (or where your Go script is located) and run:

```bash
go run generate_parquet_data.go -n 1000000 -o my_test_data.parquet
```

#### Generate with Python

1.  **Navigate to the directory**:
    ```bash
    cd ~/apache-doris/load-test-data # Or wherever your script is
    ```
2.  **Create and activate a virtual environment**:
    ```bash
    python3 -m venv venv
    source venv/bin/activate
    ```
3.  **Install dependencies**:
    ```bash
    pip install pandas pyarrow faker
    ```
4.  **Generate data**:
    ```bash
    python generate-parquet.py 1000000 my_custom_data.parquet
    ```

### Load Parquet Data into Doris

Use `curl` to stream load the generated Parquet files into the respective Doris tables.

#### Load into `parquet_data` table

```bash
curl -u root:root \
    -H "format: parquet" \
    -H "columns: id, bool_col, tinyint_col, smallint_col, int_col, bigint_col, float_col, double_col, date_string_col, string_col, timestamp_col" \
    -H "Expect:100-continue" \
    --data-binary @load-test-data/alltypes_plain.parquet \
    -XPUT http://localhost:8040/api/my_database/parquet_data/_stream_load
```

#### Load into `events` table

```bash
curl -u root:root \
  -H "format: parquet" \
    -H "columns: analyzedClientIP, appUserName, assetId, auditPolicy, clientHostName, clientPort, collectionPlatform, databaseName, dbId, dbUserName, failedSqls, gatewayEventTime, id, objectsAndVerbs, objectsAndVerbsClassifications, originalSql, osUser, periodStart, serverHostName, serverIP, serverPort, serverType, serviceName, sessionId, sonarGSource, sourceProgram, successfulSqls, terminal, timestamp, totalRecordsAffected, utcOffset, vendor" \
    -H "Expect:100-continue" \
    --data-binary @parquet-java/events2.parquet \
  -XPUT http://localhost:8040/api/my_database/events/_stream_load
```
