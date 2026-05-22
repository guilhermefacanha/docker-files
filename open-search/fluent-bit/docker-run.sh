docker rm -f fluent-bit

docker run -d --name fluent-bit \
  --network opensearch_opensearch-net \
  -v /var/lib/docker/containers:/var/lib/docker/containers:ro \
  -v ./ca.cert:/fluentbit/etc/ca.cert \
  -v ./fluent-bit.conf:/fluent-bit/etc/fluent-bit.conf \
  -v ./parsers.conf:/fluent-bit/etc/parsers.conf \
  fluent/fluent-bit:4.0.3