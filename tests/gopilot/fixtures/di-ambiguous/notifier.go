package main

import "fmt"

type Notifier interface {
	Send(msg string) error
}

type EmailNotifier struct {
	To string
}

func (e EmailNotifier) Send(msg string) error {
	fmt.Printf("email to %s: %s\n", e.To, msg)
	return nil
}

type SMSNotifier struct {
	Number string
}

func (s SMSNotifier) Send(msg string) error {
	fmt.Printf("sms to %s: %s\n", s.Number, msg)
	return nil
}
