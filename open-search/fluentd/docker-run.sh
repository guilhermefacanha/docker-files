#!/bin/bash

docker rm -f fluentd

docker run -d --name fluentd \
  --platform linux/arm64 \
  --user root \
  --network opensearch_opensearch-net \
  -v /var/lib/docker/containers:/var/lib/docker/containers:ro \
  -v $(pwd)/fluentd.conf:/fluentd/etc/fluent.conf:ro \
  fluentd-opensearch