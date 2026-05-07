#FROM apache/superset:4.1.2
FROM apache/superset:latest

# Switching to root to install the required packages and new drivers
USER root

RUN apt-get update && apt-get install -y vim openjdk-17-jdk pkg-config default-libmysqlclient-dev build-essential libmariadb-dev

# Ensure pip is up-to-date
RUN pip install --no-cache-dir --upgrade pip

# Install common Superset database dependencies
# This ensures that all standard drivers Superset might expect are present
RUN pip install --no-cache-dir \
    mysqlclient \
    psycopg2-binary \
    sqlalchemy-redshift \
    pybigquery \
    trino \
    pymongosql

# Install specific drivers for Drill and JDBC/JPype
RUN pip install --no-cache-dir \
    sqlalchemy-drill \
    JayDeBeApi \
    JPype1

# --- START: Additions for requirements-local.txt ---

ENV SUPERSET_SECRET_KEY=ee15d026-c939-46bd-a00c-22dd0115e0d8

#ENV SUPERSET_CONFIG_PATH /app/superset_config.py
#COPY files/superset_config.py /app/superset_config.py

# Switching back to using the `superset` user
USER superset

RUN superset fab create-admin --username adminSuperset --firstname Superset --lastname Admin --email admin@superset.com --password admin
RUN superset db upgrade
RUN superset init

# Feature flags are best set via environment variables in docker-compose.yml
# or directly in superset_config.py for persistence across container runs.
# This RUN command only sets it for the duration of the build step.
# For example, in docker-compose.yml under superset-app service:
# environment:
#   - SUPERSET_FEATURE_FLAGS='{"DRILL_TO_DETAIL": true}'
