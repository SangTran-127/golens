package shapes_test

import (
	"fmt"

	"example.com/single/shapes"
)

func ExampleArea() {
	fmt.Println(shapes.Area(shapes.Square{S: 2}))
	// Output: 4
}

func ExampleBox_Get() {
	fmt.Println(shapes.NewBox("hi").Get())
	// Output: hi
}

func Example() {
	fmt.Println(shapes.MaxSides)
	// Output: 64
}
