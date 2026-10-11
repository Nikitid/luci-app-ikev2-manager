# mac-bridge

Удалённый MCP-сервер на Mac. Через него Claude Code Cloud Session (и claude.ai) выполняет
команды на Mac и по SSH на хостах, до которых дотягивается Mac.

```
Cloud Session (VM Anthropic)
   │  вызов инструмента mcp__mac__*
   ▼
MCP-прокси Anthropic ──HTTPS──► Tailscale Funnel ──► 127.0.0.1:8765 mac_bridge.py ──► zsh / ssh ──► роутеры, серверы
                                 (TLS до Mac)           (LaunchAgent, OAuth)
```

- VM не входит в твою сеть и ничего про неё не знает: она видит только набор инструментов.
- Коннектор привязан к аккаунту claude.ai, поэтому подключается к каждой новой сессии без настройки.
- Сервер слушает только loopback. Снаружи доступны только OAuth-эндпоинты и `/mcp` под bearer-токеном.
  Токен выдаётся после ввода парольной фразы на странице авторизации.

## Установка

Нужны python3 ≥ 3.9 (Homebrew или Command Line Tools) и Tailscale с Funnel.

```bash
cd mac-bridge
./install.sh                 # спросит парольную фразу, поднимет LaunchAgent и Funnel
```

При первом запуске `tailscale funnel` может вывести ссылку: открой её и разреши Funnel для этого Mac
в политике tailnet. Скрипт занимает первый свободный порт Funnel (443, 8443 или 10000).
Существующие правила `tailscale serve/funnel` он не трогает.

Через свой прокси (например, `cloudflared tunnel` на свой домен) вместо Funnel:

```bash
./install.sh --url https://mac-bridge.example.com   # прокси должен вести на http://127.0.0.1:8765
```

Затем в claude.ai: **Settings → Connectors → Add custom connector**. Имя `mac`, URL из вывода
скрипта (`…/mcp`), **Connect**, ввести парольную фразу. Дальше в любой Cloud Session можно просто
написать «на маке выполни …» или «зайди через мак на router-1 и покажи swanctl --list-sas».

## Инструменты

| инструмент | что делает |
| --- | --- |
| `mac_exec` | команда в `zsh -lc` от твоего пользователя: exit code, stdout, stderr, stdin, таймаут |
| `ssh_hosts` | алиасы `Host` из `~/.ssh/config` (с учётом `Include`) и правила доступа |
| `ssh_exec` | `ssh -o BatchMode=yes -- <alias> <command>` с твоими ключами, агентом и known_hosts; stdin для передачи файлов |
| `mac_read_file`, `mac_write_file` | файлы внутри `file_roots`; бинарные файлы через base64 |
| `bridge_status` | текущая политика |

## Политика: `~/Library/Application Support/mac-bridge/config.json`

Файл перечитывается при каждом вызове, перезапуск не нужен.

```json
{
  "local_exec": "allow",
  "ssh_exec": "allow",
  "file_read": "allow",
  "file_write": "confirm",
  "ssh_hosts": ["router-*", "nas"],
  "file_roots": ["~/Projects", "~/Downloads"]
}
```

- Режимы: `allow`, `confirm` или `deny`. В режиме `confirm` на Mac появляется диалог; если
  за `confirm_timeout` секунд никто не нажал «Allow», действие отклоняется.
- `ssh_hosts`: glob-шаблоны. Если список пустой, разрешены только алиасы из `~/.ssh/config`.
  Опции в имени хоста (`-oProxyCommand=…`) отклоняются всегда.
- Файловые инструменты не отдают ключи (`~/.ssh/id_*`, Keychains, `~/.gnupg`) и собственное
  состояние моста.

## Управление

```bash
B="$HOME/Library/Application Support/mac-bridge/bin/mac_bridge.py"
python3 "$B" status            # URL, политика, число живых токенов
python3 "$B" revoke-all        # отозвать все токены (Claude придётся подключиться заново)
python3 "$B" set-passphrase
tail -f "$HOME/Library/Application Support/mac-bridge/audit.jsonl"   # каждый вызов
launchctl kickstart -k gui/$(id -u)/dev.mac-bridge                   # перезапуск
./uninstall.sh [--purge]
```

## Безопасность: что важно понимать

- **`mac_exec: allow` даёт агенту полный шелл твоего пользователя.** Это касается и случаев,
  когда агента подтолкнул к действию чужой текст (prompt injection из веб-страницы, issue, лога).
  Ограничения файловых инструментов в этом режиме лишь защита в глубину. Если такого
  доверия нет, ставь `local_exec: confirm` и оставь `ssh_exec` на `allow` с узким `ssh_hosts`.
- Защита эндпоинта: PKCE S256, одноразовые коды, ротация refresh-токенов, токены хранятся
  только как SHA-256 в файле с правами `0600`, redirect разрешён только на claude.ai, claude.com
  и localhost. После 5 неверных парольных фраз за 15 минут вход блокируется (это работает
  и как DoS: посторонний может на 15 минут помешать новой авторизации, уже выданные токены
  продолжают работать).
- TLS от Anthropic терминируется на Mac (Funnel) или на твоём прокси. Содержимое вызовов видит
  MCP-прокси Anthropic, как и у любого коннектора.

## Ограничения

- Mac должен быть включён, не спать и находиться в залогиненной сессии: LaunchAgent работает
  в GUI-сессии, от неё зависят ssh-agent и Keychain. На питании: System Settings → Battery →
  Options → «Prevent automatic sleeping when the display is off».
- macOS 15+ может спросить разрешение **Local Network** для python при первом обращении к хосту
  в LAN. Без него подключения к локальным адресам получают «No route to host». Разрешение
  в System Settings → Privacy & Security → Local Network. Адресов tailnet (100.x) это не касается.
- Защищённые TCC папки (Documents, Desktop, iCloud) без Full Disk Access для python не читаются.
- Время выполнения одного вызова ограничено `max_timeout` (900 с). Сам MCP-клиент
  может оборвать вызов раньше. Долгие задачи запускай в фоне (`nohup … &`) и проверяй отдельным вызовом.
- Новый хост SSH должен быть в `known_hosts`: в BatchMode неизвестный ключ отклоняется.
  Один раз подключись к нему вручную.
