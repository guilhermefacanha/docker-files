package env

// rds_generator.go — continuous SQL traffic generator for RDS instances.
// Uses Go database/sql drivers directly — no CLI tools required.
// Drivers: github.com/lib/pq (postgres), github.com/go-sql-driver/mysql (mysql/mariadb).

import (
	"context"
	"database/sql"
	"fmt"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"dsf-lab-builder/internal/docker"
	_ "github.com/go-sql-driver/mysql" // mysql + mariadb driver
	_ "github.com/lib/pq"              // postgres driver
)

// RDSGenStats holds live counters for a running generator session.
type RDSGenStats struct {
	Total      int `json:"total"`
	Success    int `json:"success"`
	Errors     int `json:"errors"`
	Inserts    int `json:"inserts"`
	Selects    int `json:"selects"`
	Updates    int `json:"updates"`
	Deletes    int `json:"deletes"`
	LoginFails int `json:"loginFails"`
	SQLErrors  int `json:"sqlErrors"`
	PermDenied int `json:"permDenied"`
	Grants     int `json:"grants"`
	Revokes    int `json:"revokes"`
	Batch      int `json:"batch"`
}

// labUser is a named connection pool used during rotation.
type labUser struct {
	name string
	db   *sql.DB
}

type rdsGen struct {
	mu         sync.Mutex
	stats      RDSGenStats
	lines      []string // rolling in-memory log (last 200 lines)
	stop       chan struct{}
	logFile    *os.File
	adminDB    *sql.DB   // admin connection for DDL, GRANT, REVOKE
	users      []labUser // rotating pool: lab_admin, lab_writer, lab_reader
	instanceID string    // RDS instance ID — used for docker exec root fallback
}

var (
	rdsGens   = map[string]*rdsGen{}
	rdsGensMu sync.Mutex
)

func RDSGenKey(envID, instanceID string) string { return envID + ":" + instanceID }

func StartRDSGen(envID, instanceID, engine, host, port string, cfg *Config) error {
	key := RDSGenKey(envID, instanceID)
	slot := docker.SlotFromID(envID)

	logDir := filepath.Join(cfg.Workspace, fmt.Sprintf("env%d", slot), "data")
	os.MkdirAll(logDir, 0755)
	f, err := os.Create(filepath.Join(logDir, "rds-gen-"+instanceID+".log"))
	if err != nil {
		return fmt.Errorf("create log: %w", err)
	}

	rdsGensMu.Lock()
	defer rdsGensMu.Unlock()
	if _, ok := rdsGens[key]; ok {
		f.Close()
		return fmt.Errorf("generator already running for %s", instanceID)
	}
	g := &rdsGen{stop: make(chan struct{}), logFile: f, instanceID: instanceID}
	rdsGens[key] = g
	go g.run(engine, host, port)
	return nil
}

func StopRDSGen(key string) error {
	rdsGensMu.Lock()
	g, ok := rdsGens[key]
	if !ok {
		rdsGensMu.Unlock()
		return fmt.Errorf("no generator running for %s", key)
	}
	delete(rdsGens, key)
	rdsGensMu.Unlock()
	close(g.stop)
	return nil
}

func GetRDSGenStatus(key string, n int) (lines []string, running bool, stats RDSGenStats) {
	rdsGensMu.Lock()
	g, running := rdsGens[key]
	rdsGensMu.Unlock()
	if !running || g == nil {
		return nil, false, RDSGenStats{}
	}
	g.mu.Lock()
	all := g.lines
	stats = g.stats
	g.mu.Unlock()
	if len(all) > n {
		all = all[len(all)-n:]
	}
	return append([]string(nil), all...), true, stats
}

func IsRDSGenRunning(key string) bool {
	rdsGensMu.Lock()
	defer rdsGensMu.Unlock()
	_, ok := rdsGens[key]
	return ok
}

// ── generator lifecycle ───────────────────────────────────────────────────────

var (
	depts    = []string{"Engineering", "Sales", "Finance", "Marketing", "Support", "Legal"}
	products = []string{"Widget A", "Widget B", "Service Plan", "Licence", "Module X", "Add-on Y"}
	statuses = []string{"pending", "processing", "completed", "failed", "refunded"}
)

// labUserSpec describes one of the rotating lab users and their privilege level.
type labUserSpec struct {
	name string
	pass string
	role string // "admin" | "writer" | "reader"
}

var labUserSpecs = []labUserSpec{
	{name: "lab_admin",  pass: "Admin$ecret1",  role: "admin"},
	{name: "lab_writer", pass: "Writer$ecret1", role: "writer"},
	{name: "lab_reader", pass: "Reader$ecret1", role: "reader"},
}

func (g *rdsGen) run(engine, host, port string) {
	defer func() {
		for _, u := range g.users {
			if u.db != nil {
				u.db.Close()
			}
		}
		if g.adminDB != nil {
			g.adminDB.Close()
		}
		if g.logFile != nil {
			g.logFile.Close()
		}
	}()

	g.logLine(fmt.Sprintf("=== RDS Generator started  engine=%s  endpoint=%s:%s ===", engine, host, port))

	if engine != "postgres" {
		if err := g.ensureMySQLDatabase(engine, host, port); err != nil {
			g.logLine("[ERROR] Cannot create dsf_lab database: " + err.Error())
			g.logLine("[INFO]  Make sure the RDS instance status is 'available' in the Resources tab.")
			return
		}
	}

	db, err := openDB(engine, host, port, "admin", "secret123", dbForEngine(engine))
	if err != nil {
		g.logLine("[ERROR] Cannot connect: " + err.Error())
		g.logLine("[INFO]  Make sure the RDS instance status is 'available' in the Resources tab.")
		return
	}
	g.adminDB = db
	g.logLine(fmt.Sprintf("[OK  ] Connected as admin to %s@%s:%s/%s", engine, host, port, dbForEngine(engine)))

	g.setupSchema(engine)
	g.setupUsers(engine, host, port)

	rng := rand.New(rand.NewSource(time.Now().UnixNano()))
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-g.stop:
			g.logLine("=== Generator stopped ===")
			return
		case <-ticker.C:
			g.tick(engine, host, port, rng)
			if rng.Intn(4) == 0 {
				ticker.Reset(time.Duration(800+rng.Intn(2400)) * time.Millisecond)
			}
		}
	}
}

// setupUsers creates lab_admin / lab_writer / lab_reader with appropriate GRANTs
// and opens a connection pool for each.
func (g *rdsGen) setupUsers(engine, host, port string) {
	g.logLine("=== Setting up lab users ===")
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	for _, spec := range labUserSpecs {
		var createSQL, grantSQL, seqGrantSQL string

		switch engine {
		case "postgres":
			// PL/pgSQL anonymous block: create user, ignore duplicate_object (42710)
			createSQL = fmt.Sprintf(
				`DO $$ BEGIN CREATE USER %s WITH PASSWORD '%s'; EXCEPTION WHEN duplicate_object THEN NULL; END $$`,
				spec.name, spec.pass)
			switch spec.role {
			case "admin":
				grantSQL = fmt.Sprintf(`GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO %s`, spec.name)
				// BIGSERIAL columns own a separate sequence — must grant USAGE to INSERT
				seqGrantSQL = fmt.Sprintf(`GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO %s`, spec.name)
			case "writer":
				grantSQL = fmt.Sprintf(`GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA public TO %s`, spec.name)
				seqGrantSQL = fmt.Sprintf(`GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO %s`, spec.name)
			case "reader":
				grantSQL = fmt.Sprintf(`GRANT SELECT ON ALL TABLES IN SCHEMA public TO %s`, spec.name)
			}
		default: // mysql / mariadb
			createSQL = fmt.Sprintf(`CREATE USER IF NOT EXISTS '%s'@'%%' IDENTIFIED BY '%s'`, spec.name, spec.pass)
			switch spec.role {
			case "admin":
				grantSQL = fmt.Sprintf(`GRANT SELECT, INSERT, UPDATE, DELETE ON dsf_lab.* TO '%s'@'%%'`, spec.name)
			case "writer":
				grantSQL = fmt.Sprintf(`GRANT SELECT, INSERT, UPDATE ON dsf_lab.* TO '%s'@'%%'`, spec.name)
			case "reader":
				grantSQL = fmt.Sprintf(`GRANT SELECT ON dsf_lab.* TO '%s'@'%%'`, spec.name)
			}
		}

		if _, err := g.adminDB.ExecContext(ctx, createSQL); err != nil {
			g.logLine(fmt.Sprintf("[WARN] create user %s: %s", spec.name, firstLine(err.Error())))
			continue
		}
		if _, err := g.adminDB.ExecContext(ctx, grantSQL); err != nil {
			g.logLine(fmt.Sprintf("[WARN] grant for %s: %s", spec.name, firstLine(err.Error())))
		} else {
			g.mu.Lock()
			g.stats.Grants++
			g.mu.Unlock()
			g.logLine(fmt.Sprintf("[PRIV] GRANT %-7s → %s", spec.role, spec.name))
		}
		// Grant sequence access for roles that need INSERT (postgres only)
		if seqGrantSQL != "" {
			if _, err := g.adminDB.ExecContext(ctx, seqGrantSQL); err != nil {
				g.logLine(fmt.Sprintf("[WARN] seq grant for %s: %s", spec.name, firstLine(err.Error())))
			}
		}

		userDB, err := openDB(engine, host, port, spec.name, spec.pass, dbForEngine(engine))
		if err != nil {
			g.logLine(fmt.Sprintf("[WARN] connect as %s: %s", spec.name, firstLine(err.Error())))
			continue
		}
		g.users = append(g.users, labUser{name: spec.name, db: userDB})
		g.logLine(fmt.Sprintf("[OK  ] Connected as %s (%s)", spec.name, spec.role))
	}

	if len(g.users) == 0 {
		g.logLine("[WARN] no lab users connected — falling back to admin-only mode")
		g.users = []labUser{{name: "admin", db: g.adminDB}}
	}
	g.logLine(fmt.Sprintf("=== %d lab users ready (admin + writer + reader) ===", len(g.users)))
}

// ── tick ──────────────────────────────────────────────────────────────────────

func (g *rdsGen) tick(engine, host, port string, rng *rand.Rand) {
	ts := time.Now().Format("15:04:05")

	// Periodic GRANT/REVOKE cycle — every 20 ticks
	g.mu.Lock()
	total := g.stats.Total
	g.mu.Unlock()
	if total > 0 && total%20 == 0 {
		g.grantRevokeCycle(engine, rng)
	}

	user := g.pickUser(rng)

	var label, detail string
	var isErr bool

	switch user.name {
	case "lab_reader":
		// Reader: alternates between legit SELECT and forbidden write attempts
		if rng.Intn(2) == 0 {
			label, detail, isErr = g.readerSelectOp(user)
		} else {
			label, detail, isErr = g.permDeniedOp(engine, user, rng)
		}
	default:
		if rng.Intn(10) < 8 {
			label, detail, isErr = g.normalOp(engine, user, rng)
		} else {
			label, detail, isErr = g.errorOp(engine, host, port, rng)
		}
	}

	g.mu.Lock()
	s := &g.stats
	s.Total++
	if isErr {
		s.Errors++
	} else {
		s.Success++
		switch label {
		case "INSERT":
			s.Inserts++
		case "SELECT":
			s.Selects++
		case "UPDATE":
			s.Updates++
		case "DELETE":
			s.Deletes++
		}
	}
	total = s.Total
	g.mu.Unlock()

	tag := "[OK ] "
	if isErr {
		tag = "[ERR] "
	}
	g.logLine(fmt.Sprintf("%s %s[%-10s] %-6s %s", ts, tag, user.name, label, detail))

	if total%10 == 0 {
		g.mu.Lock()
		s2 := g.stats
		s2.Batch++
		g.stats.Batch = s2.Batch
		g.mu.Unlock()
		g.logLine(fmt.Sprintf(
			"─── Batch %d ─ total:%d ok:%d err:%d ins:%d sel:%d upd:%d del:%d perm_denied:%d grants:%d revokes:%d login_fail:%d sql_err:%d",
			s2.Batch, s2.Total, s2.Success, s2.Errors,
			s2.Inserts, s2.Selects, s2.Updates, s2.Deletes,
			s2.PermDenied, s2.Grants, s2.Revokes,
			s2.LoginFails, s2.SQLErrors))
	}
}

// pickUser returns a user weighted 35% admin / 35% writer / 30% reader.
func (g *rdsGen) pickUser(rng *rand.Rand) labUser {
	if len(g.users) == 0 {
		return labUser{name: "admin", db: g.adminDB}
	}
	var admin, writer, reader *labUser
	for i := range g.users {
		switch g.users[i].name {
		case "lab_admin":
			admin = &g.users[i]
		case "lab_writer":
			writer = &g.users[i]
		case "lab_reader":
			reader = &g.users[i]
		}
	}
	r := rng.Intn(100)
	switch {
	case r < 35 && admin != nil:
		return *admin
	case r < 70 && writer != nil:
		return *writer
	case reader != nil:
		return *reader
	default:
		return g.users[rng.Intn(len(g.users))]
	}
}

// grantRevokeCycle REVOKEs then re-GRANTs a privilege on lab_writer to produce audit events.
func (g *rdsGen) grantRevokeCycle(engine string, rng *rand.Rand) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()

	var op string
	if rng.Intn(2) == 0 {
		op = "UPDATE"
	} else {
		op = "DELETE"
	}

	var revokeSQL, regrantSQL string
	switch engine {
	case "postgres":
		revokeSQL = fmt.Sprintf(`REVOKE %s ON ALL TABLES IN SCHEMA public FROM lab_writer`, op)
		regrantSQL = fmt.Sprintf(`GRANT %s ON ALL TABLES IN SCHEMA public TO lab_writer`, op)
	default:
		revokeSQL = fmt.Sprintf(`REVOKE %s ON dsf_lab.* FROM 'lab_writer'@'%%'`, op)
		regrantSQL = fmt.Sprintf(`GRANT %s ON dsf_lab.* TO 'lab_writer'@'%%'`, op)
	}

	if _, err := g.adminDB.ExecContext(ctx, revokeSQL); err != nil {
		g.logLine(fmt.Sprintf("[WARN] REVOKE: %s", firstLine(err.Error())))
		return
	}
	g.mu.Lock()
	g.stats.Revokes++
	g.mu.Unlock()
	g.logLine(fmt.Sprintf("[PRIV] REVOKE  %-6s ON lab_orders FROM lab_writer", op))

	if _, err := g.adminDB.ExecContext(ctx, regrantSQL); err != nil {
		g.logLine(fmt.Sprintf("[WARN] re-GRANT: %s", firstLine(err.Error())))
		return
	}
	g.mu.Lock()
	g.stats.Grants++
	g.mu.Unlock()
	g.logLine(fmt.Sprintf("[PRIV] GRANT   %-6s ON lab_orders TO   lab_writer (restored)", op))
}

// ── per-user operations ───────────────────────────────────────────────────────

// readerSelectOp runs a plain SELECT as the read-only lab_reader user.
func (g *rdsGen) readerSelectOp(user labUser) (label, detail string, isErr bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	rows, err := user.db.QueryContext(ctx, `SELECT id, username, dept, salary FROM lab_users ORDER BY id DESC LIMIT 5`)
	if err != nil {
		return "SELECT", "lab_users — " + firstLine(err.Error()), true
	}
	count := 0
	for rows.Next() {
		count++
	}
	rows.Close()
	return "SELECT", fmt.Sprintf("lab_users LIMIT 5 (%d rows)", count), false
}

// permDeniedOp has lab_reader attempt a forbidden write — expected to fail.
func (g *rdsGen) permDeniedOp(engine string, user labUser, rng *rand.Rand) (label, detail string, isErr bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()

	ph := func(n int) string {
		if engine == "postgres" {
			return fmt.Sprintf("$%d", n)
		}
		return "?"
	}

	n := rng.Intn(500)
	var err error

	switch rng.Intn(3) {
	case 0: // INSERT denied
		q := fmt.Sprintf(`INSERT INTO lab_users (username, email, dept, salary) VALUES (%s, %s, %s, %s)`,
			ph(1), ph(2), ph(3), ph(4))
		_, err = user.db.ExecContext(ctx, q,
			fmt.Sprintf("user_%d", n), fmt.Sprintf("user_%d@corp.internal", n), "Marketing", 50000)
		if err != nil {
			g.mu.Lock()
			g.stats.PermDenied++
			g.mu.Unlock()
			return "INSERT", fmt.Sprintf("lab_users [PERM DENIED] %s", firstLine(err.Error())), true
		}
		return "INSERT", fmt.Sprintf("lab_users user_%d (unexpected success)", n), true

	case 1: // UPDATE denied
		q := fmt.Sprintf(`UPDATE lab_orders SET status = %s WHERE id = %s`, ph(1), ph(2))
		_, err = user.db.ExecContext(ctx, q, "completed", n%50+1)
		if err != nil {
			g.mu.Lock()
			g.stats.PermDenied++
			g.mu.Unlock()
			return "UPDATE", fmt.Sprintf("lab_orders id=%d [PERM DENIED] %s", n%50+1, firstLine(err.Error())), true
		}
		return "UPDATE", fmt.Sprintf("lab_orders id=%d (unexpected success)", n%50+1), true

	default: // DELETE denied
		var q string
		if engine == "postgres" {
			q = `DELETE FROM lab_orders WHERE status = 'failed' AND id IN (SELECT id FROM lab_orders WHERE status = 'failed' ORDER BY created_at LIMIT 1)`
		} else {
			q = `DELETE FROM lab_orders WHERE status = 'failed' ORDER BY created_at LIMIT 1`
		}
		_, err = user.db.ExecContext(ctx, q)
		if err != nil {
			g.mu.Lock()
			g.stats.PermDenied++
			g.mu.Unlock()
			return "DELETE", fmt.Sprintf("lab_orders [PERM DENIED] %s", firstLine(err.Error())), true
		}
		return "DELETE", "lab_orders (unexpected success)", true
	}
}

func (g *rdsGen) normalOp(engine string, user labUser, rng *rand.Rand) (label, detail string, isErr bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	n := rng.Intn(500)

	ph := func(n int) string {
		if engine == "postgres" {
			return fmt.Sprintf("$%d", n)
		}
		return "?"
	}

	// lab_writer has no DELETE privilege — cap choice to avoid that branch
	maxChoice := 10
	if user.name == "lab_writer" {
		maxChoice = 9
	}
	choice := rng.Intn(maxChoice)

	switch {
	case choice < 4: // INSERT user
		dept := depts[rng.Intn(len(depts))]
		salary := 30000 + rng.Intn(90000)
		q := fmt.Sprintf(`INSERT INTO lab_users (username, email, dept, salary) VALUES (%s, %s, %s, %s)`,
			ph(1), ph(2), ph(3), ph(4))
		_, err := user.db.ExecContext(ctx, q,
			fmt.Sprintf("user_%d", n),
			fmt.Sprintf("user_%d@corp.internal", n),
			dept, salary)
		if err != nil && isUniqueViolation(err) {
			return "INSERT", fmt.Sprintf("lab_users user_%d (duplicate, skipped)", n), false
		}
		if err != nil {
			return "INSERT", "lab_users — " + firstLine(err.Error()), true
		}
		return "INSERT", fmt.Sprintf("lab_users user_%d dept=%s salary=%d", n, dept, salary), false

	case choice < 6: // SELECT
		rows, err := user.db.QueryContext(ctx, `SELECT id, username, dept, salary FROM lab_users ORDER BY id DESC LIMIT 5`)
		if err != nil {
			return "SELECT", "lab_users — " + firstLine(err.Error()), true
		}
		count := 0
		for rows.Next() {
			count++
		}
		rows.Close()
		return "SELECT", fmt.Sprintf("lab_users LIMIT 5 (%d rows)", count), false

	case choice < 8: // INSERT order
		prod := products[rng.Intn(len(products))]
		amount := float64(rng.Intn(9900)+100) / 100.0
		q := fmt.Sprintf(`INSERT INTO lab_orders (user_id, product, amount, status) VALUES (%s, %s, %s, 'pending')`,
			ph(1), ph(2), ph(3))
		_, err := user.db.ExecContext(ctx, q, n%100+1, prod, amount)
		if err != nil {
			return "INSERT", "lab_orders — " + firstLine(err.Error()), true
		}
		return "INSERT", fmt.Sprintf("lab_orders product=%q amount=%.2f", prod, amount), false

	case choice < 9: // UPDATE
		newStatus := statuses[rng.Intn(len(statuses))]
		q := fmt.Sprintf(`UPDATE lab_orders SET status = %s WHERE id = %s`, ph(1), ph(2))
		res, err := user.db.ExecContext(ctx, q, newStatus, n%50+1)
		if err != nil {
			return "UPDATE", "lab_orders — " + firstLine(err.Error()), true
		}
		affected, _ := res.RowsAffected()
		return "UPDATE", fmt.Sprintf("lab_orders id=%d status=%s (%d row)", n%50+1, newStatus, affected), false

	default: // DELETE — lab_admin only
		var err error
		if engine == "postgres" {
			_, err = user.db.ExecContext(ctx,
				`DELETE FROM lab_orders WHERE status = 'failed' AND id IN (SELECT id FROM lab_orders WHERE status = 'failed' ORDER BY created_at LIMIT 2)`)
		} else {
			_, err = user.db.ExecContext(ctx,
				`DELETE FROM lab_orders WHERE status = 'failed' ORDER BY created_at LIMIT 2`)
		}
		if err != nil {
			return "DELETE", "lab_orders — " + firstLine(err.Error()), true
		}
		return "DELETE", "lab_orders WHERE status=failed LIMIT 2", false
	}
}

func (g *rdsGen) errorOp(engine, host, port string, rng *rand.Rand) (label, detail string, isErr bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()

	switch rng.Intn(3) {
	case 0: // failed login with bad credentials
		g.mu.Lock()
		g.stats.LoginFails++
		g.mu.Unlock()
		badUser := fmt.Sprintf("attacker_%d", rng.Intn(50))
		db, err := openDB(engine, host, port, badUser, "h4ck3d!", dbForEngine(engine))
		if err != nil {
			return "LOGIN", fmt.Sprintf("user=%s — %s", badUser, firstLine(err.Error())), true
		}
		db.Close()
		return "LOGIN", fmt.Sprintf("user=%s — unexpectedly succeeded", badUser), true

	case 1: // wrong table reference
		g.mu.Lock()
		g.stats.SQLErrors++
		g.mu.Unlock()
		_, err := g.adminDB.ExecContext(ctx, `SELECT * FROM nonexistent_table_xyz_lab`)
		msg := "no error (unexpected)"
		if err != nil {
			msg = firstLine(err.Error())
		}
		return "SQL  ", "SELECT nonexistent_table — " + msg, true

	default: // bad column
		g.mu.Lock()
		g.stats.SQLErrors++
		g.mu.Unlock()
		_, err := g.adminDB.ExecContext(ctx, `INSERT INTO lab_users (bad_col_xyz) VALUES ('test')`)
		msg := "no error (unexpected)"
		if err != nil {
			msg = firstLine(err.Error())
		}
		return "SQL  ", "INSERT bad_column — " + msg, true
	}
}

func (g *rdsGen) setupSchema(engine string) {
	g.logLine("=== Setting up schema ===")
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	var stmts []string
	switch engine {
	case "postgres":
		stmts = []string{
			`CREATE TABLE IF NOT EXISTS lab_users (
				id BIGSERIAL PRIMARY KEY,
				username VARCHAR(60) UNIQUE,
				email VARCHAR(100),
				dept VARCHAR(40),
				salary NUMERIC(10,2),
				active BOOLEAN DEFAULT true,
				created_at TIMESTAMPTZ DEFAULT now()
			)`,
			`CREATE TABLE IF NOT EXISTS lab_orders (
				id BIGSERIAL PRIMARY KEY,
				user_id BIGINT,
				product VARCHAR(100),
				amount NUMERIC(10,2),
				status VARCHAR(20) DEFAULT 'pending',
				created_at TIMESTAMPTZ DEFAULT now()
			)`,
		}
	default: // mysql / mariadb
		stmts = []string{
			`CREATE TABLE IF NOT EXISTS lab_users (
				id BIGINT AUTO_INCREMENT PRIMARY KEY,
				username VARCHAR(60) UNIQUE,
				email VARCHAR(100),
				dept VARCHAR(40),
				salary DECIMAL(10,2),
				active TINYINT(1) DEFAULT 1,
				created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
			)`,
			`CREATE TABLE IF NOT EXISTS lab_orders (
				id BIGINT AUTO_INCREMENT PRIMARY KEY,
				user_id BIGINT,
				product VARCHAR(100),
				amount DECIMAL(10,2),
				status VARCHAR(20) DEFAULT 'pending',
				created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
			)`,
		}
	}

	for _, stmt := range stmts {
		if _, err := g.adminDB.ExecContext(ctx, stmt); err != nil {
			g.logLine("[WARN] schema: " + firstLine(err.Error()))
		}
	}
	g.logLine("=== Schema ready ===")
}

// ── DB connection ─────────────────────────────────────────────────────────────

// ensureMySQLDatabase makes sure the dsf_lab database exists and the admin
// user has full access to it.  Three-step fallback chain:
//  1. Connect directly to dsf_lab — succeeds if it already exists.
//  2. Connect to the server root and CREATE DATABASE — succeeds if admin has
//     global CREATE privilege (i.e. after the setup script's STEP 1b ran).
//  3. docker exec root fallback — mirrors STEP 1b of the RDS setup script;
//     uses the same root / master-pass trick to grant ALL PRIVILEGES and
//     create the database when the container is accessible.
func (g *rdsGen) ensureMySQLDatabase(engine, host, port string) error {
	// Step 1: database already exists?
	if db, err := openDB(engine, host, port, "admin", "secret123", "dsf_lab"); err == nil {
		db.Close()
		return nil
	}

	// Step 2: try CREATE DATABASE via admin connection (works if STEP 1b already ran)
	if db, err := openDB(engine, host, port, "admin", "secret123", ""); err == nil {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		createErr := func() error {
			defer cancel()
			_, e := db.ExecContext(ctx, "CREATE DATABASE IF NOT EXISTS dsf_lab")
			return e
		}()
		db.Close()
		if createErr == nil {
			return nil
		}
		g.logLine("[INFO]  CREATE DATABASE denied — applying docker exec root fallback (floci emulation)...")
	}

	// Step 3: docker exec root fallback — same as STEP 1b in the RDS setup script.
	// MariaDB 10.4+ renamed the client binary from "mysql" to "mariadb".
	container := "floci-rds-" + g.instanceID
	sqlStmt := "CREATE DATABASE IF NOT EXISTS dsf_lab; " +
		"GRANT ALL PRIVILEGES ON *.* TO 'admin'@'%' WITH GRANT OPTION; " +
		"FLUSH PRIVILEGES;"
	clientBin := mysqlClientBin(engine)
	out, err := exec.Command("docker", "exec", container,
		clientBin, "-u", "root", "-psecret123", "-e", sqlStmt).CombinedOutput()
	if err != nil {
		return fmt.Errorf("docker exec root fallback failed (%w): %s", err, strings.TrimSpace(string(out)))
	}
	g.logLine("[INFO]  docker exec: dsf_lab created and admin granted ALL PRIVILEGES")
	return nil
}

// mysqlClientBin returns the CLI client binary name for the given engine.
// MariaDB 10.4+ ships "mariadb" (the mysql alias was dropped); MySQL still uses "mysql".
func mysqlClientBin(engine string) string {
	if strings.ToLower(engine) == "mariadb" {
		return "mariadb"
	}
	return "mysql"
}

func openDB(engine, host, port, user, pass, dbName string) (*sql.DB, error) {
	var driverName, dsn string
	switch engine {
	case "postgres":
		driverName = "postgres"
		if dbName == "" {
			dbName = "postgres"
		}
		dsn = fmt.Sprintf(
			"host=%s port=%s user=%s password=%s dbname=%s sslmode=disable connect_timeout=5",
			host, port, user, pass, dbName)
	case "mysql", "mariadb":
		driverName = "mysql"
		dsn = fmt.Sprintf("%s:%s@tcp(%s:%s)/%s?timeout=5s&readTimeout=10s&writeTimeout=10s&parseTime=true",
			user, pass, host, port, dbName)
	default:
		return nil, fmt.Errorf("unsupported engine: %s", engine)
	}

	db, err := sql.Open(driverName, dsn)
	if err != nil {
		return nil, err
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := db.PingContext(ctx); err != nil {
		db.Close()
		return nil, err
	}

	db.SetMaxOpenConns(3)
	db.SetMaxIdleConns(2)
	db.SetConnMaxLifetime(5 * time.Minute)
	return db, nil
}

// ── helpers ───────────────────────────────────────────────────────────────────

func dbForEngine(engine string) string {
	if engine == "postgres" {
		return "postgres"
	}
	return "dsf_lab"
}

func isUniqueViolation(err error) bool {
	if err == nil {
		return false
	}
	s := err.Error()
	return strings.Contains(s, "duplicate key") ||
		strings.Contains(s, "Duplicate entry") ||
		strings.Contains(s, "UNIQUE constraint failed")
}

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	if len(s) > 120 {
		s = s[:117] + "..."
	}
	return s
}

func (g *rdsGen) logLine(line string) {
	g.mu.Lock()
	g.lines = append(g.lines, line)
	if len(g.lines) > 200 {
		g.lines = g.lines[len(g.lines)-200:]
	}
	g.mu.Unlock()
	if g.logFile != nil {
		fmt.Fprintln(g.logFile, line)
	}
}
