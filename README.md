# claude-code-usage-guard

Плагин для [Claude Code](https://docs.claude.com/en/docs/claude-code) который следит за потреблением 5-часового лимита подписки (Max / Pro) и при достижении порога (по умолчанию **98 %**) блокирует следующий tool call, а агенту отдаёт инструкцию:

> поставь cron-триггер через `CronCreate` на время сброса лимита и замри.

Триггеры `CronCreate` **session-scoped** — когда срабатывает, prompt приходит как новый turn в **ту же самую сессию** со всем контекстом. Ничего сохранять на диск не нужно, главное не закрывать процесс `claude` в терминале.

## Как это работает

```
 ┌─ PreToolUse hook ──────────────────────────────┐
 │ ccusage blocks --json --active                 │
 │ usage% = totalTokens / limit                   │
 │ if usage% ≥ 98  → exit 2 + stderr-инструкция   │
 │ if usage% ≥ 90  → stderr-warning, pass         │
 │ else            → exit 0 (approve)             │
 └────────────────────────────────────────────────┘

При блокировке агент получает:
  1. вызвать CronCreate(schedule=<reset+2min>, prompt="продолжай")
  2. ответить одной строкой и замолчать
  3. не делать других tool calls

Когда cron сработает — новый turn в той же сессии, lim сброшен, работа продолжается.
```

## Установка

### 1. Зависимости

```bash
brew install jq            # парсинг JSON
# ccusage подтянется через bunx/npx при первом запуске,
# можно поставить глобально для скорости:
bun install -g ccusage     # или: npm i -g ccusage
```

### 2. Подключить как локальный плагин

Claude Code поддерживает локальные плагины через `~/.claude/settings.json` (или per-project `.claude/settings.json`):

```json
{
  "plugins": {
    "usage-guard": {
      "source": "/Users/YOURNAME/work/claude-code-usage-guard"
    }
  }
}
```

Либо, если используется plugin marketplace — добавить как git-репозиторий:

```json
{
  "plugins": {
    "usage-guard": {
      "source": "git+https://your.git/path/claude-code-usage-guard.git"
    }
  }
}
```

### 3. Перезапустить Claude Code

```bash
# в активной сессии:
/hooks reload   # если поддерживается
# или просто переоткрыть терминал с claude
```

## Конфигурация

По умолчанию плагин читает `config/limits.json` из своей директории. Для кастомизации — скопируй в `~/.config/usage-guard/limits.json` (XDG):

```bash
mkdir -p ~/.config/usage-guard
cp /path/to/plugin/config/limits.json ~/.config/usage-guard/
$EDITOR ~/.config/usage-guard/limits.json
```

Поля:

| поле | по умолчанию | описание |
|---|---|---|
| `mode` | `auto` | `auto` — лимит = максимум `totalTokens` по истории ccusage; `fixed` — из `token_limit_5h`. |
| `token_limit_5h` | `220000000` | Жёсткий лимит в токенах (только при `mode=fixed`). Подогнать под свой план. |
| `threshold_block_pct` | `98` | Процент, при котором блокируем и ставим крон. |
| `threshold_warn_pct` | `90` | Процент предупреждения в stderr (агенту видно). |
| `throttle_seconds` | `30` | Минимальный интервал между проверками. |
| `skip_tools` | `[CronCreate, ...]` | Инструменты, которые никогда не блокируем — иначе агент не поставит крон. |
| `resume_prompt` | строка | Что придёт агенту когда крон сработает. |
| `reset_buffer_minutes` | `2` | Запас после `endTime` блока — чтобы попасть в новое окно. |

## Slash-команда

```
/usage-guard:status
```

Покажет текущее потребление, лимит, время сброса и пороги.

## Ограничения

- **Точных лимитов подписки Anthropic не публикует.** В режиме `auto` мы считаем «лимитом» максимум по истории — при первом запуске на новой подписке истории нет, будут ложные блокировки. После 1–2 полных окон режим стабилизируется.
- **ccusage читает локальные JSONL** из `~/.claude/projects/*/`. Если работать с одной подписки на нескольких машинах — счётчик будет занижен.
- **Machine must stay on.** Если выключить ноут — cron сработает, но процесс `claude` уже убит, сессия потеряется. Для более долгих пауз (weekly limit, несколько дней) нужен fallback с сохранением плана на диск и запуском через системный cron + `claude --resume`.
- **7-дневный TTL у `CronCreate`** — для 5h окна с запасом, для weekly — на грани.
- **Context compaction** до срабатывания триггера может урезать часть истории. На случай долгих пауз стоит дополнительно просить агента закоммитить прогресс.

## Отладка

Лог проверок: `~/.local/state/usage-guard/hook.log`
Последний timestamp чека: `~/.local/state/usage-guard/last-check`

Ручной прогон:

```bash
echo '{"tool_name":"Bash","tool_input":{}}' \
  | CLAUDE_PLUGIN_ROOT=/path/to/plugin \
  ./scripts/check-usage.sh; echo "exit=$?"
```

Сбросить throttle:

```bash
rm ~/.local/state/usage-guard/last-check
```

## Лицензия

MIT
