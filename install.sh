#!/usr/bin/env bash
# tcd installer — wires up tcd.zsh and .tmux.conf without clobbering your stuff.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"
SOURCE_LINE="source \"$REPO_DIR/tcd.zsh\""

echo "tcd repo: $REPO_DIR"

# 1) Add the source line to .zshrc if it isn't there already.
if [ -f "$ZSHRC" ] && grep -qF "$REPO_DIR/tcd.zsh" "$ZSHRC"; then
  echo "✓ .zshrc already sources tcd.zsh"
else
  printf '\n# tcd\n%s\n' "$SOURCE_LINE" >> "$ZSHRC"
  echo "✓ appended source line to $ZSHRC"
fi

# 2) Symlink the tmux config (back up an existing real file first).
TMUX_CONF="$HOME/.tmux.conf"
if [ -L "$TMUX_CONF" ]; then
  ln -sfn "$REPO_DIR/.tmux.conf" "$TMUX_CONF"
  echo "✓ updated ~/.tmux.conf symlink"
elif [ -e "$TMUX_CONF" ]; then
  cp "$TMUX_CONF" "$TMUX_CONF.bak.$(date +%s)"
  ln -sfn "$REPO_DIR/.tmux.conf" "$TMUX_CONF"
  echo "✓ backed up existing ~/.tmux.conf and symlinked ours"
else
  ln -sfn "$REPO_DIR/.tmux.conf" "$TMUX_CONF"
  echo "✓ symlinked ~/.tmux.conf"
fi

# 3) Install tpm (tmux plugin manager) if missing.
TPM_DIR="$HOME/.tmux/plugins/tpm"
if [ -d "$TPM_DIR" ]; then
  echo "✓ tpm already installed"
else
  git clone --depth 1 https://github.com/tmux-plugins/tpm "$TPM_DIR"
  echo "✓ cloned tpm"
fi

echo
echo "Done. Now:"
echo "  1. Restart your shell (or: source \"$ZSHRC\")"
echo "  2. Start tmux and press  prefix + I  to install the tmux plugins"
