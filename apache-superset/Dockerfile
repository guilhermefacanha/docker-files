FROM apache/superset

# Switching to root to install the required packages
USER root

RUN apt-get update && apt-get install -y vim

ENV SUPERSET_SECRET_KEY=ee15d026-c939-46bd-a00c-22dd0115e0d8
ENV SUPERSET_CONFIG_PATH /app/superset_config.py

COPY files/superset_config.py /app/superset_config.py

# Example: installing the MySQL driver to connect to the metadata database
# if you prefer Postgres, you may want to use `psycopg2-binary` instead
RUN pip install mysqlclient
RUN pip install psycopg2-binary

# Example: installing a driver to connect to Redshift
# Find which driver you need based on the analytics database
# you want to connect to here:
# https://superset.apache.org/installation.html#database-dependencies
# RUN pip install sqlalchemy-redshift

# Switching back to using the `superset` user
USER superset

RUN superset fab create-admin --username adminSuperset --firstname Superset --lastname Admin --email admin@superset.com --password admin
RUN superset db upgrade
RUN superset init
RUN export SUPERSET_FEATURE_FLAGS='{"DRILL_TO_DETAIL": true}'