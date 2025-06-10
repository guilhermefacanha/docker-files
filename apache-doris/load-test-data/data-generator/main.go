package main

import (
	"flag" // Import flag for command-line arguments
	"fmt"
	"log"
	"math/rand"
	"path/filepath"
	"time"

	"github.com/xitongsys/parquet-go-source/local" // Import for local file writer
	"github.com/xitongsys/parquet-go/parquet"
	"github.com/xitongsys/parquet-go/writer"
)

// Record defines the schema for our Parquet file.
// Struct tags are used to map Go fields to Parquet column names and types.
type Record struct {
	ID          int64   `parquet:"name=id, type=INT64"`
	BoolCol     bool    `parquet:"name=bool_col, type=BOOLEAN"`
	TinyintCol  int32   `parquet:"name=tinyint_col, type=INT32, convertedtype=INT_8"`   // INT_8 for logical tinyint
	SmallintCol int32   `parquet:"name=smallint_col, type=INT32, convertedtype=INT_16"` // INT_16 for logical smallint
	IntCol      int32   `parquet:"name=int_col, type=INT32"`
	BigintCol   int64   `parquet:"name=bigint_col, type=INT64"`
	FloatCol    float32 `parquet:"name=float_col, type=FLOAT"`
	DoubleCol   float64 `parquet:"name=double_col, type=DOUBLE"`
	// For strings, use BYTE_ARRAY as primitive type and UTF8 as converted type.
	// Add encoding=PLAIN_DICTIONARY for better compression on repetitive strings.
	DateStringCol string `parquet:"name=date_string_col, type=BYTE_ARRAY, convertedtype=UTF8, encoding=PLAIN_DICTIONARY"`
	StringCol     string `parquet:"name=string_col, type=BYTE_ARRAY, convertedtype=UTF8, encoding=PLAIN_DICTIONARY"`
	// For time.Time, map to INT64 primitive type with TIMESTAMP_MILLIS converted type.
	// We will store Unix milliseconds (int64) directly in this field.
	TimestampCol int64 `parquet:"name=timestamp_col, type=INT64, convertedtype=TIMESTAMP_MILLIS"`
}

// generateRandomWord creates a random string of a given length, mimicking Faker's word generation.
func generateRandomWord(r *rand.Rand, length int) string {
	const charset = "abcdefghijklmnopqrstuvwxyz" + "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
	b := make([]byte, length)
	for i := range b {
		b[i] = charset[r.Intn(len(charset))] // Use the passed random source
	}
	return string(b)
}

func main() {
	// Record the start time
	startTime := time.Now()

	// --- Command-line flags configuration ---
	// Define command-line flags for number of records and output file name.
	numRecordsPtr := flag.Int("n", 1_000_000, "Number of records to generate")
	outputFilePtr := flag.String("o", "one_million_records.parquet", "Output Parquet file name")
	flag.Parse() // Parse the command-line arguments

	// Dereference the pointers to get the actual values
	numRecords := *numRecordsPtr
	outputFile := *outputFilePtr

	// Validate the number of records provided.
	if numRecords <= 0 {
		fmt.Println("Error: Number of records (-n) must be a positive integer.")
		fmt.Println("Usage: go run main.go -n <number_of_records> [-o <output_file_name.parquet>]")
		return // Exit if invalid input
	}

	// Ensure the output file has a .parquet extension if not provided.
	if filepath.Ext(outputFile) != ".parquet" && filepath.Ext(outputFile) != ".PARQUET" {
		outputFile += ".parquet"
	}
	// --- End of command-line flags configuration ---

	log.Printf("Starting to generate %d records into %s", numRecords, outputFile)

	// Create the output file using local.NewLocalFileWriter
	// This correctly implements the source.ParquetFile interface required by parquet-go
	fw, err := local.NewLocalFileWriter(outputFile)
	if err != nil {
		log.Fatalf("Failed to create file writer: %v", err)
	}
	defer fw.Close() // Ensure the file is closed when main exits

	// Create a new Parquet writer
	// We pass a new instance of the Record struct to define the schema
	// The last argument is the number of rows expected, helps with optimization.
	pw, err := writer.NewParquetWriter(fw, new(Record), int64(numRecords))
	if err != nil {
		log.Fatalf("Failed to create parquet writer: %v", err)
	}

	// Set compression type. SNAPPY is a good default.
	pw.RowGroupSize = 256 * 1024 * 1024 // 128MB row group size
	pw.CompressionType = parquet.CompressionCodec_SNAPPY
	pw.EnableDictionary = true
	// pw.PageSize = 1 * 1024 * 1024 // You can also set PageSize if needed

	// Seed the random number generator using the current time for different results each run.
	r := rand.New(rand.NewSource(time.Now().UnixNano()))
	baseDate := time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC)

	// Loop to generate and write records
	for i := 0; i < numRecords; i++ {
		rec := Record{
			ID:          int64(i),
			BoolCol:     r.Intn(2) == 0,
			TinyintCol:  int32(r.Intn(256) - 128),     // Range for tinyint
			SmallintCol: int32(r.Intn(65536) - 32768), // Range for smallint
			IntCol:      r.Int31(),
			BigintCol:   r.Int63(),
			FloatCol:    r.Float32() * 100,
			DoubleCol:   r.Float64() * 1000,
			// Generate random date string: Random date within 3 years from baseDate
			DateStringCol: baseDate.AddDate(0, 0, r.Intn(365*3)).Format("01/02/06"),
			// StringCol with more variation to demonstrate dictionary encoding impact
			StringCol: fmt.Sprintf("go_generated_string_%d", r.Intn(10000)), // Limit unique strings to see encoding effect
			// Generate random timestamp within 3 years from baseDate as Unix milliseconds (int64)
			TimestampCol: baseDate.Add(time.Second * time.Duration(r.Intn(3600*24*365*3))).UnixMilli(),
		}

		if err := pw.Write(rec); err != nil {
			log.Printf("Error writing record %d: %v", i, err)
			// Decide if you want to stop on first error or continue
			// For large files, you might want to continue and log, or fatal based on criticality
		}

		// Optional: Print progress
		if (i+1)%100_000 == 0 {
			log.Printf("Wrote %d/%d records...", i+1, numRecords)
		}
	}

	// IMPORTANT: Close the writer to flush buffers and write metadata (Parquet footer)
	if err := pw.WriteStop(); err != nil {
		log.Fatalf("Parquet writer failed on stop: %v", err)
	}

	// Calculate and print the elapsed time
	elapsedTime := time.Since(startTime)

	log.Printf("Successfully generated %s with %d records.", outputFile, numRecords)
	log.Printf("Time elapsed: %s", elapsedTime)
	log.Printf("\nTo verify the number of records using parquet-tools, run:")
	log.Printf("parquet-tools row-count %s", outputFile)
}
