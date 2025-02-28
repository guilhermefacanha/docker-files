

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
