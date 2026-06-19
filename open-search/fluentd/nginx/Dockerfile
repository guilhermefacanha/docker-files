FROM fluent/fluentd
USER root
RUN apt-get update && apt-get install -y build-essential ruby-dev libgeoip-dev autoconf automake libtool
RUN gem install fluent-plugin-opensearch
RUN gem install fluent-plugin-geoip
COPY GeoLite2-City.mmdb /fluentd/GeoLite2-City.mmdb
USER fluent