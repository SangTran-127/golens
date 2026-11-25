package main

import (
	"context"
	"errors"
	"strings"
)

var ErrEmptyPayload = errors.New("empty payload")

func Upper(ctx context.Context, job Job) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if job.Payload == "" {
		return "", ErrEmptyPayload
	}
	return strings.ToUpper(job.Payload), nil
}
