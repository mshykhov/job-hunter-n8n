# LinkedIn Scraper

Two-phase LinkedIn scraper: fast discovery of all new jobs via search, then parallel detail enrichment with proxy pool and browser fingerprints. Runs every 15 minutes.

**Folder:** Scrapers | **Tags:** `scraper`, `linkedin`

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         n8n Workflow                             │
│                                                                  │
│  Phase 1: DISCOVERY (fast, ~10 min)                              │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │ Schedule (15 min)                                         │    │
│  │   → Get Proxies + Fingerprints (Kotlin API)               │    │
│  │   → Get Criteria (Kotlin API)                             │    │
│  │   → Build Queries                                         │    │
│  │   → Search LinkedIn (job-spy-api, NO descriptions)        │    │
│  │   → Parse basic fields                                    │    │
│  │   → POST /jobs/check-urls (Kotlin API) → filter NEW only  │    │
│  └──────────────────────────────────────────────────────────┘    │
│                              ↓                                    │
│  Phase 2: ENRICHMENT (parallel, ~1-5 min)                        │
│  ┌──────────────────────────────────────────────────────────┐    │
│  │   → POST /jobs/enrich (job-spy-api)                       │    │
│  │       ↳ 20 proxy workers, each with browser fingerprint   │    │
│  │       ↳ random delay 7-15 sec per proxy                   │    │
│  │       ↳ auto-redistribute on proxy death                  │    │
│  │   → Process results (success/errors)                      │    │
│  │   → POST /jobs/ingest (Kotlin API)                        │    │
│  │   → Notify Telegram (stats)                               │    │
│  └──────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

### Dependencies

| Service | Endpoints Used | Purpose |
|---|---|---|
| **Kotlin API** | `GET /proxies/all` | Proxies + browser fingerprints |
| | `GET /criteria?source=linkedin` | Search categories |
| | `POST /jobs/check-urls` | Filter already-known URLs |
| | `POST /jobs/ingest` | Save jobs |
| **job-spy-api** | `GET /jobs` | LinkedIn search (python-jobspy) |
| | `POST /jobs/enrich` | Parallel detail page scraping |

### Shared sub-workflows

| Sub-workflow | ID | Purpose |
|---|---|---|
| **Get Criteria** | `51QbvQ9rXWCQSL9Y` | Fetches categories. Logs errors to Telegram, throws on failure. |
| **Get Proxies** | `W1ELujeuM4ivaoc7` | Fetches proxies + fingerprints. Logs errors to Telegram, throws on failure. |
| **Send Jobs** | `3JhDuzeLD3FbIOP1` | Checks count, `POST /jobs/ingest`, logs success/warn/error to Telegram. |
| **Telegram Notify** | `TQShysginOAn9uQs` | Routes `{level, message}` to Telegram forum topics. |

## Phase 1: Discovery

### How it works

Uses existing `GET /jobs` on job-spy-api (python-jobspy `scrape_jobs()`). No description fetching — only search result cards. Fast and lightweight.

### Search parameters

| Parameter | Value | Reason |
|---|---|---|
| `site` | `linkedin` | LinkedIn scraper |
| `search_term` | From criteria (Kotlin, Java, etc.) | Dynamic per category |
| `location` | `Europe` | Target region |
| `is_remote` | `true` | Weak filter but reduces noise |
| `results_wanted` | `200` | Covers high-volume categories (Java: 100+/hour) |
| `hours_old` | `1` | Only fresh jobs |
| `linkedin_fetch_description` | `false` | **No descriptions** — Phase 2 handles this |
| `description_format` | `markdown` | For any snippets that come through |
| `proxies` | All proxies comma-separated | python-jobspy round-robins internally |

### What search returns (per job)

| Field | Source | Available |
|---|---|---|
| title | `span.sr-only` | Always |
| company | `h4.base-search-card__subtitle` | Always |
| job_url | `a.base-card__full-link` | Always |
| location | `span.job-search-card__location` | Always |
| date_posted | `time.job-search-card__listdate[datetime]` | Always (fixed in v0.2.1) |
| is_remote | LinkedIn metadata | **Unreliable** (~5% accuracy) |
| salary | `span.job-search-card__salary-info` | Rare (<20%) |
| description | — | **Not available** (Phase 2) |

### Timing per category

| results_wanted | LinkedIn pages | Time | Safety |
|---|---|---|---|
| 50 | ~5 | ~30 sec | Very safe |
| 100 | ~10 | ~60 sec | Safe |
| **200** | **~20** | **~2 min** | **Safe (recommended)** |
| 1000 | ~100 | ~10 min | LinkedIn caps at offset=1000 |

python-jobspy adds 3-7 sec random delay between pages internally.

**5 categories × 2 min = ~10 min total for discovery.**

### URL filtering

After search, we call `POST /jobs/check-urls` with all found URLs. API returns which ones already exist in the database. We only enrich **new** URLs.

Typical numbers:
- First run: 200-500 new jobs
- Subsequent runs (every 15 min): 0-30 new jobs

## Phase 2: Enrichment

### How it works

New endpoint `POST /jobs/enrich` on job-spy-api. Fetches full detail pages from LinkedIn in parallel using a proxy worker pool with browser fingerprints.

### What enrichment returns (per job)

| Field | Selector | Example |
|---|---|---|
| description | `div.show-more-less-html__markup` | Full HTML/markdown |
| seniority | Job Criteria `[0]` | "Mid-Senior level" |
| employment_type | Job Criteria `[1]` | "Full-time" |
| job_function | Job Criteria `[2]` | "Engineering" |
| industries | Job Criteria `[3]` | "Software Development" |
| applicants | `figcaption.num-applicants__caption` | "Over 200 applicants" |
| salary | `div.salary.compensation__salary` | "$126,000-$180,000/yr" |
| apply_url | `code#applyUrl` | Direct application link |
| published_at | `meta[name=description]` "Posted HH:MM:SS AM/PM" + date_posted | "2026-02-26T12:42:21Z" |

### Worker pool architecture

```
                    ┌──────────────┐
                    │  Job Queue   │  ← all new URLs
                    │  (asyncio)   │
                    └──┬───┬───┬───┘
                       │   │   │
                 ┌─────┘   │   └─────┐
                 ▼         ▼         ▼
           ┌──────┐  ┌──────┐  ┌──────┐
           │Proxy 1│  │Proxy 2│  │Proxy 3│  ...×20
           │+fprint│  │+fprint│  │+fprint│
           └──┬───┘  └──┬───┘  └──┬───┘
              │         │         │
              ▼         ▼         ▼
         fetch job  fetch job  fetch job
         delay 7-15s delay 7-15s delay 7-15s
         fetch next  ← 429!     fetch next
         ...         DEAD       ...
                     (remaining jobs stay in queue,
                      alive workers pick them up)
```

Each proxy has a **stable browser fingerprint** (User-Agent, Sec-Ch-Ua, Accept-Language, etc.) assigned by the Kotlin API via ScrapeOps API. Same proxy always uses the same fingerprint — looks like a real user.

### Request format

```json
{
  "jobs": [
    {"url": "https://linkedin.com/jobs/view/123", "job_id": "123", "date_posted": "2026-02-26"}
  ],
  "proxies": [
    {
      "url": "user:pass@ip:port",
      "fingerprint": {
        "User-Agent": "Mozilla/5.0 ...",
        "Accept-Language": "en-US,en;q=0.9",
        "Sec-Ch-Ua": "\"Google Chrome\";v=\"131\"...",
        "Sec-Ch-Ua-Mobile": "?0",
        "Sec-Ch-Ua-Platform": "\"Windows\""
      }
    }
  ],
  "delay_min": 7,
  "delay_max": 15
}
```

### Response format

```json
{
  "results": [
    {
      "job_id": "123",
      "url": "https://linkedin.com/jobs/view/123",
      "status": "success",
      "data": {
        "description": "We are looking for...",
        "description_html": "<div>We are looking for...</div>",
        "seniority": "Mid-Senior level",
        "employment_type": "Full-time",
        "job_function": "Engineering",
        "industries": "Software Development",
        "applicants": "Over 200 applicants",
        "salary": "$126,000 - $180,000/yr",
        "apply_url": "https://company.com/apply/123",
        "published_at": "2026-02-26T12:42:21Z"
      }
    },
    {
      "job_id": "456",
      "status": "skipped",
      "error": "All proxies exhausted"
    }
  ],
  "stats": {
    "total": 50,
    "success": 42,
    "no_data": 3,
    "not_found": 1,
    "timeout": 1,
    "error": 0,
    "skipped": 3,
    "proxies_alive": 17,
    "proxies_dead": 3,
    "duration_seconds": 45
  }
}
```

### Error handling per job

| LinkedIn Response | Status | Action |
|---|---|---|
| 200 + description found | `success` | Data extracted, job ingested |
| 200 + empty page | `no_data` | Job probably deleted. Ingested without description |
| 404 | `not_found` | Job doesn't exist. Ingested without description |
| Timeout (30s) | `timeout` | Skipped this job. Next cycle will retry |
| Connection error | `error` | Skipped this job. Next cycle will retry |

### Error handling per proxy

| LinkedIn Response | Action |
|---|---|
| **429 Too Many Requests** | Proxy worker **dies**. Remaining jobs stay in queue for alive workers |
| **Redirect to `/signup`** | Proxy worker **dies**. Same as 429 |
| **All workers dead** | Remaining jobs returned as `status: "skipped"`. Next cycle retries them |

### Timing estimate

| Scenario | New jobs | 20 proxies × 10s delay | Total time |
|---|---|---|---|
| First run | ~500 | 500/20 = 25 per proxy | **~4 min** |
| Normal cycle | ~20 | 20/20 = 1 per proxy | **~10 sec** |
| Busy hour (Java) | ~50 | 50/20 = 2-3 per proxy | **~30 sec** |

## Notifications (Telegram)

| Event | Level | When |
|---|---|---|
| Jobs ingested: "LinkedIn: 15 jobs (12 new, 12 enriched)" | `info` | Every successful cycle |
| No new jobs found | `info` | Normal during off-hours |
| Enrichment partial: "LinkedIn: 5/20 enriched, 15 skipped (all proxies dead)" | `warn` | Proxies getting blocked |
| All proxies dead during enrichment | `error` | All 20 proxies blocked |
| Search failed (job-spy-api error) | `error` | job-spy-api down or LinkedIn search blocked |
| API unreachable (check-urls / ingest) | `error` | Kotlin API down |

### Notification message format

**Success:**
```
LinkedIn Scraper: 25 jobs found, 8 new, 8 enriched (3 no_data, 0 skipped)
Proxies: 20/20 alive | Duration: 45s
```

**Partial failure:**
```
⚠️ LinkedIn Scraper: 25 jobs found, 15 new, 10 enriched, 5 skipped
Proxies: 12/20 alive (8 got 429)
Duration: 120s
```

**Full failure:**
```
🚨 LinkedIn Scraper: enrichment failed — all proxies exhausted after 3 jobs
15 jobs will retry next cycle
```

## Data Flow (field mapping)

### Phase 1 → ingest (without description)

```javascript
{
  title: job.title,
  company: job.company,
  url: job.job_url,
  description: null,           // Phase 2 fills this
  source: 'linkedin',
  salary: parseSalary(job),    // from search (rare)
  location: job.location,
  remote: job.is_remote ?? null,
  publishedAt: job.date_posted,
  rawData: job,                // full search result
  category: matchedCategory    // matched by title against search terms
}
```

### Phase 2 → update with enriched data

```javascript
{
  title: searchData.title,
  company: searchData.company,
  url: searchData.url,
  description: enriched.description,
  source: 'linkedin',
  salary: enriched.salary || searchData.salary,
  location: searchData.location,
  remote: searchData.remote,
  publishedAt: enriched.published_at || searchData.publishedAt,
  rawData: {
    ...searchData.rawData,     // original search fields
    ...enriched.data           // all enriched fields
  },
  category: searchData.category // from Phase 1 title matching
}
```

`rawData` contains everything: description_html, seniority, employment_type, job_function, industries, applicants, apply_url.

## Environment Variables

| Variable | Purpose | Example |
|---|---|---|
| `JOB_HUNTER_API_URL` | Kotlin API base URL | `http://host.docker.internal:8095` |
| `JOB_SPY_API_URL` | job-spy-api base URL | `http://job-spy-api:8000` |

## Known Limitations

| Issue | Impact | Mitigation |
|---|---|---|
| LinkedIn `is_remote` filter unreliable | Non-remote jobs in results | AI matching on API side filters |
| python-jobspy pagination bug (#258) | Offsets skip non-linearly | `hours_old=1` keeps volume low |
| LinkedIn caps at offset=1000 | Max ~100-200 actual results | Fresh jobs window is small |
| Detail page may require login | Redirect to `/signup` | Proxy dies, others continue |
| No JSON-LD on LinkedIn guest pages | Must parse HTML with selectors | BeautifulSoup in job-spy-api |
| `published_at` time from meta desc | "Posted HH:MM:SS AM/PM" — timezone unspecified (likely UTC) | Combined with date_posted from Phase 1 |
| `date_posted` needs both CSS selectors | Fixed in python-jobspy main branch | job-spy-api v0.2.1 |

## Edge Cases

- **job-spy-api down** — Search fails → Telegram error notification
- **All proxies blocked during enrichment** — Jobs ingested without descriptions, retry next cycle
- **Kotlin API down** — check-urls/ingest fail → Telegram error notification
- **Empty search results** — Normal for `hours_old=1` during off-hours → Telegram info
- **Duplicate jobs across categories** — API deduplicates by URL (UNIQUE constraint)
- **Job deleted between search and enrichment** — `no_data` status, ingested without description
- **First run (cold start)** — ~500 new jobs, ~4 min enrichment, all within 15 min window
