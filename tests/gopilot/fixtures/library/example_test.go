package slug_test

import (
	"fmt"

	"example.test/slug"
)

func ExampleMake() {
	fmt.Println(slug.Make("Hello, Go World"))
	// Output: hello-go-world
}

func ExampleMakeWithOptions() {
	fmt.Println(slug.MakeWithOptions("Hello, Go World", slug.Options{Separator: '_', MaxLen: 8}))
	// Output: hello_go
}
