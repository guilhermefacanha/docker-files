# Docker Apache Superset

To build image

```bash 
#build default
docker build -f Dockerfile -t superset .

#build with apache drill
docker-compose -p superset_drill up --build -d

#remove
docker-compose -p superset_drill down

```

To Run

```bash 
docker run -d --name superset -p 8088:8088 --restart always superset

# run with drill
docker run -d --name superset -p 8047:8047 -p 8088:8088 --restart always superset
```

Test
```shell
# in apache drill config mongo using storages
#in sql lab type command
show schemas;
```

Driver
```shell
drill+sadrill://18.207.157.117:8047/mongo?use_ssl=False
```

# Postgres - Create readonly user for superset

### To create a new user in PostgreSQL:

> CREATE USER superset_consulta WITH PASSWORD 'your_password';

### GRANT the CONNECT access:

> GRANT CONNECT ON DATABASE database_name TO superset_consulta;

### Then GRANT USAGE on schema:

> GRANT USAGE ON SCHEMA schema_name TO superset_consulta;

### GRANT SELECT

#### Grant SELECT for a specific table:

> GRANT SELECT ON table_name TO superset_consulta; 

#### Grant SELECT for multiple tables:

> GRANT SELECT ON ALL TABLES IN SCHEMA schema_name TO username;

### If you want to grant access to the new table in the future automatically, you have to alter default:

> ALTER DEFAULT PRIVILEGES IN SCHEMA schema_name

> GRANT SELECT ON TABLES TO username;
