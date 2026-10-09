# Claude Pill

Плавающая пилюля поверх всех окон macOS, которая показывает, чем сейчас заняты все ваши беседы Claude Code: кто думает, кто работает, кому нужно ваше разрешение, а кто уже закончил.

- Висит поверх всех окон и на всех рабочих столах, не забирает фокус.
- Показывает настоящие названия бесед из desktop-приложения Claude, проект и ветку.
- Клик по строке открывает нужную беседу.
- Пилюля дышит, подпрыгивает, когда нужно ваше внимание, и выпускает конфетти, когда задача готова.

## Статусы

| Цвет | Текст | Когда |
|---|---|---|
| 🔵 | думаю… | Claude обдумывает ответ |
| 🔵 | `$ команда`, читаю `файл`, правлю `файл`, ищу по коду | Claude работает с инструментами |
| 🔵 | сабагент: …, сабагент · … | работает сабагент |
| 🔵 | фоном: … | ход закончен, но фоном ещё идут задачи |
| 🟠 | нужно разрешение | Claude ждёт разрешения на операцию |
| 🟣 | есть вопрос, нужно одобрение | вопрос с вариантами или план на утверждение |
| 🟢 | готово / готово, есть вопрос | ход закончен, вы его ещё не смотрели |
| ⚪ | жду задачу | беседа открыта и ничего не делает |

Строки «готово» и «жду задачу» можно убрать красной кнопкой с корзиной, которая появляется при наведении.

## Установка

Нужны macOS 14+, Command Line Tools (`xcode-select --install`) и Claude Code с поддержкой модов (проверено на 2.1.286).

```bash
git clone https://github.com/AV-Loginova/claude-pill.git
cd claude-pill
./install.sh
```

Скрипт собирает пилюлю в `~/.claude/pet/ClaudePill.app` и ставит мод `status-pill` из маркетплейса этого репозитория. Повторный запуск обновляет обе части. Уже открытые беседы подхватят мод после перезапуска.

Чтобы пилюля стартовала при входе в систему, добавьте `~/.claude/pet/ClaudePill.app` в «Системные настройки → Основные → Объекты входа». Мод и сам запускает её при старте беседы.

## Как это устроено

```
Claude Code (каждая беседа)             macOS
┌──────────────────────┐              ┌─────────────────────────┐
│ мод status-pill (TS) │── пишет ──▶  │ ~/.claude/pet/sessions/ │
│ слушает события      │   JSON       │   <session-id>.json     │
└──────────────────────┘              └────────────┬────────────┘
                                                   │ читает раз в 0.5 с
Claude.app                              ┌──────────▼──────────┐
 claude-code-sessions/*.json ─ читает ─▶│ ClaudePill (Swift)  │
 (названия, id для перехода)            │ NSPanel поверх окон │
                                        └─────────────────────┘
```

- **`plugin/`** — мод Claude Code на TypeScript (hooks API). Слушает `turn.step`, `tool.call`, `classic.PermissionRequest`, `turn.complete`, `session.append` и другие события и пишет статус беседы в JSON.
- **`pill/`** — приложение на Swift (AppKit + SwiftUI) из одного файла, собирается `swiftc` без Xcode-проекта.

## Ограничения

- Названия бесед и переход по клику берутся из **недокументированного** хранилища desktop-приложения Claude (`~/Library/Application Support/Claude/claude-code-sessions`) и deep link `claude://code/continue`. После обновления приложения это может сломаться: тогда вместо названия покажется первый промпт, а клик просто откроет Claude.
- В терминальных сессиях названия — это первая строка первого промпта.
- Фоновые задачи распознаются по тексту ответа инструмента («running in background with ID…»). Новый формат ответа может это сломать.

## Если сборка падает с `redefinition of module 'SwiftBridging'`

В Command Line Tools иногда остаётся старый файл, который дублирует модуль. `install.sh` распознаёт эту ошибку и подсказывает фикс:

```bash
sudo mv /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap ~/module.modulemap.bak
```

## Разработка

- Мод с hot reload: `claude --plugin-dir ./plugin`. Проверка: `claude plugin validate ./plugin`.
- Типы `claude-code` генерирует движок, их нет в репо: выполните `/plugin-types ./plugin/.claude-plugin/types` в интерактивном Claude Code, после этого `tsc -p plugin` и редактор перестанут ругаться.
- Пилюля: `swiftc -O -o ~/.claude/pet/ClaudePill.app/Contents/MacOS/ClaudePill pill/main.swift`, потом `pkill -x ClaudePill; open ~/.claude/pet/ClaudePill.app`.
- Демо без Claude: положите в `~/.claude/pet/sessions/demo.json` строку `{"project":"demo","branch":"main","title":"Демо","state":"waiting","text":"нужно разрешение","updatedAt":<ms>}`.

## Удаление

```bash
pkill -x ClaudePill
claude plugin uninstall status-pill@claude-pet
claude plugin marketplace remove claude-pet
rm -rf ~/.claude/pet
```

## Лицензия

MIT
