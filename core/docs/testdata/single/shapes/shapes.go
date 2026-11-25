// Package shapes provides small geometric helpers used by the documentation spike.
//
// See [Area] and [Box.Get] for the main entry points, and [strings.Cut] for a stdlib link.
package shapes

// Shape is anything with an area.
type Shape interface {
	Area() float64
}

// Square is a square with side S.
type Square struct {
	// S is the side length.
	S float64 // length in units
}

// Area returns the area of the square.
func (s Square) Area() float64 { return s.S * s.S }

// Area returns the area of sh.
func Area(sh Shape) float64 { return sh.Area() }

// Box holds a single value of any type.
type Box[T any] struct {
	v T
}

// NewBox returns a Box holding v.
func NewBox[T any](v T) *Box[T] { return &Box[T]{v: v} }

// Get returns the boxed value.
func (b *Box[T]) Get() T { return b.v }

// Map applies f to every element of in.
func Map[S ~[]E, E, R any](in S, f func(E) R) []R {
	out := make([]R, 0, len(in))
	for _, e := range in {
		out = append(out, f(e))
	}
	return out
}

// Polygon is an alias for Shape.
type Polygon = Shape

// IntBox is a generic alias.
type IntBox = Box[int]

// MaxSides is the largest supported polygon.
const MaxSides = 64

func helper() int { return 1 }
