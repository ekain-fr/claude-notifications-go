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
