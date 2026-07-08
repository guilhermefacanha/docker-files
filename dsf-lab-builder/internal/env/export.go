package env

import (
	"fmt"
	"strings"

	"dsf-lab-builder/internal/docker"
	"github.com/xuri/excelize/v2"
)

// ExportAssetsXLSX builds a DSF Hub import spreadsheet for the given env.
// serverIP replaces "localhost" in all endpoint URLs.
// gatewayName fills every <agentless-gateway-display-name> cell.
func ExportAssetsXLSX(e docker.EnvSummary, serverIP, gatewayName string, cfg *Config) ([]byte, error) {
	if serverIP == "" {
		serverIP = "localhost"
	}
	if gatewayName == "" {
		gatewayName = "<agentless-gateway-display-name>"
	}

	detail, err := GetDetail(e, cfg)
	if err != nil {
		return nil, fmt.Errorf("get detail: %w", err)
	}

	accountID := e.AccountID
	if accountID == "" {
		accountID = "000000000000"
	}
	endpoint := fmt.Sprintf("http://%s:%d", serverIP, e.FlociPort)
	cloudAccountARN := "arn:aws:iam::" + accountID

	f := excelize.NewFile()
	defer f.Close()

	// ── Sheet 1: Cloud Account ────────────────────────────────────────────────
	const sheet1 = "Cloud Account"
	f.SetSheetName("Sheet1", sheet1)

	cloudHeaders := []string{
		"asset_id", "asset_display_name", "Server Type", "Server IP", "Server Host Name",
		"Service Name", "asset_source", "admin_email", "Server Port", "auth_mechanism",
		"location", "region", "access_id", "secret_key", "jsonar_uid_display_name",
		"credentials_endpoint", "service_endpoints.logs", "service_endpoints.rds", "service_endpoints.s3",
	}
	xlsxRow(f, sheet1, 1, toIface(cloudHeaders))
	applyHeaderStyle(f, sheet1, 1, len(cloudHeaders))

	var keyID, secretKey string
	if detail.FAM != nil {
		keyID = detail.FAM.KeyID
		secretKey = detail.FAM.SecretKey
	}
	xlsxRow(f, sheet1, 2, []interface{}{
		cloudAccountARN, e.ID, "AWS",
		cloudAccountARN, serverIP, "",
		"AWS", "dbadmin@company.com",
		fmt.Sprintf("%d", e.FlociPort),
		"key", "us-east-1", "us-east-1",
		keyID, secretKey, gatewayName,
		endpoint, endpoint, endpoint, endpoint,
	})

	autoColWidth(f, sheet1)

	// ── Sheet 2: RDS & Log Groups ─────────────────────────────────────────────
	const sheet2 = "RDS & Log Groups"
	f.NewSheet(sheet2)

	rdsHeaders := []string{
		"asset_id", "parent_asset_id", "asset_display_name", "Server Type",
		"Server IP", "Server Host Name", "arn", "region", "location",
		"Service Name", "Server Port", "admin_email", "auth_mechanism",
		"username", "password", "database_name", "reason", "autocommit",
		"version", "content_type", "jsonar_uid_display_name", "sdm_enabled",
		"service_endpoint", "credentials_endpoint",
	}
	xlsxRow(f, sheet2, 1, toIface(rdsHeaders))
	applyHeaderStyle(f, sheet2, 1, len(rdsHeaders))

	row := 2
	for _, rds := range detail.RDBS {
		rd, err := GetRDSDetail(e, rds.ID, cfg)
		if err != nil {
			continue
		}
		serverType := engineToServerType(rd.Engine)
		rdsARN := fmt.Sprintf("arn:aws:rds:us-east-1:%s:db:%s", accountID, rd.ID)
		rdsEndpoint := fmt.Sprintf("http://%s:%d", serverIP, e.FlociPort)
		rdsPort := fmt.Sprintf("%d", rd.Port)

		// RDS instance asset row
		xlsxRow(f, sheet2, row, []interface{}{
			rdsARN, cloudAccountARN, rd.ID, serverType,
			rdsARN, serverIP, rdsARN,
			"us-east-1", "us-east-1", "",
			rdsPort, "dbadmin@company.com", "none",
			"", "", "", "", "", "",
			serverType, gatewayName, "",
			rdsEndpoint, rdsEndpoint,
		})
		row++

		// CloudWatch Log Group asset row (child of RDS instance)
		logGroup := rd.CloudWatchLogGroup
		if logGroup == "" {
			logGroup = logGroupPath(rd.Engine, rd.ID)
		}
		logGroupARN := fmt.Sprintf("arn:aws:logs:us-east-1:%s:log-group:%s", accountID, logGroup)
		xlsxRow(f, sheet2, row, []interface{}{
			logGroup, rdsARN, rd.ID + "-log-group", "AWS LOG GROUP",
			logGroup, serverIP, logGroupARN,
			"us-east-1", "us-east-1", "",
			fmt.Sprintf("%d", e.FlociPort), "dbadmin@company.com", "default",
			"", "", "", "", "", "",
			serverType, gatewayName, "",
			rdsEndpoint, rdsEndpoint,
		})
		row++
	}

	autoColWidth(f, sheet2)

	buf, err := f.WriteToBuffer()
	if err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// ExportGCPAssetsXLSX builds a DSF Hub import spreadsheet for a GCP env.
// serverIP is the actual hostname/IP of the machine running floci-gcp (used by DSF to connect).
// gatewayName fills the jsonar_uid_display_name cell.
func ExportGCPAssetsXLSX(e docker.EnvSummary, serverIP, gatewayName string) ([]byte, error) {
	if serverIP == "" {
		serverIP = "localhost"
	}
	if gatewayName == "" {
		gatewayName = "<agentless-gateway-display-name>"
	}

	projectID := e.AccountID
	if projectID == "" {
		projectID = fmt.Sprintf("floci-gcp-lab-%d", e.Slot)
	}
	serviceAccount := fmt.Sprintf("dsf-gateway@%s.iam.gserviceaccount.com", projectID)
	// Spec format: <service account email>:<default project ID>
	assetID := fmt.Sprintf("%s:%s", serviceAccount, projectID)

	f := excelize.NewFile()
	defer f.Close()

	const sheet1 = "Sheet1"
	f.SetSheetName("Sheet1", sheet1)

	headers := []string{
		"asset_id", "asset_display_name", "Server Type", "Server IP", "Server Host Name",
		"Service Name", "asset_source", "admin_email", "Server Port",
		"jsonar_uid_display_name",
	}
	xlsxRow(f, sheet1, 1, toIface(headers))
	applyHeaderStyle(f, sheet1, 1, len(headers))

	xlsxRow(f, sheet1, 2, []interface{}{
		assetID, e.ID, "GCP",
		serverIP, serverIP,
		"", "GCP", "admin@example.com",
		e.FlociPort,
		gatewayName,
	})

	autoColWidth(f, sheet1)

	buf, err := f.WriteToBuffer()
	if err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// ExportAZAssetsXLSX builds a DSF Hub import spreadsheet for an Azure env.
// serverIP fills the endpoint used by DSF to reach floci-az; gatewayName fills the gateway cell.
func ExportAZAssetsXLSX(e docker.EnvSummary, serverIP, gatewayName string) ([]byte, error) {
	if serverIP == "" {
		serverIP = "localhost"
	}
	if gatewayName == "" {
		gatewayName = "<agentless-gateway-display-name>"
	}

	const (
		tenantID = "00000000-0000-0000-0000-000000000002"
		appID    = "00000000-0000-0000-0000-000000000003"
		rg       = "dsf-lab-rg"
	)
	subscriptionID := e.AccountID
	// Spec format: directory_id/<id>/subscription_id/<id>/<rg>/application_id/<id>
	assetID := fmt.Sprintf("directory_id/%s/subscription_id/%s/%s/application_id/%s",
		tenantID, subscriptionID, rg, appID)
	flociEndpoint := fmt.Sprintf("http://%s:%d", serverIP, e.FlociPort)

	f := excelize.NewFile()
	defer f.Close()

	const sheet1 = "Sheet1"
	f.SetSheetName("Sheet1", sheet1)

	// Mandatory spec fields first, then auth_mechanism sub-fields for client_secret
	headers := []string{
		"asset_id", "asset_display_name", "Server Type",
		"Server IP", "Server Host Name", "Server Port",
		"asset_source", "admin_email", "Service Name",
		"jsonar_uid_display_name",
		"auth_mechanism",
		"directory_id", "application_id", "subscription_id", "client_secret",
	}
	xlsxRow(f, sheet1, 1, toIface(headers))
	applyHeaderStyle(f, sheet1, 1, len(headers))

	xlsxRow(f, sheet1, 2, []interface{}{
		assetID, e.ID, "AZURE",
		flociEndpoint, flociEndpoint, e.FlociPort,
		"AZURE", "dbadmin@company.com", "",
		gatewayName,
		"client_secret",
		tenantID, appID, subscriptionID, "fake-secret",
	})

	autoColWidth(f, sheet1)

	buf, err := f.WriteToBuffer()
	if err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// ── helpers ───────────────────────────────────────────────────────────────────

func engineToServerType(engine string) string {
	switch strings.ToLower(engine) {
	case "postgres":
		return "AWS RDS POSTGRESQL"
	case "mysql":
		return "AWS RDS MYSQL"
	case "mariadb":
		return "AWS RDS MARIADB"
	default:
		return "AWS RDS " + strings.ToUpper(engine)
	}
}

func logGroupPath(engine, instanceID string) string {
	if strings.ToLower(engine) == "postgres" {
		return "/aws/rds/instance/" + instanceID + "/postgresql"
	}
	return "/aws/rds/instance/" + instanceID + "/audit"
}

func toIface(ss []string) []interface{} {
	out := make([]interface{}, len(ss))
	for i, s := range ss {
		out[i] = s
	}
	return out
}

func xlsxRow(f *excelize.File, sheet string, row int, cells []interface{}) {
	for col, v := range cells {
		cell, _ := excelize.CoordinatesToCellName(col+1, row)
		f.SetCellValue(sheet, cell, v)
	}
}

func applyHeaderStyle(f *excelize.File, sheet string, row, cols int) {
	style, err := f.NewStyle(&excelize.Style{
		Font: &excelize.Font{Bold: true, Color: "FFFFFF"},
		Fill: excelize.Fill{Type: "pattern", Pattern: 1, Color: []string{"1F4E79"}},
		Alignment: &excelize.Alignment{Horizontal: "center", Vertical: "center"},
	})
	if err != nil {
		return
	}
	startCell, _ := excelize.CoordinatesToCellName(1, row)
	endCell, _ := excelize.CoordinatesToCellName(cols, row)
	f.SetCellStyle(sheet, startCell, endCell, style)
	f.SetRowHeight(sheet, row, 18)
}

func autoColWidth(f *excelize.File, sheet string) {
	cols, _ := f.GetCols(sheet)
	for i, col := range cols {
		maxLen := 10
		for _, cell := range col {
			if l := len(cell); l > maxLen {
				maxLen = l
			}
		}
		if maxLen > 60 {
			maxLen = 60
		}
		colName, _ := excelize.ColumnNumberToName(i + 1)
		f.SetColWidth(sheet, colName, colName, float64(maxLen)+2)
	}
}
