# Configurar ContextPath da aplicacao

```shell
docker exec -it registry-web bash

vi conf/server.xml
#change line `<Context path="${contextPath}" docBase="ROOT"/>` to
<Context path="/registry-web" docBase="ROOT"/>

exit

docker restart registry-web

```