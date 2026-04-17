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

### 2. Установка из GitHub (через marketplace)

Репозиторий одновременно является и плагином, и маркетплейсом — внутри лежит `.claude-plugin/marketplace.json`. В активной сессии Claude Code:

```
/plugin marketplace add adyachenko/claude-code-usage-guard
/plugin install usage-guard@usage-guard
```

Либо указать полный URL:

```
/plugin marketplace add https://github.com/adyachenko/claude-code-usage-guard
```

После установки плагин лежит в `~/.claude/plugins/`, хук подхватится автоматически.

**Обновление:**
```
/plugin marketplace update usage-guard
```

### 3. Альтернатива: подключить как локальный плагин

Если хочется работать с локальным клоном (для разработки):

```json
// ~/.claude/settings.json
{
  "plugins": {
    "usage-guard": {
      "source": "/Users/YOURNAME/home/claude-code-usage-guard"
    }
  }
}
```

### 4. Перезапустить Claude Code

Закрыть и открыть сессию — хук зарегистрируется. Проверить:

```
/usage-guard:status
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

## Runtime-настройка из Claude Code CLI

Приоритет значений: **ENV > `~/.config/usage-guard/limits.json` > default**. Любое значение из конфига можно переопределить на лету:

### Slash-команды

| команда | что делает |
|---|---|
| `/usage-guard:status` | текущее потребление, лимит, пороги, активные override, состояние kill-switch |
| `/usage-guard:set-threshold 95` | персистентно записать новый `threshold_block_pct` в пользовательский конфиг |
| `/usage-guard:disable` | временно выключить плагин (создаёт флаг-файл, переживает рестарт) |
| `/usage-guard:enable` | включить обратно |

### Переменные окружения (разовый override, только на сессию)

Запускать `claude` с нужными значениями:

```bash
USAGE_GUARD_BLOCK_PCT=95 claude                  # блокировать на 95% вместо 98
USAGE_GUARD_MODE=fixed USAGE_GUARD_TOKEN_LIMIT=300000000 claude
USAGE_GUARD_DISABLE=1 claude                     # полностью выключить на эту сессию
```

Доступные переменные:

| env | соответствует полю в конфиге |
|---|---|
| `USAGE_GUARD_DISABLE=1` | kill-switch |
| `USAGE_GUARD_MODE` | `mode` |
| `USAGE_GUARD_BLOCK_PCT` | `threshold_block_pct` |
| `USAGE_GUARD_WARN_PCT` | `threshold_warn_pct` |
| `USAGE_GUARD_TOKEN_LIMIT` | `token_limit_5h` |
| `USAGE_GUARD_THROTTLE` | `throttle_seconds` |
| `USAGE_GUARD_BUFFER_MIN` | `reset_buffer_minutes` |
| `USAGE_GUARD_RESUME_PROMPT` | `resume_prompt` |

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
