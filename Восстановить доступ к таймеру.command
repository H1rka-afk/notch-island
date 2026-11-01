#!/bin/bash
# Opt-in repair for Notch Island Accessibility privacy authorization.
set -euo pipefail
printf 'Notch Island — восстановление «Универсального доступа»\n'
printf '===================================================\n\n'
printf 'Эта процедура затронет ТОЛЬКО разрешение Accessibility для\n'
printf 'app.notchisland.desktop (Notch Island). Другие приложения не затрагиваются.\n'
printf 'После сброса разрешение надо снова выдать в Системных настройках.\n\n'
if [[ "$(uname -s)" != "Darwin" ]]; then
  printf 'Команда предназначена только для macOS.\n'; exit 1
fi
if [[ ! -d "/Applications/Notch Island.app" ]]; then
  printf 'Сначала установи Notch Island в /Applications.\n'; exit 1
fi
printf 'Сбросить старую запись доступа Notch Island? [д/Н]: '
read -r answer
case "$answer" in д|Д|y|Y|yes|YES) ;; *) printf 'Отменено.\n'; exit 0;; esac
/usr/bin/killall NotchIsland >/dev/null 2>&1 || true
sleep 1
if /usr/bin/tccutil reset Accessibility app.notchisland.desktop; then
  printf '\nСтарая запись разрешения сброшена.\n'
else
  printf '\nmacOS не смогла сбросить запись по bundle ID.\n'
  printf 'Удали старую запись Notch Island вручную из «Универсального доступа», если она есть.\n'
fi
/usr/bin/open -a "/Applications/Notch Island.app" || true
/usr/bin/open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" || true
printf '\n1. Открой «Конфиденциальность и безопасность» → «Универсальный доступ».\n'
printf '2. Разреши «Notch Island». Если списка нет — добавь /Applications/Notch Island.app.\n'
printf '3. Закрой Notch Island через меню «Выйти» и открой из «Программы» снова.\n'
printf '4. Запусти таймер «Часов», в настройках Notch Island нажми «Проверить таймер».\n'
printf '\nНажми Enter, чтобы закрыть окно.\n'
read -r _ || true
