# Run MSSQL server container

Reference: https://hub.docker.com/r/microsoft/mssql-server 

Default User: `sa`


``` shell

export DOCKER_DEFAULT_PLATFORM=linux/amd64
docker run -e "ACCEPT_EULA=Y" -e "MSSQL_SA_PASSWORD=1qaz@WSX" -p 1433:1433 --name sqlserver -d mcr.microsoft.com/mssql/server:2022-latest

```