package notifier

import (
	"github.com/777genius/claude-notifications/internal/logging"
)

// multiplexerHandler describes a terminal multiplexer integration.
type multiplexerHandler struct {
	name      string
	detect    func() bool
	buildArgs func(title, message, bundleID string) ([]string, error)
}

// multiplexerHandlers is the ordered list of supported multiplexers.
// First detected wins.
var multiplexerHandlers = []multiplexerHandler{
	{"tmux", IsTmux, buildTmuxClickArgs},
	{"zellij", IsZellij, buildZellijClickArgs},
	{"wezterm", IsWezTerm, buildWezTermClickArgs},
	{"kitty", IsKitty, buildKittyClickArgs},
}

// detectMultiplexerArgs tries each registered multiplexer.
// Returns (args, name) if detected and target obtained,
// (nil, name) if detected but target failed,
// (nil, "") if no multiplexer detected.
func detectMultiplexerArgs(title, message, bundleID string) ([]string, string) {
	for _, mux := range multiplexerHandlers {
		if !mux.detect() {
			continue
		}
		args, err := mux.buildArgs(title, message, bundleID)
		if err != nil {
			logging.Debug("%s detected but buildArgs failed: %v", mux.name, err)
			return nil, mux.name
		}
		return args, mux.name
	}
	return nil, ""
}

// buildTmuxClickArgs captures tmux target and builds notifier args.
func buildTmuxClickArgs(title, message, bundleID string) ([]string, error) {
	target, err := GetTmuxPaneTarget()
	if err != nil {
		return nil, err
	}
	return buildTmuxNotifierArgs(title, message, target, bundleID), nil
}

// buildZellijClickArgs captures zellij tab target and builds notifier args.
func buildZellijClickArgs(title, message, bundleID string) ([]string, error) {
	tabName, sessionName, err := GetZellijTabTarget()
	if err != nil {
		return nil, err
	}
	return buildZellijNotifierArgs(title, message, tabName, sessionName, bundleID), nil
}

// buildWezTermClickArgs captures WezTerm pane target and builds notifier args.
func buildWezTermClickArgs(title, message, bundleID string) ([]string, error) {
	paneID, socketPath, err := GetWezTermPaneTarget()
	if err != nil {
		return nil, err
	}
	return buildWezTermNotifierArgs(title, message, paneID, socketPath, bundleID), nil
}

// buildKittyClickArgs captures Kitty window target and builds notifier args.
func buildKittyClickArgs(title, message, bundleID string) ([]string, error) {
	windowID, listenOn, err := GetKittyWindowTarget()
	if err != nil {
		return nil, err
	}
	return buildKittyNotifierArgs(title, message, windowID, listenOn, bundleID), nil
}
