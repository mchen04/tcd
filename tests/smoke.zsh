#!/usr/bin/env zsh
# Kept as the historical entry point; the suite now lives in run.zsh.
exec zsh "${${(%):-%x}:A:h}/run.zsh" "$@"
