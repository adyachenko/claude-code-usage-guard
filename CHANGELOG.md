# CHANGELOG

Semver: MAJOR.MINOR.PATCH.

## [0.3.0] — 2026-04-17

### Почему

Anthropic UI не показывает потребление в токенах — только проценты. К тому
же разные модели (Opus/Sonnet/Haiku) расходуют 5h-квоту неодинаково.
Token-based лимит принципиально не может быть точным через смену
model-mix. Cost в $USD — лучший прокси, потому что ccusage уже взвешивает
модели по их прайсингу.

### Изменения

- **Новый режим `mode=cost`**: лимит в $USD через `cost_limit_5h_usd`.
  ccusage сам учитывает Opus/Sonnet/Haiku через их цены. Это самый близкий
  прокси к тому, как Anthropic квотирует «работу».
- **Новая команда `/usage-guard:calibrate <anthropic_pct>`**: смотришь
  процент в Anthropic UI, запускаешь команду — плагин читает текущий
  cost из ccusage и выводит реальный лимит подписки, сохраняет как
  `cost_limit_5h_usd`. Перекалибровка в любой момент.
- **status**: в cost-режиме показывает `$X.XX` вместо токенов, печатает
  дату/процент последней калибровки, warning про auto стал полезнее.
- **userConfig**: добавлено поле `cost_limit`.

### Flow для нового пользователя

```
/plugin install usage-guard@usage-guard
# поработать часок, чтобы в 5h-блоке был cost
# открыть claude.ai → Settings → Usage, посмотреть %
/usage-guard:calibrate 42       # подставь свой процент
/usage-guard:status             # теперь показывает % от реального лимита
```

## [0.2.0] — 2026-04-17

- **Прогноз вместо текущего потребления**: новая опция `block_on`
  (projected | current, default=projected). Блокировка срабатывает по
  прогнозируемому использованию полного 5h-окна от ccusage, а не по
  текущему счётчику. Ловит trajectory заранее.
- **Новая команда `/usage-guard:set-limit <tokens>`**: задаёт жёсткий
  лимит и переключает `mode=fixed`. Принимает суффиксы `k/m/b/g`
  (`44m`, `220M`, `1.1b`).
- **Расширенный `/usage-guard:status`**: показывает текущее потребление,
  прогноз, burn rate, оставшееся время до сброса, источник лимита
  (auto/fixed) и warning про auto-режим.
- **Источник лимита**: auto теперь читает `tokenLimitStatus.limit` из
  ccusage (через `--token-limit max`) вместо собственного подсчёта max
  по истории.

⚠ Breaking/поведение: блокировка теперь по прогнозу — обычно жёстче.
Чтобы вернуть старое поведение: `/usage-guard:set-threshold` и
`USAGE_GUARD_BLOCK_ON=current` в окружении.

## [0.1.4] — 2026-04-17

- **marketplace.json**: `source` переведён с `github`-объекта на relative path `"./"`.
  Для single-plugin-в-том-же-репо это документированный паттерн. При `source: github`,
  указывающем на тот же репо, что и маркетплейс, Claude Code создавал пустые
  `temp_github_*` директории в кэше и плагин не загружался — команды не
  регистрировались, хотя статус был "Enabled".

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
