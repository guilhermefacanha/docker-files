# Open Search Docker

Documentation: 
https://docs.opensearch.org/docs/latest/getting-started/quickstart/

### To Run

Password info:
`minimum 8 character password and must contain at least one uppercase letter, one lowercase letter, one digit, and one special character that is strong. Password strength can be tested here: https://lowe.github.io/tryzxcvbn`

```shell
 docker compose down -v
 export OPENSEARCH_INITIAL_ADMIN_PASSWORD=1qaz@WSX3edc
 echo $OPENSEARCH_INITIAL_ADMIN_PASSWORD
 docker compose up -d
```

### To Update

```shell
 export OPENSEARCH_INITIAL_ADMIN_PASSWORD=1qaz@WSX3edc
 echo $OPENSEARCH_INITIAL_ADMIN_PASSWORD
 docker compose up -d
```

## Development Environment

For development without clustering, use the `docker-compose-dev.yml` file which runs a single OpenSearch node and dashboard with lower memory requirements.

### To Run Dev Environment

```shell
 docker compose -f docker-compose-dev.yml down -v
 export OPENSEARCH_INITIAL_ADMIN_PASSWORD=1qaz@WSX3edc
 echo $OPENSEARCH_INITIAL_ADMIN_PASSWORD
 docker compose -f docker-compose-dev.yml up -d
```

### To Update Dev Environment

```shell
 export OPENSEARCH_INITIAL_ADMIN_PASSWORD=1qaz@WSX3edc
 echo $OPENSEARCH_INITIAL_ADMIN_PASSWORD
 docker compose -f docker-compose-dev.yml up -d
```

### To Access Dev Dashboard

- **OpenSearch Dashboards**: http://localhost:5601
- **OpenSearch API**: https://localhost:9200 (requires authentication)
- **Credentials**: admin / 1qaz@WSX3edc

### To test the cluster
```shell
curl -v -u admin:1qaz@WSX3edc https://opensearch-api.gfsolucoesti.com.br/_cluster/health?pretty
```

### To Delete an Index
```shell
curl -k -X DELETE -u admin:1qaz@WSX3edc "https://localhost:9200/ged-tomcat-logs"
```

### Superset config
```shell
elasticsearch+https://admin:1qaz@WSX3edc@100.81.0.5:9200/?verify_certs=False
```

## How to Send logs in Java Apps

### Tomcat

Download the APM agent JAR (if you haven't already).

Create or modify your Tomcat's setenv.sh (in $CATALINA_BASE/bin/):

``` properties
# Add the APM agent to Tomcat
export CATALINA_OPTS="$CATALINA_OPTS -javaagent:/path/to/elastic-apm-agent.jar"
export CATALINA_OPTS="$CATALINA_OPTS -Delastic.apm.service_name=ged-tomcat"
export CATALINA_OPTS="$CATALINA_OPTS -Delastic.apm.server_url=https://opensearch-api.gfsolucoesti.com.br:8200"
export CATALINA_OPTS="$CATALINA_OPTS -Delastic.apm.secret_token=YOUR_SECRET_TOKEN"
# Capture all packages - don't set application_packages at all
# Optionally, set specific configurations
export CATALINA_OPTS="$CATALINA_OPTS -Delastic.apm.log_level=INFO"
# Use your existing CA certificate
export CATALINA_OPTS="$CATALINA_OPTS -Delastic.apm.server_cert=/path/to/fluent-bit/ca-opensearchapi-gfsolucoesti-com-br-chain.pem"
```