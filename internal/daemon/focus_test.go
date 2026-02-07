//go:build linux

package daemon

import (
	"testing"
)

// --- GetFocusMethods tests ---

func TestGetFocusMethods_Order(t *testing.T) {
	methods := GetFocusMethods()

	expectedNames := []string{
		"activate-window-by-title extension",
		"GNOME Shell Eval (by window title)",
		"GNOME Shell Eval (by app)",
		"GNOME Shell FocusApp",
		"wlrctl",
		"kdotool",
		"xdotool",
	}

	if len(methods) != len(expectedNames) {
		t.Fatalf("GetFocusMethods() returned %d methods, want %d", len(methods), len(expectedNames))
	}

	for i, method := range methods {
		if method.Name != expectedNames[i] {
			t.Errorf("GetFocusMethods()[%d].Name = %q, want %q", i, method.Name, expectedNames[i])
		}
		if method.Fn == nil {
			t.Errorf("GetFocusMethods()[%d].Fn is nil", i)
		}
	}
}

func TestGetFocusMethods_NotEmpty(t *testing.T) {
	methods := GetFocusMethods()
	if len(methods) == 0 {
		t.Fatal("GetFocusMethods() returned empty slice")
	}
}

func TestGetFocusMethods_AllHaveFunctions(t *testing.T) {
	for _, m := range GetFocusMethods() {
		if m.Name == "" {
			t.Error("FocusMethod has empty Name")
		}
		if m.Fn == nil {
			t.Errorf("FocusMethod %q has nil Fn", m.Name)
		}
	}
}
