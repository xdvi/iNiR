#!/usr/bin/env bash
# Launch the configured terminal emulator
# Reads from iNiR config, falls back to kitty (project default)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/config-path.sh
source "$SCRIPT_DIR/lib/config-path.sh"

CONFIG_FILE="$(inir_config_file)"

if [[ -f "$CONFIG_FILE" ]]; then
    TERMINAL=$(grep -o '"terminal"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG_FILE" \
        | head -1 \
        | sed 's/.*"terminal"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
fi

TERMINAL="${TERMINAL:-kitty}"

# Exec inside transient user scope
exec_terminal_scoped() {
    if command -v systemd-run >/dev/null 2>&1 && [[ -S "$XDG_RUNTIME_DIR/systemd/private" ]]; then
        exec systemd-run --user --quiet --collect --same-dir --scope \
            --unit="inir-terminal-$$" --description="inir terminal" -- "$@"
    fi
    exec "$@"
}

if command -v "$TERMINAL" &>/dev/null; then
    exec_terminal_scoped "$TERMINAL" "$@"
fi

# Fallback chain: project default first, then popular alternatives
for fallback in kitty foot ghostty alacritty wezterm konsole xterm; do
    if command -v "$fallback" &>/dev/null; then
        exec_terminal_scoped "$fallback" "$@"
    fi
done

echo "No terminal emulator found" >&2
exit 1
