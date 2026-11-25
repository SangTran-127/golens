//go:build !premium

package lib

import "example.test/shared"

func Price(base int) int { return shared.Round(base) }
