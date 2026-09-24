package main

import (
	"regexp"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf16"
)

const maxNameLength = 200

// ItemInput 是 POST / PUT /items 的輸入；驗證規則與另外四版一致。
type ItemInput struct {
	Name string
	Done bool
}

var idPattern = regexp.MustCompile(`^[0-9]+$`)

// parseItemInput 驗證 json.Unmarshal 到 any 之後的 body。
// 成功回傳 input 與空字串；失敗回傳錯誤訊息（對應 400）。
func parseItemInput(body any) (ItemInput, string) {
	obj, _ := body.(map[string]any)
	rawName, _ := obj["name"].(string)
	name := strings.TrimFunc(rawName, isTrimmable)
	if name == "" {
		return ItemInput{}, "name is required"
	}
	// 以 UTF-16 code unit 計算長度，與 Node（String.length）、.NET（string.Length）相同；emoji 算 2
	if len(utf16.Encode([]rune(name))) > maxNameLength {
		return ItemInput{}, "name must be at most " + strconv.Itoa(maxNameLength) + " characters"
	}

	done := false
	if v, ok := obj["done"]; ok && v != nil {
		b, isBool := v.(bool)
		if !isBool {
			return ItemInput{}, "done must be a boolean"
		}
		done = b
	}
	return ItemInput{Name: name, Done: done}, ""
}

// parseID 解析路徑上的 id；不是正整數或超出 int4 範圍（2147483647）時回傳 false（對應 404）。
func parseID(raw string) (int, bool) {
	if !idPattern.MatchString(raw) {
		return 0, false
	}
	digits := strings.TrimLeft(raw, "0")
	if digits == "" || len(digits) > 10 {
		return 0, false
	}
	id, err := strconv.Atoi(digits)
	if err != nil || id > 2147483647 {
		return 0, false
	}
	return id, true
}

// isTrimmable：Unicode 空白（含全形空白）再加上 BOM（U+FEFF），與 JavaScript 的 trim() 相近
func isTrimmable(r rune) bool {
	return unicode.IsSpace(r) || r == '\uFEFF'
}
