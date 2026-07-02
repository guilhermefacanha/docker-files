# GCP & Azure DSF Lab Coverage Analysis

**Date:** 2026-06-26  
**Source docs:**  
- Thales DSF Hub Reference Guide — Google Cloud (GCP) Data Sources (Jun 25, 2026)  
- Thales DSF Hub Reference Guide — Azure Data Sources (Jun 25, 2026)  
- floci.io/gcp/#services  
- floci.io/az/#services

---

## Context

The `dsf-lab-builder` currently provides a local AWS environment using **floci** (formerly LocalStack) to simulate AWS services for DSF integration testing. This analysis evaluates whether we can extend the same approach to **GCP** and **Azure** using `floci-gcp` and `floci-az`.

The key insight: DSF does **not** talk directly to the databases. It reads audit logs from a **log aggregator**:
- **GCP:** Cloud Logging → Log Router Sink → **Pub/Sub** → DSF Agentless Gateway
- **Azure:** Database Diagnostic Settings → **Azure Event Hubs** → DSF Agentless Gateway

So for a working lab we need: **(a) log aggregator emulation** + **(b) a database that produces the right audit log format**.

---

## Google Cloud Platform (GCP)

### GCP DSF Data Sources (from Thales guide)

| Data Source | Log Mechanism | Auth |
|---|---|---|
| AlloyDB for PostgreSQL | Cloud Logging → Pub/Sub | IAM Service Account |
| BigQuery | Cloud Logging → Pub/Sub | IAM Service Account |
| Bigtable | Cloud Logging → Pub/Sub | IAM Service Account |
| Cloud SQL for MySQL | Cloud Logging → Pub/Sub | IAM Service Account |
| Cloud SQL for PostgreSQL | Cloud Logging → Pub/Sub | IAM Service Account |
| Cloud SQL for SQL Server (PubSub) | Cloud Logging → Pub/Sub | IAM Service Account |
| Cloud SQL for SQL Server (Storage) | Cloud Logging → Cloud Storage Bucket | IAM Service Account |
| Firestore | Cloud Logging → Pub/Sub | IAM Service Account |
| Spanner | Cloud Logging → Pub/Sub | IAM Service Account |

### floci-gcp Supported Services (17 services on port 4588)

| Service | Protocol | DSF Relevance |
|---|---|---|
| Cloud Storage | REST JSON / XML | ✅ Required (SQL Server Storage path) |
| **Pub/Sub** | gRPC | ✅ **Core** — DSF pulls all GCP audit logs from here |
| **Firestore** | gRPC | ✅ Database emulator available |
| Datastore | HTTP/protobuf | — |
| Secret Manager | gRPC | — |
| **IAM** | REST JSON | ✅ **Core** — Service Account auth |
| Managed Kafka | REST JSON + Redpanda | — |
| Cloud Tasks | gRPC, v2 | — |
| Cloud Run | REST JSON | — |
| **Cloud SQL** | REST JSON | ✅ Postgres/MySQL only (no SQL Server) |
| Cloud Functions | REST JSON | — |
| Cloud KMS | gRPC, REST JSON | — |
| **Cloud Logging** | gRPC, REST JSON | ✅ **Core** — Log Router Sinks route logs to Pub/Sub |
| Cloud Monitoring | gRPC, REST JSON | ✅ Useful |
| Cloud Scheduler | gRPC, REST JSON | — |
| GKE | REST JSON (k3s/mocked) | — |
| Operations | gRPC, REST JSON, LRO | — |

### GCP Coverage Analysis

#### What IS covered by floci-gcp

The **entire GCP audit log pipeline** is covered:

```
Database → Cloud Logging (floci) → Log Router Sink → Pub/Sub (floci) → DSF Gateway
```

- **Cloud Logging** ✅ — can receive and route logs via Log Router Sinks  
- **Pub/Sub** ✅ — DSF Agentless Gateway can subscribe and pull audit events  
- **IAM** ✅ — Service Account authentication works  
- **Cloud Storage** ✅ — covers the alternate SQL Server Storage Bucket path  
- **Cloud SQL (MySQL/PostgreSQL)** ✅ — database emulator for Cloud SQL MySQL and PostgreSQL  
- **Firestore** ✅ — direct database emulator available  

#### What is MISSING from floci-gcp

| Missing Service | Impact | Notes |
|---|---|---|
| **BigQuery** | ❌ Cannot emulate BigQuery data source | No BigQuery emulator in floci. Google's official BigQuery emulator exists (`ghcr.io/goccy/bigquery-emulator`) — needs contribution to floci. |
| **Bigtable** | ❌ Cannot emulate Bigtable data source | Google provides an official Bigtable emulator (`gcr.io/google.com/cloudsdktool`) — needs contribution to floci. |
| **Spanner** | ❌ Cannot emulate Spanner data source | Google provides an official Spanner emulator — needs contribution to floci. |
| **AlloyDB for PostgreSQL** | ⚠️ Partial | No AlloyDB ARM/management API. However, since AlloyDB is PostgreSQL-compatible with pgaudit, it can be approximated with a PostgreSQL Docker container + pgaudit, routing logs manually to Pub/Sub. |
| **Cloud SQL for SQL Server** | ⚠️ Partial | floci Cloud SQL only supports Postgres/MySQL. SQL Server needs a separate container (mcr.microsoft.com/mssql/server) + integration into floci Cloud SQL. |

### GCP Verdict

**We already have what we need for the log pipeline.** The core infrastructure (Pub/Sub, Cloud Logging, IAM, Cloud Storage) is fully covered by floci-gcp.

The gaps are at the **database emulator level** — BigQuery, Bigtable, and Spanner do not exist in floci. However, the floci OSS project could be extended with:
1. BigQuery → integrate `ghcr.io/goccy/bigquery-emulator`
2. Bigtable → integrate Google's official Bigtable emulator
3. Spanner → integrate Google's official Spanner emulator
4. AlloyDB → workaround with PostgreSQL + pgaudit is viable today
5. Cloud SQL for SQL Server → add SQL Server container (low effort)

---

## Azure

### Azure DSF Data Sources (from Thales guide)

| Data Source | Log Mechanism | Auth |
|---|---|---|
| Azure Blob Storage | Diagnostic Settings → Event Hubs | Entra ID / Secret Key |
| Azure Cosmos DB for MongoDB | Diagnostic Settings → Event Hubs | Entra ID / Secret Key |
| Azure Cosmos DB for NoSQL | Diagnostic Settings → Event Hubs | Entra ID / Secret Key |
| Azure Cosmos DB for Table | Diagnostic Settings → Event Hubs | Entra ID / Secret Key |
| Azure Database for MariaDB | Diagnostic Settings → Event Hubs | Entra ID / Secret Key |
| Azure Database for MySQL (Single) | Diagnostic Settings → Event Hubs | Entra ID / Secret Key |
| Azure Database for MySQL (Flexible) | Diagnostic Settings → Event Hubs | Entra ID / Secret Key |
| Azure Database for PostgreSQL (Single) | Diagnostic Settings → Event Hubs | Entra ID / Secret Key |
| Azure Database for PostgreSQL (Flexible) | Diagnostic Settings → Event Hubs | Entra ID / Secret Key |
| Azure Databricks | Diagnostic Settings → Event Hubs | Entra ID / Secret Key |
| Azure Data Explorer | Diagnostic Settings → Event Hubs | Entra ID / Secret Key |
| Azure Data Lake Storage Gen2 | Diagnostic Settings → Event Hubs | Entra ID / Secret Key |
| Azure Dedicated SQL Pool | Diagnostic Settings → Event Hubs | Entra ID / Secret Key |
| Azure SQL Managed Instance | Diagnostic Settings → Event Hubs | Entra ID / Secret Key |
| Azure SQL Server | Diagnostic Settings → Event Hubs | Entra ID / Secret Key |

### floci-az Supported Services (21 services on port 4577)

| Service | Protocol | DSF Relevance |
|---|---|---|
| **Blob Storage** | REST XML/JSON | ✅ **Core** — DSF metadata storage + data source |
| Queue Storage | REST JSON | — |
| Table Storage | OData/REST JSON | ✅ Useful for Cosmos DB Table emulation |
| Azure Functions | HTTP + Timer | — |
| App Configuration | REST JSON | — |
| Key Vault | Secrets, keys, certs | — |
| **Event Hubs** | AMQP, Kafka, REST | ✅ **Core** — ALL Azure data sources route logs here |
| Service Bus | AMQP topics/queues | — |
| **Cosmos DB** | SQL, Mongo, Cassandra, Gremlin | ✅ Covers 3 of 4 Cosmos DB APIs |
| AKS | REST JSON, k3s/mocked | — |
| **Azure SQL** | ARM + SQL Server via Docker | ✅ Partial — covers Azure SQL Server |
| API Management | ARM, REST JSON | — |
| Virtual Machines | ARM, REST JSON | — |
| Cache for Redis | ARM + Redis via Docker | — |
| Container Registry | ARM + registry:2 | — |
| Virtual Network | ARM, REST JSON | — |
| **Azure Monitor** | Logs, metrics, KQL | ✅ **Core** — Diagnostic settings routing |
| **Microsoft Entra ID** | OAuth2, OIDC, JWKS | ✅ **Core** — Managed Identity + Client Secret auth |
| Email Communication | REST JSON, ARM | — |
| Container Apps | ARM, REST JSON | — |
| Event Grid | REST JSON, CloudEvents | — |

### Azure Coverage Analysis

#### What IS covered by floci-az

The **entire Azure audit log pipeline** is covered:

```
Database → Diagnostic Settings → Azure Monitor (floci) → Event Hubs (floci) → DSF Gateway
                                                             ↑
                                              Blob Storage (floci) [metadata]
                                              Entra ID (floci) [auth]
```

- **Event Hubs** ✅ — **The most critical piece.** All 15 Azure data sources use Event Hubs as the log aggregator. AMQP protocol is supported, which is exactly what DSF uses.  
- **Blob Storage** ✅ — Required for Event Hub checkpoint metadata storage  
- **Microsoft Entra ID** ✅ — Managed Identity and Client Secret auth both supported  
- **Azure Monitor** ✅ — Diagnostic settings configuration  
- **Cosmos DB** ✅ — SQL/Core, MongoDB, Cassandra, Gremlin APIs (covers 3 of 4 Cosmos DB DSF sources); Table API via Table Storage  
- **Azure SQL** ✅ — Basic SQL Server coverage via Docker  

#### What is MISSING from floci-az

| Missing Service | Impact | Notes |
|---|---|---|
| **Azure Database for MySQL** (Single + Flexible) | ❌ No managed MySQL emulator | MySQL Docker container exists but no Azure ARM management plane to configure diagnostic settings |
| **Azure Database for MariaDB** | ❌ No managed MariaDB emulator | Same as MySQL — needs ARM API stub + Docker container |
| **Azure Database for PostgreSQL** (Single + Flexible) | ❌ No managed PostgreSQL emulator | Same pattern — needs ARM API stub + Docker container |
| **Azure Databricks** | ❌ No Databricks emulator | Very complex proprietary service; no viable open-source alternative |
| **Azure Data Explorer** (Kusto) | ❌ No Kusto emulator | Proprietary query engine; no viable open-source alternative |
| **Azure Data Lake Storage Gen2** | ⚠️ Partial | Gen2 adds hierarchical namespace on top of Blob Storage. Could be implemented as an extension to existing Blob Storage in floci. |
| **Azure Dedicated SQL Pool** (Synapse) | ❌ No Synapse emulator | Complex analytical service; no viable open-source alternative |
| **Azure SQL Managed Instance** | ⚠️ Partial | Azure SQL in floci covers basic SQL Server. Managed Instance-specific ARM APIs are missing but the database wire protocol is the same. |
| **Cosmos DB Table API** | ⚠️ Needs verification | Table Storage exists in floci-az but Cosmos DB for Table is listed separately in DSF — may need specific audit log format support |

### Azure Verdict

**The log pipeline is entirely ready.** Event Hubs (with AMQP), Blob Storage (metadata), Microsoft Entra ID (auth), and Azure Monitor (diagnostic settings) are all supported by floci-az. This means any database that can send diagnostic logs to an Event Hub endpoint will work.

The gaps are at the **managed database service level**. For MySQL, MariaDB, and PostgreSQL, the actual database can run as a Docker container — the missing piece is the ARM management API stub that simulates Azure's diagnostic settings UI/API (the step that routes logs to Event Hubs). This is a **lower-complexity contribution** to floci-az compared to proprietary services like Databricks or Data Explorer.

---

## Summary: What Can We Do Today vs. What Requires OSS Contribution

### GCP

| Scenario | Status | Action Required |
|---|---|---|
| AlloyDB for PostgreSQL lab | ✅ Workable today | Use PostgreSQL + pgaudit, route logs to floci Pub/Sub |
| BigQuery lab | ❌ Blocked | Contribute BigQuery emulator to floci-gcp |
| Bigtable lab | ❌ Blocked | Contribute Bigtable emulator integration to floci-gcp |
| Cloud SQL for MySQL lab | ✅ Ready today | floci Cloud SQL (MySQL) is available |
| Cloud SQL for PostgreSQL lab | ✅ Ready today | floci Cloud SQL (PostgreSQL) is available |
| Cloud SQL for SQL Server lab | ⚠️ Partial | Add SQL Server Docker container to floci Cloud SQL |
| Firestore lab | ✅ Ready today | floci Firestore is available |
| Spanner lab | ❌ Blocked | Contribute Spanner emulator integration to floci-gcp |

### Azure

| Scenario | Status | Action Required |
|---|---|---|
| Azure Blob Storage lab | ✅ Ready today | floci Blob Storage + Event Hubs available |
| Cosmos DB (MongoDB/NoSQL/Gremlin) lab | ✅ Ready today | floci Cosmos DB covers these APIs |
| Cosmos DB Table lab | ⚠️ Needs testing | floci Table Storage exists; verify log format compatibility |
| Azure Database for MySQL lab | ⚠️ Partial | Database Docker container available; ARM diagnostic API stub needed in floci-az |
| Azure Database for MariaDB lab | ⚠️ Partial | Same as MySQL above |
| Azure Database for PostgreSQL lab | ⚠️ Partial | Same as MySQL above |
| Azure SQL Server lab | ✅ Ready today | floci Azure SQL covers SQL Server via Docker |
| Azure SQL Managed Instance lab | ⚠️ Partial | floci Azure SQL covers wire protocol; Managed Instance ARM API incomplete |
| Azure Databricks lab | ❌ Blocked | No viable emulator; requires OSS contribution or skip |
| Azure Data Explorer lab | ❌ Blocked | Proprietary Kusto engine; no viable emulator |
| Azure Data Lake Storage Gen2 lab | ⚠️ Partial | Could be built on top of existing floci Blob Storage |
| Azure Dedicated SQL Pool lab | ❌ Blocked | Synapse Analytics has no viable local emulator |

---

## Recommended OSS Contributions to floci

### High Priority (enables the most DSF coverage)

1. **floci-gcp: BigQuery emulator** — Integrate `ghcr.io/goccy/bigquery-emulator`. BigQuery is one of GCP's most common DSF data sources.
2. **floci-az: Azure Database for MySQL/MariaDB/PostgreSQL** — Add ARM management API stubs + Docker containers. These 5 data sources share the same architecture and a single implementation pattern covers all of them.
3. **floci-az: Azure Data Lake Storage Gen2** — Extend the existing Blob Storage service with hierarchical namespace support.

### Medium Priority

4. **floci-gcp: Bigtable emulator** — Integrate Google's official Bigtace emulator.
5. **floci-gcp: Spanner emulator** — Integrate Google's official Spanner emulator.
6. **floci-gcp: Cloud SQL for SQL Server** — Add SQL Server Docker container alongside existing MySQL/Postgres.
7. **floci-az: Azure SQL Managed Instance** — Extend existing Azure SQL with Managed Instance ARM APIs.

### Low Priority / Out of Scope

8. **floci-az: Azure Databricks** — No viable open-source emulator; proprietary cloud service.
9. **floci-az: Azure Data Explorer** — Proprietary Kusto engine; no viable emulator.
10. **floci-az: Azure Dedicated SQL Pool** — Synapse Analytics is complex; no viable local emulator.

---

## Architecture Diagram: Lab Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                         GCP Lab (floci-gcp, port 4588)         │
│                                                                  │
│  PostgreSQL/MySQL  ──► Cloud Logging ──► Pub/Sub ──► DSF Hub    │
│  (Docker)               (floci)         (floci)                  │
│                             │                                    │
│                         IAM / Service Account (floci)            │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                       Azure Lab (floci-az, port 4577)           │
│                                                                  │
│  MySQL/MariaDB/    ──► Azure Monitor ──► Event Hubs ──► DSF Hub │
│  PostgreSQL/SQL         (floci)          (floci)                 │
│  (Docker)                                   │                   │
│                         Blob Storage (floci) [metadata]          │
│                         Microsoft Entra ID (floci) [auth]        │
└─────────────────────────────────────────────────────────────────┘
```

---

## References

- Thales DSF GCP Guide: `scripts/docs/onboarding_databases_to_dsf_hub_reference_guide_google_cloud_(gcp)_data_sources_2026-06-25-16-04-53.pdf`
- Thales DSF Azure Guide: `scripts/docs/onboarding_databases_to_dsf_hub_reference_guide_azure_data_sources_2026-06-25-16-07-21.pdf`
- floci GCP services: https://floci.io/gcp/#services
- floci Azure services: https://floci.io/az/#services
