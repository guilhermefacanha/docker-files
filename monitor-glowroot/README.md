# Monitor Glowroot

> read docker-run.sh to understand how to deploy central server

## Client Wildfly

1. download client glowroot at: `https://github.com/glowroot/glowroot/releases/download/v0.13.6/glowroot-0.13.6-dist.zip` (check for new versions)

2. unzip client to local folder example: `/opt/glowroot`

3. add javaagent config to wildfly file ``
   3.1 Example:
      ``` properties

            echo 'JAVA_OPTS="-javaagent:/opt/glowroot-agent/glowroot/glowroot.jar -Dglowroot.agent.id=[agentId] -Dglowroot.collector.address=[glowroot_central_server]:[port] $JAVA_OPTS"' >> /opt/eap/bin/standalone.conf

      ```

## Other Servers

> check `https://github.com/glowroot/glowroot/wiki/Where-are-my-application-server's-JVM-args%3F`


## HELP CASSANDRA

``` shell
  
  527  /usr/bin/cqlsh
  528  cassandra
  529  cassandra -R
  534  sudo netstat -ntlp | grep 9042
  
STOP GLOWROOT AND RUN MANUAL
> systemctl stop glowroot
> java -jar /opt/glowroot-central/glowroot-central.jar truncate-all-data
> nodetool clearsnapshot glowroot --all
> nodetool cleanup

> tail -f -n 200 /opt/glowroot-central/logs/glowroot-central.log

```