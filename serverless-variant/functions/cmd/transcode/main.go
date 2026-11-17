// Command transcode is the Lambda function behind the transcode task of the upload state machine.
package main

import (
	"github.com/aws/aws-lambda-go/lambda"

	"github.com/anhnvcoder/svp-labs/serverless-variant/functions/transcode"
)

func main() {
	lambda.Start(transcode.Handle)
}
