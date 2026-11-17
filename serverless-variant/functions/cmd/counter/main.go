// Command counter is the Lambda function that counts video views from the SQS view queue.
//
// It reads TABLE_NAME (the views table) and DEDUPE_TTL_SECONDS (how long a dedupe item lives) from the environment.
package main

import (
	"context"
	"log/slog"
	"os"
	"strconv"
	"time"

	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"

	"github.com/anhnvcoder/svp-labs/serverless-variant/functions/counter"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	table := os.Getenv("TABLE_NAME")
	ttl, err := strconv.Atoi(os.Getenv("DEDUPE_TTL_SECONDS"))
	if table == "" || err != nil || ttl <= 0 {
		log.Error("TABLE_NAME must be set and DEDUPE_TTL_SECONDS must be a positive number of seconds")
		os.Exit(1)
	}
	cfg, err := config.LoadDefaultConfig(context.Background())
	if err != nil {
		log.Error("load AWS config", "error", err)
		os.Exit(1)
	}
	h := &counter.Handler{
		DB:        dynamodb.NewFromConfig(cfg),
		Table:     table,
		DedupeTTL: time.Duration(ttl) * time.Second,
		Now:       time.Now,
		Metrics:   os.Stdout,
		Log:       log,
	}
	lambda.Start(h.Handle)
}
