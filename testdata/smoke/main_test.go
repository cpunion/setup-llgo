package main

import "testing"

func TestSum(t *testing.T) {
	if got := sum(19, 23); got != 42 {
		t.Fatalf("sum = %d, want 42", got)
	}
}
