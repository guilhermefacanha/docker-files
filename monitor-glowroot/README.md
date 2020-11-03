# Install Agent

# Download and unzip glowroot-0.13.6-dist.zip.

$ https://github.com/glowroot/glowroot/releases/download/v0.13.6/glowroot-0.13.6-dist.zip

$ unzip install/glowroot-0.13.6-dist.zip

$ vim /opt/glowroot/glowroot.properties

agent.id=eap
collector.address=localhost:8181

### For Jboss EAP
$ vim /opt/jboss-eap/bin/standalone.conf

#change line from

JAVA_OPTS="-Xms1303m -Xmx1303m -XX:MetaspaceSize=96M -XX:MaxMetaspaceSize=256m -Djava.net.preferIPv4Stack=true"

to

JAVA_OPTS="-javaagent:/opt/glowroot/glowroot.jar -Xms1303m -Xmx1303m -XX:MetaspaceSize=96M -XX:MaxMetaspaceSize=256m -Djava.net.preferIPv4Stack=true"

### For TOMCAT
vim /opt/tomcat/bin/setenv.sh

export CATALINA_OPTS="$CATALINA_OPTS -javaagent:/opt/glowroot/glowroot.jar"



References:
https://github.com/glowroot/glowroot/wiki/Central-Collector-Installation
https://github.com/glowroot/glowroot/wiki/Agent-Installation-(for-Central-Collector)
