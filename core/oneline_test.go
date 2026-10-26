package main

import "testing"

func TestOneLineMarkdown(t *testing.T) {
	got := oneLine("### Horários\n| Dia | Manhã |\n| --- | --- |\n| Seg | 8h |\n\n- **Retorno**: grátis")
	want := "Horários Dia · Manhã - Retorno: grátis"
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
	if g := oneLine("oi\n  tudo   bem"); g != "oi tudo bem" {
		t.Fatalf("plain: %q", g)
	}
}
