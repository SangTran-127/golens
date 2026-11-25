package main

import (
	"fmt"

	"example.test/lib"
	"example.test/shared"
)

func main() {
	fmt.Println(lib.Price(103), shared.Version())
}
