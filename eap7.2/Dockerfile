FROM daggerok/jboss-eap-7.2:7.2.5-centos

#Variables
ENV POSTGRES_SERVER=creasp-hml.cksiko2fdktm.sa-east-1.rds.amazonaws.com
ENV POSTGRES_PORT=5432
ENV POSTGRES_DB=tpd_dados
ENV POSTGRES_USER=trapro
ENV POSTGRES_PASS=R&crut@0
ENV MIN_POOL_SIZE=10
ENV MAX_POOL_SIZE=50

#JBOSS Variables
ENV jboss.http.port=8080
ENV jboss.https.port=8443
ENV jboss.socket.binding.port-offset=0

EXPOSE 8080 8443

#Install necessary openoffice soffice libs
#RUN sudo yum install -y libreoffice-headless libreoffice-writer libreoffice-impress libreoffice-calc

#Linux commands to create necessary permissions and symbolik links
RUN sudo ln -s /home/jboss/jboss-eap-7.2 /opt/eap \
	&& sudo mkdir /opt/deploy \
	&& sudo chown -R  jboss:jboss /opt/deploy \
	&& sudo mkdir /opt/fs \
	&& sudo chown -R  jboss:jboss /opt/fs \
	&& sudo ln -s /opt/eap/standalone/log/ /opt/log

#Create a JBoss User
RUN sudo /opt/eap/bin/add-user.sh --silent=true jbossAdmin 1qaz@WSX


#Copy driver modules and War files
COPY ./postgresql /opt/eap/modules/system/layers/base/org/postgresql
COPY ./war/*.war /opt/deploy

#Create datasource using copy pre configured standalone.xml
#COPY ./conf/standalone.xml ${JBOSS_HOME}/standalone/configuration/standalone.xml


#Create datasource using cli commands and environment variables
#ADD create-ds.sh /opt/
#RUN sh /opt/create-ds.sh

#Deploy war files
RUN cp /opt/deploy/*.war /opt/eap/standalone/deployments/
