package main

type Alerts struct {
	n Notifier
}

func NewAlerts(n Notifier) *Alerts {
	return &Alerts{n: n}
}

func (a *Alerts) Raise(msg string) {
	_ = a.n.Send(msg)
}
