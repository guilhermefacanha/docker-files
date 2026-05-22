FROM jenkins/jenkins:latest

#EXPOSE PORTS
EXPOSE 8280

COPY files/executors.groovy /usr/share/jenkins/ref/init.groovy.d/executors.groovy

#INSTALAR PACOTES NECESSARIOS
USER root
RUN apt-get update && apt-get install -y apt-transport-https \
       ca-certificates curl gnupg2 \
       software-properties-common
RUN curl -fsSL https://download.docker.com/linux/debian/gpg | apt-key add -
RUN apt-key fingerprint 0EBFCD88
RUN apt-get install -y maven

#VARIAVES DE AMBIENTE PARA CUSTOMIZACOES
#ENV JENKINS_OPTS --httpPort=-1 --httpsPort=8083 --httpsCertificate=/var/lib/jenkins/cert --httpsPrivateKey=/var/lib/jenkins/pk
#ENV JAVA_OPTS="-Dhudson.footerURL=http://localhost jenkins"
#ENV JAVA_OPTS="-Djava.util.logging.config.file=/var/jenkins_home/log.properties"