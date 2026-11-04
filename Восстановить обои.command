#!/bin/bash
# Ovira 4.11 — puts the user's own wallpaper back after the lock-screen
# Aerial (only files in this user's Library; no administrator password).
set -uo pipefail
printf 'Ovira — восстановление обоев\n'
printf '============================\n\n'
printf 'Уберёт из списка Aerial всё, что добавила Ovira, вернёт сохранённые\n'
printf 'настройки обоев (если копия есть) и перезапустит процесс обоев macOS.\n'
printf 'Затрагиваются только файлы обоев в твоей папке пользователя.\n\n'
if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'Команда предназначена только для macOS.\n'; exit 1
fi
printf 'Продолжить? [д/Н]: '
read -r answer
case "$answer" in д|Д|y|Y|yes|YES) ;; *) printf 'Отменено.\n'; exit 0;; esac

/usr/bin/killall NotchIsland >/dev/null 2>&1 || true
sleep 1

WP="$HOME/Library/Application Support/com.apple.wallpaper"
ENTRIES="$WP/aerials/manifest/entries.json"
BACKUP="$HOME/Library/Application Support/Ovira/LockWallpaper/Index-backup.plist"

if [[ -f "$ENTRIES" ]]; then
  /usr/bin/osascript -l JavaScript - "$ENTRIES" "$WP/aerials" <<'JXA'
ObjC.import('Foundation');
function run(argv) {
  const path = argv[0], base = argv[1];
  const cat = '0E1A0000-0000-4000-8000-0000000000A1';
  const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  if (!text || text.isNil()) return 'нет списка';
  const json = JSON.parse(ObjC.unwrap(text));
  const fm = $.NSFileManager.defaultManager;
  const ours = (json.assets || []).filter(a => (a.categories || []).indexOf(cat) >= 0);
  ours.forEach(a => {
    fm.removeItemAtPathError(base + '/videos/' + a.id + '.mov', null);
    fm.removeItemAtPathError(base + '/thumbnails/' + a.id + '.png', null);
  });
  json.assets = (json.assets || []).filter(a => (a.categories || []).indexOf(cat) < 0);
  json.categories = (json.categories || []).filter(c => c.id !== cat);
  $(JSON.stringify(json, null, 2)).writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
  return 'убрано записей: ' + ours.length;
}
JXA
fi

if [[ -f "$BACKUP" ]]; then
  cp "$BACKUP" "$WP/Store/Index.plist" && printf 'Настройки обоев возвращены из копии.\n'
else
  printf 'Копии настроек нет — если обои всё ещё не те, выбери их в «Системных настройках» → «Обои».\n'
fi
/usr/bin/defaults delete app.notchisland.desktop lockAerialActiveV4110 >/dev/null 2>&1 || true
/usr/bin/defaults delete app.notchisland.desktop lockSystemWallpaperBackupV4100 >/dev/null 2>&1 || true
/usr/bin/killall WallpaperAgent >/dev/null 2>&1 || true
printf '\nГотово. Ovira можно снова открыть.\n'
