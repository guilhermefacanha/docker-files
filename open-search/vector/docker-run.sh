#!/bin/bash

docker rm -f vector

docker run -d \
  --name vector \
  -v $(pwd)/vector.yaml:/etc/vector/vector.yaml:ro \
  -v /var/lib/docker/containers:/var/lib/docker/containers:ro \
  -v /var/lib/vector:/var/lib/vector \
  -e VECTOR_LOG=debug \
  timberio/vector:latest-alpine