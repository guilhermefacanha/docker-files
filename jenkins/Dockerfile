FROM jenkins/jenkins:latest

#EXPOSE PORTS
EXPOSE 8080

#VARIAVES DE AMBIENTE PARA CUSTOMIZACOES
#ENV JENKINS_OPTS --httpPort=-1 --httpsPort=8083 --httpsCertificate=/var/lib/jenkins/cert --httpsPrivateKey=/var/lib/jenkins/pk
#ENV JAVA_OPTS="-Dhudson.footerURL=http://localhost jenkins"
#ENV JAVA_OPTS="-Djava.util.logging.config.file=/var/jenkins_home/log.properties"

COPY files/executors.groovy /usr/share/jenkins/ref/init.groovy.d/executors.groovy
