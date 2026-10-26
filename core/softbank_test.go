package main

import "testing"

func TestUnsoftbank(t *testing.T) {
	in := "Party Hard!! \U0001F3BB\U0001F3B9\U0001F357\U0001F356\U0001F377"
	want := "Party Hard!! 🎸🎷🎺🎻🎹🎤🍗🍖🍻🍷"
	if got := unsoftbank(in); got != want {
		t.Fatalf("got %q want %q", got, want)
	}
	if s := "sem emoji antigo"; unsoftbank(s) != s {
		t.Fatal("changed plain text")
	}
}
