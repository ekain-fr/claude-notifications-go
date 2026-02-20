package notifier

import (
	"os"
	"testing"
)

func TestDetectMultiplexerArgs_NoMux(t *testing.T) {
	// Save and clear both env vars
	oldTmux := os.Getenv("TMUX")
	oldZellij := os.Getenv("ZELLIJ")
	os.Unsetenv("TMUX")
	os.Unsetenv("ZELLIJ")
	t.Cleanup(func() {
		if oldTmux != "" {
			os.Setenv("TMUX", oldTmux)
		}
		if oldZellij != "" {
			os.Setenv("ZELLIJ", oldZellij)
		}
	})

	args, name := detectMultiplexerArgs("Title", "Message", "com.test.app")
	if args != nil {
		t.Errorf("expected nil args when no multiplexer, got %v", args)
	}
	if name != "" {
		t.Errorf("expected empty name when no multiplexer, got %q", name)
	}
}

func TestDetectMultiplexerArgs_TmuxPriority(t *testing.T) {
	// When both TMUX and ZELLIJ are set, tmux should win (first in registry)
	oldTmux := os.Getenv("TMUX")
	oldZellij := os.Getenv("ZELLIJ")
	os.Setenv("TMUX", "/tmp/tmux-test,12345,0")
	os.Setenv("ZELLIJ", "0")
	t.Cleanup(func() {
		if oldTmux != "" {
			os.Setenv("TMUX", oldTmux)
		} else {
			os.Unsetenv("TMUX")
		}
		if oldZellij != "" {
			os.Setenv("ZELLIJ", oldZellij)
		} else {
			os.Unsetenv("ZELLIJ")
		}
	})

	// tmux will be detected but GetTmuxPaneTarget will fail (no real tmux server)
	// so we expect (nil, "tmux") — detected but target capture failed
	args, name := detectMultiplexerArgs("Title", "Message", "com.test.app")
	if args != nil {
		t.Errorf("expected nil args (no real tmux server), got %v", args)
	}
	if name != "tmux" {
		t.Errorf("expected name = %q (tmux wins by priority), got %q", "tmux", name)
	}
}
