// Package a uses a workspace-vendored dependency.
package a

import "example.com/wvdep"

// Call greets via workspace vendor.
func Call() string { return wvdep.Hello() }
