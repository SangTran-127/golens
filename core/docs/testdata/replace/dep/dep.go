// Package dep is consumed through a local replace directive.
package dep

// Version reports which copy of dep is in use.
func Version() string { return "local" }
