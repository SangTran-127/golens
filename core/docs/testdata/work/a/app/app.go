// Package app uses the util package from the sibling workspace module.
package app

import "example.com/b/util"

// Run calls util.Greet.
func Run() string { return util.Greet("work") }
