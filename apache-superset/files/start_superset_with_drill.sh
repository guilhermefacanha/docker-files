#!/bin/bash

# --- Start Apache Drill in embedded mode ---
echo "Starting Apache Drill in embedded mode..."
${DRILL_HOME}/bin/drill-embedded &

# --- Wait for Drill to initialize ---
echo "Waiting for Drill to start..."
while ! curl -s http://localhost:8047/status > /dev/null; do
  echo "Drill not yet ready, waiting..."
  sleep 5
done
echo "Drill is ready!"

# --- Keep Drill Running ---
# Ensure Drill remains running in the background
if ! pgrep -f drill-embedded > /dev/null; then
  echo "Drill process terminated unexpectedly. Exiting..."
  exit 1
fi

# --- Start Apache Superset ---
echo "Starting Apache Superset..."
exec "$@"