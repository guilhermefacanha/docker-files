-- DSF Hub mandatory audit configuration
-- Runs once on first container initialization via docker-entrypoint-initdb.d

ALTER SYSTEM SET log_connections = 'on';
ALTER SYSTEM SET log_disconnections = 'on';
ALTER SYSTEM SET log_hostname = 'on';
ALTER SYSTEM SET pgaudit.log = 'all';
ALTER SYSTEM SET log_line_prefix = '%t:%r:%u@%d:[%p]:';

CREATE EXTENSION IF NOT EXISTS pgaudit;

-- Audit management user (rds_superuser is RDS-specific; create it locally)
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'rds_superuser') THEN
    CREATE ROLE rds_superuser;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'auditmgr') THEN
    CREATE USER auditmgr WITH PASSWORD 'AuditMgr$ecret1' CREATEROLE;
    GRANT rds_superuser TO auditmgr;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_user') THEN
    CREATE USER app_user WITH PASSWORD 'password' SUPERUSER;
  END IF;
END
$$;

SELECT pg_reload_conf();
