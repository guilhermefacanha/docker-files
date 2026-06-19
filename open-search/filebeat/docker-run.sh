#!/bin/bash

docker rm -f filebeat

docker run -d --name filebeat \
  --user=root \
  --network opensearch_opensearch-net \
  -v /var/lib/docker/containers:/var/lib/docker/containers:ro \
  -v $(pwd)/filebeat.yml:/usr/share/filebeat/filebeat.yml:ro \
  docker.elastic.co/beats/filebeat:8.13.4