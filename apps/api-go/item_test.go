package main

import (
	"encoding/json"
	"strings"
	"testing"
)

// 與 .NET、PHP、Python 版相同的案例，確保各版的驗證規則一致。

func parse(t *testing.T, text string) (ItemInput, string) {
	t.Helper()
	var body any
	if err := json.Unmarshal([]byte(text), &body); err != nil {
		t.Fatalf("invalid test JSON %q: %v", text, err)
	}
	return parseItemInput(body)
}

func TestParseItemInput_名稱會去除前後空白且done預設為false(t *testing.T) {
	in, msg := parse(t, `{"name":"  買牛奶  "}`)
	if msg != "" || in != (ItemInput{"買牛奶", false}) {
		t.Fatalf("got %+v %q", in, msg)
	}
}

func TestParseItemInput_全形空白與BOM也會去除(t *testing.T) {
	bom := string(rune(0xFEFF))
	body := map[string]any{"name": "　" + bom + "買牛奶" + bom + "　"}
	if in, _ := parseItemInput(body); in.Name != "買牛奶" {
		t.Fatalf("got %q", in.Name)
	}
}

func TestParseItemInput_done(t *testing.T) {
	if in, _ := parse(t, `{"name":"x","done":true}`); !in.Done {
		t.Fatal("done should be true")
	}
	if in, msg := parse(t, `{"name":"x","done":null}`); msg != "" || in.Done {
		t.Fatalf("null done: %+v %q", in, msg)
	}
}

func TestParseItemInput_缺少名稱(t *testing.T) {
	for _, text := range []string{`{}`, `{"name":""}`, `{"name":"   "}`, `{"name":123}`, `{"name":null}`, `[]`, `["x"]`, `null`, `"x"`} {
		if _, msg := parse(t, text); msg != "name is required" {
			t.Errorf("%s: got %q", text, msg)
		}
	}
}

func TestParseItemInput_名稱最多200字且以UTF16計算(t *testing.T) {
	cases := []struct {
		name string
		ok   bool
	}{
		{strings.Repeat("a", 200), true},
		{strings.Repeat("中", 200), true},
		{strings.Repeat("a", 201), false},
		{strings.Repeat("😀", 100), true}, // emoji 在 UTF-16 佔 2 個單位
		{strings.Repeat("😀", 101), false},
	}
	for _, c := range cases {
		_, msg := parseItemInput(map[string]any{"name": c.name})
		if c.ok != (msg == "") || (!c.ok && msg != "name must be at most 200 characters") {
			t.Errorf("len(runes)=%d: got %q", len([]rune(c.name)), msg)
		}
	}
}

func TestParseItemInput_done必須是布林(t *testing.T) {
	for _, done := range []string{`"yes"`, `1`, `0`, `{}`, `[]`} {
		if _, msg := parse(t, `{"name":"x","done":`+done+`}`); msg != "done must be a boolean" {
			t.Errorf("%s: got %q", done, msg)
		}
	}
}

func TestParseID(t *testing.T) {
	valid := map[string]int{"1": 1, "42": 42, "007": 7, "2147483647": 2147483647}
	for raw, want := range valid {
		if got, ok := parseID(raw); !ok || got != want {
			t.Errorf("%q: got %d %v", raw, got, ok)
		}
	}
	for _, raw := range []string{"0", "000", "-1", "abc", "1.5", " 1", "1e2", "１", "2147483648", strings.Repeat("9", 5000), ""} {
		if got, ok := parseID(raw); ok {
			t.Errorf("%q: should be invalid, got %d", raw, got)
		}
	}
}
