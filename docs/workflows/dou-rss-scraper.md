# DOU RSS Scraper

Scrapes job listings from DOU.ua via RSS feeds. Categories are fetched dynamically from the API.

**Folder:** Scrapers | **Tags:** `scraper`, `dou`

## Architecture

Uses 3 shared sub-workflows (folder: Shared, tag: `shared`):

| Sub-workflow | Purpose |
|---|---|
| **Get Criteria** | `GET /criteria?source={source}` — returns categories. Logs errors to Telegram, throws on failure. |
| **Send Jobs** | Checks count, `POST /jobs/ingest`, logs success/warn/error to Telegram. |
| **Telegram Notify** | Routes `{level, message}` to Telegram forum topics (error/warn → alerts, info → logs). |

## Flow (11 nodes)

```
Schedule Trigger (15 min)
  → Set Source ({source: "DOU"})
  → Get Criteria (Execute Workflow)
  → Build DOU URLs
  → Fetch RSS (batch 1 req / 2s, browser User-Agent)
      ├─ [success] → XML to JSON → Parse Jobs → Prepare Ingest → Send Jobs (Execute Workflow)
      └─ [error] → Format Error → Notify Error (Telegram)
```

- **Get Criteria** handles its own error logging + throws to stop pipeline
- **Send Jobs** handles has-jobs check, success/warn/error logging internally
- DOU Scraper only logs **Fetch RSS** errors (the only direct HTTP call)

## Environment Variables

Set in `.env`, passed via `docker-compose.yml`:

| Variable | Purpose |
|---|---|
| `JOB_HUNTER_API_URL` | API base URL (e.g., `http://host.docker.internal:8095`) |
| `TELEGRAM_CHAT_ID` | Telegram group chat ID |
| `TELEGRAM_LOG_TOPIC_ID` | Forum topic ID for info logs |
| `TELEGRAM_ALERT_TOPIC_ID` | Forum topic ID for errors/warnings |

Accessed via `$env.VARIABLE_NAME` in expressions.

## RSS URL

```
https://jobs.dou.ua/vacancies/feeds/?category={category}
```

Categories come from the API dynamically (`GET /criteria?source=DOU`).

Available DOU filters (not used — backend filters later):
- `exp=5plus` — experience 5+ years
- `remote` — remote only
- `city=Kyiv` — specific city

## Parsed Fields (JobIngestRequest)

| Field | Source | Example |
|---|---|---|
| title | `<title>` before " в " | Senior Java Developer |
| company | `<title>` after " в " | Intellias |
| url | `<link>` (utm stripped) | https://jobs.dou.ua/companies/... |
| description | `<description>` (HTML) | ... |
| source | Hardcoded | DOU |
| salary | `<title>` pattern `до/від $NNN` | до $3500 |
| location | `<title>` remaining parts | Kyiv, Lviv |
| remote | `<title>` contains "віддалено" | true |
| publishedAt | `<pubDate>` | Mon, 23 Feb 2026 18:06:19 +0200 |

## Edge Cases

- **Company names with commas** (Inc., Ltd., d.o.o.) — parser preserves legal suffixes
- **Empty feed** — Send Jobs sends `warn` to Telegram
- **No salary/location** — fields set to null
- **HTML entities** (`&nbsp;`, `&amp;`) — decoded in parser
- **DOU blocks n8n User-Agent** — browser User-Agent header required
- **Single item in RSS** — parser handles both array and single object

## Observability

| Event | Level | Source |
|---|---|---|
| Jobs sent to API | `info` | Send Jobs sub-workflow |
| No jobs found | `warn` | Send Jobs sub-workflow |
| API error (criteria) | `error` | Get Criteria sub-workflow |
| API error (ingest) | `error` | Send Jobs sub-workflow |
| RSS fetch error | `error` | DOU Scraper (Format Error → Notify Error) |
| Workflow crash | — | n8n Executions tab |
