#!/bin/bash
# Runs the unit tests (pure logic, no UI). Used by GitHub Actions.
set -uo pipefail
cd "$(dirname "$0")/.."
SRC=Source
SDK="$(xcrun --sdk macosx --show-sdk-path)"
T="$(uname -m)-apple-macosx14.0"
OUT="$(mktemp -d)"
FAILED=0
run_test() {
  local name="$1"; shift
  if xcrun --sdk macosx swiftc -sdk "$SDK" -target "$T" -parse-as-library "$@" -o "$OUT/$name" 2>"$OUT/$name.log"; then
    if "$OUT/$name"; then :; else echo "::error::$name failed"; FAILED=1; fi
  else
    echo "::error::$name did not compile"; cat "$OUT/$name.log"; FAILED=1
  fi
}
run_test YandexCatalogTests "$SRC/YandexCatalogArtwork.swift" Tests/YandexCatalogTests.swift
run_test FocusModeTests "$SRC/FocusModeParser.swift" Tests/FocusModeTests.swift
run_test UpdatePolicyTests "$SRC/UpdatePolicy.swift" Tests/UpdatePolicyTests.swift
run_test MediaScrollGestureTests "$SRC/MediaScrollGesture.swift" Tests/MediaScrollGestureTests.swift
run_test ArtworkSourceTests "$SRC/ArtworkSourcePreferences.swift" Tests/ArtworkSourceTests.swift
run_test MediaVisibilityTests "$SRC/MediaVisibilityPolicy.swift" Tests/MediaVisibilityTests.swift
run_test IslandProfilesTests "$SRC/IslandProfiles.swift" Tests/IslandProfilesTests.swift
run_test SettingsSearchTests "$SRC/SettingsSearch.swift" Tests/SettingsSearchTests.swift
run_test IslandWaveformTests "$SRC/IslandWaveform.swift" Tests/IslandWaveformTests.swift
run_test WeatherTests "$SRC/LockWeather.swift" Tests/WeatherTests.swift
run_test ReleaseNotesTests "$SRC/ReleaseNotes.swift" Tests/ReleaseNotesTests.swift
run_test CoverPaletteTests "$SRC/CoverPaletteMath.swift" Tests/CoverPaletteTests.swift
run_test EyeBreakTests "$SRC/EyeBreakPolicy.swift" Tests/EyeBreakTests.swift
run_test WidgetFormatTests "$SRC/WidgetFormat.swift" Tests/WidgetFormatTests.swift
run_test WallpaperStoreTests "$SRC/WallpaperStore.swift" "$SRC/AirDropFormat.swift" Tests/WallpaperStoreTests.swift
run_test LayoutConverterTests "$SRC/LayoutConverter.swift" Tests/LayoutConverterTests.swift
exit $FAILED
