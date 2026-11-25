package lib

import "testing"

func TestPriceIsRounded(t *testing.T) {
	if got := Price(101); got%5 != 0 {
		t.Fatalf("got %d", got)
	}
}
