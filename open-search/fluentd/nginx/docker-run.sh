#!/bin/bash

docker rm -f fluentd

docker run -d \
  --user root \
  --name fluentd \
  -v /var/log/nginx:/var/log/nginx:ro \
  -v $(pwd)/fluentd.conf:/fluentd/etc/fluentd.conf \
  -e FLUENTD_CONF=fluentd.conf \
  --log-driver json-file \
  --log-opt max-size=10m \
  --log-opt max-file=3 \
  fluentd-opensearch