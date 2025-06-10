# Apache Doris Docker Dev Env

```shell
sh setup.sh
```

Test the connections
``` shell
## Check the FE status to ensure that both the Join and Alive columns are true.
mysql -uroot -P9030 -h127.0.0.1 -e 'SELECT `host`, `join`, `alive` FROM frontends()'
+-----------+------+-------+
| host      | join | alive |
+-----------+------+-------+
| 127.0.0.1 | true | true  |
+-----------+------+-------+

## Check the BE status to ensure that the Alive column is true.
mysql -uroot -P9030 -h127.0.0.1 -e 'SELECT `host`, `alive` FROM backends()'
+-----------+-------+
| host      | alive |
+-----------+-------+
| 127.0.0.1 |     1 |
+-----------+-------+

```


## Load Test Data from Parquet

Create Database and Table
```sql
CREATE DATABASE IF NOT EXISTS my_database;

--create sample table
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


--create events table
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

Generate load parquet file data with Go
```shell
go run generate_parquet_data.go -n 1000000 -o my_test_data.parquet
```

Generate load parquet file data with Python
```shell

# Navigate to your project directory (e.g., apache-doris or load-test-data)
cd ~/apache-doris/load-test-data # Or wherever your script is

# Create a virtual environment
python3 -m venv venv

# Activate the virtual environment
source venv/bin/activate

# Now install pandas, pyarrow, and faker into the activated environment
pip install pandas pyarrow faker

python generate-parquet.py 1000000 my_custom_data.parquet

```

```shell
#sample table
curl -u root:root \
    -H "format: parquet" \
    -H "columns: id, bool_col, tinyint_col, smallint_col, int_col, bigint_col, float_col, double_col, date_string_col, string_col, timestamp_col" \
    -H "Expect:100-continue" \
    --data-binary @load-test-data/alltypes_plain.parquet \
    -XPUT http://localhost:8040/api/my_database/parquet_data/_stream_load

#events table
curl -u root:root \
  -H "format: parquet" \
    -H "columns: analyzedClientIP, appUserName, assetId, auditPolicy, clientHostName, clientPort, collectionPlatform, databaseName, dbId, dbUserName, failedSqls, gatewayEventTime, id, objectsAndVerbs, objectsAndVerbsClassifications, originalSql, osUser, periodStart, serverHostName, serverIP, serverPort, serverType, serviceName, sessionId, sonarGSource, sourceProgram, successfulSqls, terminal, timestamp, totalRecordsAffected, utcOffset, vendor" \
    -H "Expect:100-continue" \
    --data-binary @parquet-java/events2.parquet \
  -XPUT http://localhost:8040/api/my_database/events/_stream_load

```