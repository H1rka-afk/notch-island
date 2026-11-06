#!/bin/bash
# Ovira installer (macOS 14+). Does not upload anything or change security settings.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/Source"
TMP="$(mktemp -d "${TMPDIR:-/tmp/}notch-island.XXXXXXXX")"
APP="$TMP/Ovira.app"
DEST="/Applications/Ovira.app"
# 4.7.0: Notch Island is now called Ovira. The same app (same identifier,
# so permissions and settings stay); the old copy is removed after install.
LEGACY="/Applications/Notch Island.app"
LOG="$ROOT/notch-island-install.log"

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

notify() {
  /usr/bin/osascript - "$1" "$2" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
    display dialog (item 2 of argv) with title (item 1 of argv) buttons {"OK"} default button "OK" with icon note
end run
APPLESCRIPT
}

fail() {
  printf '\nОшибка: %s\n' "$1" >&2
  notify "Ovira: ошибка" "$1"
  printf '\nОтчёт сборки: %s\n' "$LOG" >&2
  exit 1
}

cd "$ROOT"
printf 'Ovira 4.14.2\n'
printf '========================================================\n'

[[ "$(uname -s)" == "Darwin" ]] || fail "Этот установщик необходимо запустить на Mac."

VERSION="$(/usr/bin/sw_vers -productVersion)"
MAJOR="${VERSION%%.*}"
if (( MAJOR < 14 )); then
  fail "Требуется macOS Sonoma 14 или новее (у тебя $VERSION)."
fi

# 3.21.0: releases from GitHub carry a ready-made app (built and tested on
# GitHub's Macs). Then nothing is compiled here: it is only signed with this
# Mac's persistent signature and installed — a matter of seconds.
PREBUILT="$ROOT/Prebuilt/Ovira.app"
[[ -d "$PREBUILT" ]] || PREBUILT="$ROOT/Prebuilt/Notch Island.app"
USE_PREBUILT=0
if [[ -x "$PREBUILT/Contents/MacOS/NotchIsland" ]] &&
   [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PREBUILT/Contents/Info.plist" 2>/dev/null)" == \
      "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$SRC/Info.plist" 2>/dev/null)" ]]; then
  USE_PREBUILT=1
fi

if [[ "$USE_PREBUILT" != "1" ]] && { ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1 || ! /usr/bin/xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; }; then
  printf 'Нужны бесплатные инструменты Apple Command Line Tools.\n'
  printf 'Запускаю их системную установку. По её завершении снова открой этот файл.\n'
  /usr/bin/xcode-select --install 2>/dev/null || true
  notify "Ovira" "Для первой установки нужны бесплатные инструменты командной строки Apple (не полный Xcode). После их установки запусти этот установщик ещё раз."
  exit 0
fi

for REQUIRED in SpectrumTuning.swift ArtworkSourcePreferences.swift TimerRoutingPolicy.swift ClockTimerTextParser.swift ClockTimerControlPolicy.swift ClockTimerBridge.swift LowBatteryWarningTracker.swift IslandMotion.swift NotchSettingsWindow.swift NotchIslandApp.swift IslandView.swift MediaReader.swift SystemAudioAnalyzer.swift LockScreenOverlay.swift FavoritesController.swift YandexBrowserFavorites.swift YandexAccountFavorites.swift YandexDesktopFavorites.swift YandexDesktopArtwork.swift YandexCatalogArtwork.swift AirPodsMonitor.swift FocusModeParser.swift FocusModeMonitor.swift UpdatePolicy.swift AppUpdater.swift MediaScrollGesture.swift SystemVolume.swift SupportTools.swift LabFeatures.swift LabAgenda.swift ShelfFeature.swift Info.plist NotchIsland.icns; do
  [[ -f "$SRC/$REQUIRED" ]] || fail "Не найден Source/$REQUIRED. Сначала распакуй весь архив."
done

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
cp "$SRC/NotchIsland.icns" "$APP/Contents/Resources/NotchIsland.icns"
# 3.9.0: dark/light icons, switched with the theme while the app runs.
for ICON in IconDark.png IconLight.png; do
  [[ -f "$SRC/$ICON" ]] && cp "$SRC/$ICON" "$APP/Contents/Resources/$ICON"
done
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [[ "$USE_PREBUILT" == "1" ]]; then
printf '\nГотовая сборка с GitHub — компилировать не нужно.\n'
rm -rf "$APP"
/usr/bin/ditto "$PREBUILT" "$APP" || fail "Не удалось скопировать готовую сборку."
else
SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
if [[ "$ARCH" != "arm64" && "$ARCH" != "x86_64" ]]; then fail "Неизвестная архитектура Mac: $ARCH"; fi
TARGET="${ARCH}-apple-macosx14.0"

printf '\nСобираю нативную версию для %s…\n' "$ARCH"
# 3.16.3: one whole-module pass with code generation on every CPU core —
# the module is parsed and type-checked once instead of once per batch,
# which makes the build (and so every update) noticeably faster.
CORES="$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || echo 4)"
if ! /usr/bin/xcrun --sdk macosx swiftc \
  -sdk "$SDK" -target "$TARGET" -O -wmo -num-threads "$CORES" -parse-as-library \
  -framework ServiceManagement -framework AppKit -framework SwiftUI -framework IOKit -framework CoreAudio -framework AudioToolbox -framework Security -framework Carbon -framework ApplicationServices -framework IOBluetooth -framework CoreMediaIO -framework Network -framework EventKit -framework SystemConfiguration -framework UniformTypeIdentifiers -framework CoreLocation -framework Collaboration -framework OpenDirectory -framework ScreenCaptureKit -framework AVFoundation -framework CoreImage -framework SceneKit \
  "$SRC/SpectrumTuning.swift" "$SRC/ArtworkSourcePreferences.swift" "$SRC/TimerRoutingPolicy.swift" "$SRC/ClockTimerTextParser.swift" "$SRC/ClockTimerControlPolicy.swift" "$SRC/ClockTimerBridge.swift" "$SRC/LowBatteryWarningTracker.swift" "$SRC/IslandMotion.swift" "$SRC/NotchIslandApp.swift" "$SRC/NotchSettingsWindow.swift" "$SRC/MediaReader.swift" "$SRC/IslandView.swift" "$SRC/SystemAudioAnalyzer.swift" "$SRC/LockScreenOverlay.swift" "$SRC/FavoritesController.swift" "$SRC/YandexBrowserFavorites.swift" "$SRC/YandexAccountFavorites.swift" "$SRC/YandexDesktopFavorites.swift" "$SRC/YandexDesktopArtwork.swift" "$SRC/YandexCatalogArtwork.swift" "$SRC/AirPodsMonitor.swift" "$SRC/FocusModeParser.swift" "$SRC/FocusModeMonitor.swift" "$SRC/UpdatePolicy.swift" "$SRC/AppUpdater.swift" "$SRC/MediaScrollGesture.swift" "$SRC/SystemVolume.swift" "$SRC/SupportTools.swift" "$SRC/LabFeatures.swift" "$SRC/LabAgenda.swift" "$SRC/ShelfFeature.swift" "$SRC/MediaVisibilityPolicy.swift" "$SRC/IslandProfiles.swift" "$SRC/SettingsSearch.swift" "$SRC/IslandWaveform.swift" "$SRC/LockWidgets.swift" "$SRC/LockWeather.swift" "$SRC/AppIconSwitcher.swift" "$SRC/AirDropFormat.swift" "$SRC/AirDropFeature.swift" "$SRC/WallpaperStore.swift" "$SRC/LockWallpaper.swift" "$SRC/PerformanceMonitor.swift" "$SRC/WidgetFormat.swift" "$SRC/MacStats.swift" "$SRC/IslandDemo.swift" "$SRC/Onboarding.swift" "$SRC/EyeBreakPolicy.swift" "$SRC/EyeBreak.swift" "$SRC/ArtworkBlur.swift" "$SRC/CoverPaletteMath.swift" "$SRC/CoverPalette.swift" "$SRC/ReleaseNotes.swift" "$SRC/Island40.swift" "$SRC/LockStandBy.swift" "$SRC/CustomThemes.swift" "$SRC/LayoutConverter.swift" "$SRC/LayoutFix.swift" "$SRC/DayStats.swift" "$SRC/DayStatsStore.swift" "$SRC/AirPods3D.swift" "$SRC/InlinePalette.swift" "$SRC/LockWidgetLayout.swift" \
  -o "$APP/Contents/MacOS/NotchIsland" >"$LOG" 2>&1; then
  tail -n 35 "$LOG" >&2
  fail "Не удалось собрать приложение. Подробности записаны в notch-island-install.log рядом с установщиком."
fi
fi

chmod +x "$APP/Contents/MacOS/NotchIsland"
# TCC privacy grants are bound to the signing identity. A fresh ad-hoc
# signature (-) changes the identity after every rebuild, even if System
# Settings keeps showing the old Accessibility checkbox as enabled.
# Prefer a real, already-installed valid signing identity when available.
# 3.2.0 — a PERSISTENT local signature. macOS ties "Accessibility", "Full
# Disk Access" and folder grants to the app's designated requirement. With
# an ad-hoc signature that requirement is a hash of each build, so every
# update lost the grants. A certificate created once on this Mac gives the
# requirement 'identifier "app.notchisland.desktop" and certificate leaf =
# H"…"', identical for every future build. It lives in a SEPARATE keychain
# (the login keychain is never touched) whose random password is stored next
# to it, readable only by this user, so signing never shows a prompt.
LOCAL_NAME="Notch Island Local Signing"
LOCAL_DIR="$HOME/Library/Application Support/Notch Island/Signing"
LOCAL_KC="$LOCAL_DIR/NotchIsland-signing.keychain-db"
LOCAL_PASS_FILE="$LOCAL_DIR/keychain-password"

ensure_local_identity() {
  mkdir -p "$LOCAL_DIR" || return 1
  chmod 700 "$LOCAL_DIR" 2>/dev/null || true
  if [[ ! -f "$LOCAL_KC" || ! -s "$LOCAL_PASS_FILE" ]]; then
    printf 'Создаю постоянный сертификат подписи (один раз)…\n'
    rm -f "$LOCAL_KC"
    local pass p12pass work
    pass="$(/usr/bin/openssl rand -hex 24)" || return 1
    p12pass="$(/usr/bin/openssl rand -hex 12)" || return 1
    work="$(mktemp -d "${TMPDIR:-/tmp/}notch-island-sign.XXXXXXXX")" || return 1
    cat > "$work/cert.cnf" <<CNF
[ req ]
distinguished_name = dn
prompt = no
x509_extensions = ext
[ dn ]
CN = $LOCAL_NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CNF
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$work/cert.cnf" \
      -keyout "$work/key.pem" -out "$work/cert.pem" || { rm -rf "$work"; return 1; }
    /usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$LOCAL_NAME" \
      -out "$work/id.p12" -passout "pass:$p12pass" || { rm -rf "$work"; return 1; }
    /usr/bin/security create-keychain -p "$pass" "$LOCAL_KC" || { rm -rf "$work"; return 1; }
    /usr/bin/security set-keychain-settings "$LOCAL_KC" || true   # never auto-lock
    /usr/bin/security unlock-keychain -p "$pass" "$LOCAL_KC" || { rm -rf "$work"; return 1; }
    /usr/bin/security import "$work/id.p12" -k "$LOCAL_KC" -P "$p12pass" -T /usr/bin/codesign -f pkcs12 \
      || { rm -rf "$work"; return 1; }
    /usr/bin/security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pass" "$LOCAL_KC" >/dev/null \
      || { rm -rf "$work"; return 1; }
    rm -rf "$work"
    ( umask 077; printf '%s' "$pass" > "$LOCAL_PASS_FILE" ) || return 1
  fi
  /usr/bin/security unlock-keychain -p "$(cat "$LOCAL_PASS_FILE")" "$LOCAL_KC" || return 1
  local identities
  identities="$(/usr/bin/security find-identity -p codesigning "$LOCAL_KC" 2>/dev/null)" || return 1
  [[ "$identities" == *"$LOCAL_NAME"* ]]
}

SIGN_ID="${NOTCH_ISLAND_SIGNING_IDENTITY:-}"
SIGN_KEYCHAIN=""
if [[ -z "$SIGN_ID" ]]; then
  SIGN_ID="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null | /usr/bin/awk '/Apple Development:|Mac Developer:|Developer ID Application:/ {print $2; exit}')"
fi
if [[ "$SIGN_ID" == "-" ]]; then SIGN_ID=""; fi
if [[ -z "$SIGN_ID" ]]; then
  if ensure_local_identity >>"$LOG" 2>&1; then
    SIGN_ID="$LOCAL_NAME"
    SIGN_KEYCHAIN="$LOCAL_KC"
  else
    printf 'Local signing identity unavailable; falling back to ad-hoc\n' >>"$LOG"
  fi
fi
SIGN_MODE="adhoc"
if [[ -n "$SIGN_ID" ]]; then
  printf '\nПодписываю постоянной подписью — разрешения сохранятся при обновлениях.\n'
  printf 'Signing: persistent identity %s\n' "$SIGN_ID" >>"$LOG"
  if [[ -n "$SIGN_KEYCHAIN" ]]; then
    SIGN_ARGS=(--force --keychain "$SIGN_KEYCHAIN" --sign "$SIGN_ID")
  else
    SIGN_ARGS=(--force --sign "$SIGN_ID")
  fi
  if /usr/bin/codesign "${SIGN_ARGS[@]}" "$APP" >>"$LOG" 2>&1 &&
     /usr/bin/codesign --verify --strict "$APP" >>"$LOG" 2>&1; then
    SIGN_MODE="persistent"
  else
    printf 'Постоянная подпись не удалась — использую временную.\n'
    printf 'Persistent signing failed; falling back to ad-hoc\n' >>"$LOG"
  fi
fi
if [[ "$SIGN_MODE" == "adhoc" ]]; then
  printf '\nИспользую временную подпись.\n'
  printf 'ВНИМАНИЕ: после обновления macOS может забыть разрешение «Универсальный доступ».\n'
  printf 'После установки выключи и вновь включи разрешение для Ovira.\n'
  printf 'Signing: ad-hoc (Accessibility grant may need to be re-authorized)\n' >>"$LOG"
  /usr/bin/codesign --force --sign - "$APP" >>"$LOG" 2>&1 || fail "Ошибка временной подписи приложения."
fi
/usr/bin/codesign --verify --strict "$APP" >>"$LOG" 2>&1 || fail "Проверка подписи собранного приложения не пройдена."

printf 'Останавливаю ранее запущенный Ovira (если есть)…\n'
# 3.6.3: the real reason the app "did not restart": the old copy was never
# stopped (pgrep/killall did not find it from here), so `open` merely woke
# the still-running OLD app. Find it by its executable path with ps, and by
# our parent process (a one-click update is started BY the app), then stop
# it and wait until it is really gone.
island_pids() {
  { /bin/ps -axo pid=,comm= 2>/dev/null | /usr/bin/grep -E '(^|/)NotchIsland$' | /usr/bin/awk '{print $1}'; } || true
}
OLD_PIDS="$(island_pids)"
if /bin/ps -p "$PPID" -o comm= 2>/dev/null | /usr/bin/grep -qE '(^|/)NotchIsland$'; then
  OLD_PIDS="$PPID $OLD_PIDS"
fi
OLD_PIDS="$(printf '%s\n' $OLD_PIDS | /usr/bin/sort -u | /usr/bin/tr '\n' ' ')"
if [[ -n "${OLD_PIDS// /}" ]]; then
  printf '  запущенные копии: %s\n' "$OLD_PIDS"
  for pid in $OLD_PIDS; do kill -TERM "$pid" 2>/dev/null || true; done
  /usr/bin/killall NotchIsland >/dev/null 2>&1 || true
  for i in $(seq 1 20); do
    alive=""
    for pid in $OLD_PIDS; do if kill -0 "$pid" 2>/dev/null; then alive="$alive $pid"; fi; done
    if [[ -z "$alive" ]]; then break; fi
    sleep 0.25
  done
  for pid in $alive; do kill -KILL "$pid" 2>/dev/null || true; done
  if [[ -n "$alive" ]]; then printf '  принудительно остановлены:%s\n' "$alive"; fi
  sleep 0.5
fi

printf 'Устанавливаю приложение в /Applications…\n'
# 3.4.2: never overwrite the signed binary IN PLACE. macOS caches the code
# signature of the old file; a new binary written into the same file is
# killed at launch ("Code Signature Invalid") until that cache expires —
# this is why the freshly updated app did not open by itself. Move the old
# bundle aside and copy the new one as brand-new files.
OLD_APP=""
if [[ -d "$DEST" ]]; then
  OLD_APP="$(/usr/bin/dirname "$DEST")/.Ovira.old.$$.app"
  if /bin/mv "$DEST" "$OLD_APP" 2>>"$LOG"; then
    printf 'old bundle moved aside: %s\n' "$OLD_APP" >>"$LOG"
  else
    OLD_APP=""
  fi
fi
if ! /usr/bin/ditto "$APP" "$DEST" >>"$LOG" 2>&1; then
  printf 'macOS запросит разрешение администратора на запись в Программы.\n'
  if ! /usr/bin/osascript - "$APP" "$DEST" <<'APPLESCRIPT'
on run argv
    set sourcePath to item 1 of argv
    set destPath to item 2 of argv
    do shell script "/usr/bin/ditto " & quoted form of sourcePath & " " & quoted form of destPath with administrator privileges
end run
APPLESCRIPT
  then
    fail "Не удалось скопировать приложение в /Applications."
  fi
fi

if [[ -n "$OLD_APP" ]]; then
  if [[ -x "$DEST/Contents/MacOS/NotchIsland" ]]; then
    /bin/rm -rf "$OLD_APP" >>"$LOG" 2>&1 || true
  else
    # The copy failed — put the previous version back.
    /bin/rm -rf "$DEST" >/dev/null 2>&1 || true
    /bin/mv "$OLD_APP" "$DEST" >>"$LOG" 2>&1 || true
  fi
fi
REGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
# 4.7.0: remove the copy installed under the old name.
if [[ -d "$LEGACY" && -x "$DEST/Contents/MacOS/NotchIsland" ]]; then
  if [[ -x "$REGISTER" ]]; then "$REGISTER" -u "$LEGACY" >/dev/null 2>&1 || true; fi
  if /bin/rm -rf "$LEGACY" >>"$LOG" 2>&1; then
    printf 'Старая копия «Notch Island» удалена — теперь приложение называется Ovira.\n'
  else
    printf 'Старую копию «Notch Island» не удалось удалить — её можно перенести в Корзину вручную.\n'
  fi
fi
# 3.8.22: new icon — nudge Finder/Dock to drop the cached old one.
/usr/bin/touch "$DEST" >/dev/null 2>&1 || true
if [[ -x "$REGISTER" ]]; then "$REGISTER" -f "$DEST" >/dev/null 2>&1 || true; fi

printf '\nУстановлено: %s\n' "$DEST"
printf 'Приложение можно открывать через Launchpad, Spotlight или папку Программы.\n'
printf 'Значок Ovira доступен в Dock: нажми его, чтобы открыть настройки. Иконка в строке меню тоже остаётся.\n'

# Open without requiring Xcode for subsequent launches. A one-click update
# runs this script after the old app has quit, so CONFIRM the new version is
# really running and retry; every step is written to the update log.
# 3.4.2: after a one-click update this script is the last survivor of the
# old app, and macOS ignored its plain `open` (exit 0, nothing launched).
# Fallback: hand the launch to launchd as a separate one-shot job, fully
# outside the old app's session; the job is removed as soon as the app runs.
island_running() { [[ -n "$(island_pids)" ]]; }
wait_for_island() {
  local i
  for i in $(seq 1 "$1"); do island_running && return 0; sleep 0.5; done
  return 1
}
RELAUNCH_LABEL="local.notchisland.relaunch"
printf 'Запускаю новую версию…\n'
/usr/bin/open "$DEST"
printf '  open → код %s\n' "$?"
if wait_for_island 8; then
  printf 'Новая версия запущена (pid %s).\n' "$(island_pids | /usr/bin/tr '\n' ' ')"
else
  printf 'Обычный запуск не сработал — запускаю через launchd…\n'
  /bin/launchctl remove "$RELAUNCH_LABEL" >/dev/null 2>&1 || true
  /bin/launchctl submit -l "$RELAUNCH_LABEL" -- /bin/sh -c '/usr/bin/open "$0"; exec /bin/sleep 600' "$DEST"
  printf '  launchctl submit → код %s\n' "$?"
  if wait_for_island 20; then
    printf 'Новая версия запущена (launchd).\n'
  fi
  /bin/launchctl remove "$RELAUNCH_LABEL" >/dev/null 2>&1 || true
fi
if ! island_running; then
  printf 'Не удалось запустить автоматически. Открой Ovira из «Программ».\n'
  printf '  диагностика: последние системные сообщения о запуске\n'
  /usr/bin/log show --last 40s --style compact \
    --predicate 'eventMessage CONTAINS[c] "NotchIsland" OR eventMessage CONTAINS[c] "Ovira" OR eventMessage CONTAINS[c] "Notch Island"' 2>/dev/null \
    | /usr/bin/grep -iE "kill|deny|denied|invalid|crash|fail|error|launch" | /usr/bin/tail -n 15 | /usr/bin/sed 's/^/    /'
fi
if [[ "$SIGN_MODE" == "adhoc" ]]; then
  notify "Ovira 3.2.0 установлен" "Приложение установлено. Новая сборка получает новую подпись: в «Полном доступе к диску» и «Универсальном доступе» выключи и снова включи Ovira, затем перезапусти приложение. Для чтения обложек Яндекс Музыки и таймеров проверь «Универсальный доступ»: macOS может сохранить разрешение от предыдущей сборки, но не признать его для новой. Выключи и вновь включи Ovira, затем полностью перезапусти приложение. Если не поможет — запусти отдельный файл «Восстановить доступ к таймеру.command» из архива."
elif [[ "${NOTCH_ISLAND_QUIET:-0}" != "1" ]]; then
  # 3.21.0: no dialog when the app updates itself — it just reopens.
  notify "Ovira 4.14.2 установлен" "Готово! Ovira подписан постоянной подписью этого Mac. Последний раз включи его в «Универсальном доступе» и «Полном доступе к диску» (настройки откроются на странице «Разрешения») — дальше разрешения будут сохраняться при обновлениях."
fi
