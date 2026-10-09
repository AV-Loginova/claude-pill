#!/bin/bash
# Собирает ClaudePill и ставит мод status-pill в Claude Code. Повторный запуск обновляет обе части.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
PET="$HOME/.claude/pet"
APP="$PET/ClaudePill.app"

step() { printf '\n\033[1m▸ %s\033[0m\n' "$1"; }
fail() { printf '\033[31m✘ %s\033[0m\n' "$1" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || fail "Нужен macOS."
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MACOS_MAJOR" -ge 14 ] || fail "Нужен macOS 14 или новее (анимации SwiftUI)."

step "Проверяю Swift"
command -v swiftc >/dev/null || fail "Нет swiftc. Установи Command Line Tools: xcode-select --install"

step "Собираю ClaudePill"
mkdir -p "$APP/Contents/MacOS" "$PET/sessions" "$PET/build"
cp "$REPO/pill/Info.plist" "$APP/Contents/Info.plist"
if ! swiftc -O -o "$APP/Contents/MacOS/ClaudePill" "$REPO/pill/main.swift" > "$PET/build/log.txt" 2>&1; then
  # Известная поломка CLT: старый module.modulemap дублирует модуль SwiftBridging
  if grep -q "redefinition of module 'SwiftBridging'" "$PET/build/log.txt"; then
    fail "Сломаны Command Line Tools (дубль SwiftBridging). Исправь и запусти снова:
  sudo mv /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap ~/module.modulemap.bak"
  fi
  tail -20 "$PET/build/log.txt" >&2
  fail "Сборка не удалась, полный лог: $PET/build/log.txt"
fi

step "Ищу Claude Code CLI"
CLAUDE="$(command -v claude || true)"
if [ -z "$CLAUDE" ]; then
  # Desktop-приложение кладёт CLI внутрь себя и не добавляет в PATH
  CLAUDE="$(find "$HOME/Library/Application Support/Claude/claude-code" -path '*MacOS/claude' -type f 2>/dev/null | sort -V | tail -1)"
fi
[ -n "$CLAUDE" ] || fail "Не нашла claude. Установи Claude Code или открой desktop-приложение Claude хотя бы раз."

step "Ставлю мод status-pill"
MARKETPLACE="$("$CLAUDE" plugin marketplace list 2>/dev/null | grep -A1 'claude-pet' || true)"
if [ -n "$MARKETPLACE" ] && ! printf '%s' "$MARKETPLACE" | grep -qF "($REPO)"; then
  # Маркетплейс с тем же именем смотрит в другую папку: переключаем на этот репозиторий
  "$CLAUDE" plugin marketplace remove claude-pet
  MARKETPLACE=""
fi
if [ -n "$MARKETPLACE" ]; then
  "$CLAUDE" plugin marketplace update claude-pet
  "$CLAUDE" plugin update status-pill@claude-pet --scope user || true
else
  "$CLAUDE" plugin marketplace add "$REPO"
  "$CLAUDE" plugin install status-pill@claude-pet --scope user
fi

step "Запускаю пилюлю"
pkill -x ClaudePill 2>/dev/null || true
open "$APP"

printf '\n\033[32m✔ Готово.\033[0m Новые беседы Claude Code появятся в пилюле. Уже открытые — после перезапуска.\n'
