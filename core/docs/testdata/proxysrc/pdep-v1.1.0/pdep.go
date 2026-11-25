// Package pdep is served from a file proxy at version v1.1.0.
package pdep

// Version returns the module version.
func Version() string { return "v1.1.0" }

// OnlyInV11 exists only in v1.1.0.
func OnlyInV11() bool { return true }
