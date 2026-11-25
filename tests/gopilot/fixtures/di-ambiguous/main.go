package main

import (
	"fmt"
	"os"
)

func main() {
	n, err := build(LoadConfig())
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	NewAlerts(n).Raise("disk almost full")
}

func build(cfg Config) (Notifier, error) {
	switch cfg.Channel {
	case "email":
		return EmailNotifier{To: cfg.Target}, nil
	case "sms":
		return SMSNotifier{Number: cfg.Target}, nil
	default:
		return nil, fmt.Errorf("unsupported channel %q", cfg.Channel)
	}
}
