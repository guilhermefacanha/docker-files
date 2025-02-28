FROM --platform=linux/amd64 ubuntu

#JBOSS Variables
ENV MYVAR=1

EXPOSE 9081

USER root

RUN apt-get update \ 
	&& apt-get install -y wget unzip

RUN cd /opt \ 
    && wget "https://github.com/grafana/loki/releases/download/v2.8.6/promtail-linux-amd64.zip" \ 
	&& unzip /opt/promtail-linux-amd64.zip -d /opt/ \ 
	&& chmod a+x /opt/promtail-linux-amd64

#ENTRY
