package main

import "os"

type Config struct {
	Channel string
	Target  string
}

func LoadConfig() Config {
	return Config{Channel: os.Getenv("NOTIFY_CHANNEL"), Target: os.Getenv("NOTIFY_TARGET")}
}
