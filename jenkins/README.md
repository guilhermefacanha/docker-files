

## Example of docker init agent

localhost:8005 is the main url and port of jenkins control

```shell
docker run -d -u root --restart unless-stopped --name jenkins-agent -v /opt/jenkins:/home/jenkins -v $(which docker):/usr/bin/docker -v /var/run/docker.sock:/var/run/docker.sock --net=host --init jenkins-agent -url http://localhost:8005 2fdfef051ee9b677fbcae4441a85688cec16f839e610135d04936dc894783223 Node001
2fdfef051ee9b677fbcae4441a85688cec16f839e610135d04936dc894783223
```