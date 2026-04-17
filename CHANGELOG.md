# CHANGELOG

Semver: MAJOR.MINOR.PATCH.

## [0.1.3] — 2026-04-17

- **marketplace.json**: `description` перенесён в `metadata.description` (соответствие документации Claude Code).
- **marketplace.json**: убран `version` у плагин-entry — версию теперь несёт только `plugin.json` (docs: «plugin manifest always wins silently»).
- **plugin.json**: добавлены `repository` и `keywords` (опциональные metadata-поля).
- Добавлен CHANGELOG.md.

## [0.1.2] — 2026-04-17

- `commands/*.md` переименованы: убран префикс `usage-guard-*` (Claude Code сам добавляет префикс плагина). Команды теперь `/usage-guard:status`, `/usage-guard:set-threshold`, `/usage-guard:disable`, `/usage-guard:enable`.

## [0.1.1] — 2026-04-17

- **plugin.json**: `userConfig` — добавлено обязательное поле `title` для каждой опции (иначе валидатор Claude Code отклоняет манифест).
- **plugin.json**: `homepage` должен быть валидным URL — был пустой строкой.

## [0.1.0] — 2026-04-17

Первый релиз.

- PreToolUse-хук мониторит потребление 5-часового окна через `ccusage`.
- При достижении порога (по умолчанию 98%) блокирует tool call и инструктирует агента поставить `CronCreate`-триггер на время сброса.
- `userConfig` в манифесте — Claude Code показывает диалог настроек при установке.
- ENV override: `USAGE_GUARD_*` (разово) и `CLAUDE_PLUGIN_OPTION_*` (из userConfig).
- Slash-команды: `/usage-guard:status`, `/usage-guard:set-threshold`, `/usage-guard:disable`, `/usage-guard:enable`.
- Kill-switch через флаг-файл `~/.local/state/usage-guard/disabled`.
