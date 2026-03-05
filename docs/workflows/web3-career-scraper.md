# Web3.career Scraper

Scrapes remote job listings from web3.career using JSON-LD structured data (`schema.org/JobPosting`) embedded in category pages. Categories and `remoteOnly` flag are fetched dynamically from the Job Hunter API via criteria endpoint.

**Folder:** Scrapers | **Tags:** `scraper`, `web3career`

## Architecture

Uses 3 shared sub-workflows (folder: Shared, tag: `shared`):

| Sub-workflow | Purpose |
|---|---|
| **Get Criteria** | `GET /criteria?source={source}` — returns categories + remoteOnly. Logs errors to Telegram, throws on failure. |
| **Send Jobs** | Checks count, `POST /jobs/ingest`, logs success/warn/error to Telegram. |
| **Telegram Notify** | Routes `{level, message}` to Telegram forum topics (error/warn → alerts, info → logs). |

## Data Strategy

### Why listing pages + JSON-LD?

| Approach | Feasibility |
|---|---|
| REST API | Closed (need to apply) |
| RSS | None |
| Sitemap | Only ~3% coverage |
| **HTML + JSON-LD** (chosen) | Full coverage, structured data |

web3.career listing pages contain ~15 separate JSON-LD `JobPosting` blocks per page with complete structured data (title, company, salary, description, location). No enrichment phase needed — all data in a single GET request.

### Data sources per field

| Field | Source | Reliability |
|---|---|---|
| title | JSON-LD `title` | Stable (structured data) |
| company | JSON-LD `hiringOrganization.name` | Stable |
| url | HTML `<a href="/{slug}/{id}">` | Stable (regex) |
| description | JSON-LD `description` | Stable |
| source | Hardcoded `"web3career"` | — |
| salary | JSON-LD `baseSalary` (formatted) | Stable |
| location | JSON-LD `applicantLocationRequirements.name` | Stable |
| remote | JSON-LD `jobLocationType === "TELECOMMUTE"` | Stable |
| publishedAt | JSON-LD `datePosted` | Stable |
| rawData | Full JSON-LD JobPosting object | — |

## Flow (10 nodes)

```
Schedule Trigger (15 min)
  → Set Source ({source: "web3career"})
  → Get Criteria (Execute Workflow)
  → Build Page URLs (category + remoteOnly → path URLs)
  → Fetch Listing Pages (HTTP, text response, batch 1/2s)
      ├─ [success] → Parse Jobs (JSON-LD + URL extraction)
      │    → Prepare Ingest (aggregate + dedup by URL)
      │    → Send Jobs (Execute Workflow)
      └─ [error] → Format Error → Notify Error (Telegram)
```

- **Get Criteria** handles its own error logging + throws to stop pipeline
- **Send Jobs** handles has-jobs check, success/warn/error logging internally
- Web3.career Scraper only logs **Fetch Listing Pages** errors (the only direct HTTP call)

## Node Details

### 1. Schedule Trigger
- Interval: every 15 minutes

### 2. Set Source
```javascript
return [{json: {source: 'web3career'}}];
```

### 3. Get Criteria (Execute Workflow)
- Calls shared sub-workflow `51QbvQ9rXWCQSL9Y`
- Input: `{source: "web3career"}`
- Output: `[{category, locations, remoteOnly}, ...]`
- `onError: stopWorkflow`

### 4. Build Page URLs
```javascript
return $input.all().map(item => {
  const cat = item.json.category.toLowerCase().replace(/\s+/g, '-');
  const remote = item.json.remoteOnly ? '+remote' : '';
  return {
    json: {
      category: item.json.category,
      url: `https://web3.career/${cat}${remote}-jobs`
    }
  };
});
```

URL examples:
- "Kotlin" + remoteOnly → `https://web3.career/kotlin+remote-jobs`
- "Python" + !remoteOnly → `https://web3.career/python-jobs`

### 5. Fetch Listing Pages
- HTTP Request node
- URL: `={{ $json.url }}`
- Response format: **text** (raw HTML)
- Batching: 1 request / 2s interval
- `onError: continueErrorOutput`

### 6. Parse Jobs
Extracts JSON-LD `JobPosting` blocks and job URLs from page HTML:
```javascript
const source = $('Set Source').first().json.source;
const allJobs = [];

for (const inputItem of $input.all()) {
  const html = inputItem.json.data;
  if (!html || typeof html !== 'string') continue;

  // 1. Extract JSON-LD JobPosting blocks
  const jsonLdBlocks = [];
  const jsonLdRegex = /<script type="application\/ld\+json">([\s\S]*?)<\/script>/g;
  let m;
  while ((m = jsonLdRegex.exec(html)) !== null) {
    try {
      const parsed = JSON.parse(m[1]);
      const items = Array.isArray(parsed) ? parsed : [parsed];
      for (const item of items) {
        if (item['@type'] === 'JobPosting') jsonLdBlocks.push(item);
      }
    } catch {}
  }

  // 2. Extract job URLs from HTML: /{slug}/{numericId}
  const urlRegex = /href="\/([\w][\w.-]*(?:-[\w.-]+)*\/(\d+))"/g;
  const urlMap = new Map();
  let um;
  while ((um = urlRegex.exec(html)) !== null) {
    const path = '/' + um[1];
    const id = um[2];
    if (!urlMap.has(id)) urlMap.set(id, path);
  }
  const urlList = [...urlMap.values()];

  // 3. Pair JSON-LD with URLs by index
  for (let i = 0; i < jsonLdBlocks.length; i++) {
    const p = jsonLdBlocks[i];
    const jobUrl = i < urlList.length
      ? 'https://web3.career' + urlList[i]
      : null;
    if (!jobUrl) continue;

    const sal = p.baseSalary?.value;
    const salaryStr = sal
      ? `${sal.minValue}-${sal.maxValue} ${p.baseSalary?.currency || 'USD'}/${sal.unitText || 'YEAR'}`
      : null;

    allJobs.push({
      json: {
        title: p.title || '',
        company: p.hiringOrganization?.name || null,
        url: jobUrl,
        description: p.description || '',
        source,
        salary: salaryStr,
        location: p.applicantLocationRequirements?.name || null,
        remote: p.jobLocationType === 'TELECOMMUTE',
        publishedAt: p.datePosted || null,
        rawData: p
      }
    });
  }
}

return allJobs;
```

### 7. Prepare Ingest
```javascript
const source = $('Set Source').first().json.source;
const seen = new Set();
const jobs = $input.all()
  .map(i => i.json)
  .filter(j => {
    if (!j.url || seen.has(j.url)) return false;
    seen.add(j.url);
    return true;
  });

return [{json: {body: jobs, count: jobs.length, source}}];
```
Deduplicates jobs by URL (same job may appear under multiple categories).

### 8. Send Jobs (Execute Workflow)
- Calls shared sub-workflow `3JhDuzeLD3FbIOP1`
- `onError: stopWorkflow`

### 9. Format Error
```javascript
const err = $input.first().json;
const source = $('Set Source').first().json.source;
const msg = err.error?.message || err.message || 'Unknown error';
return [{json: {level: 'error', message: `${$workflow.name}: ${msg}`, source}}];
```

### 10. Notify Error (Execute Workflow)
- Calls shared Telegram Notify `TQShysginOAn9uQs`
- `onError: continueRegularOutput`

## Category Page URL

```
https://web3.career/{category}+remote-jobs   (when remoteOnly = true)
https://web3.career/{category}-jobs           (when remoteOnly = false)
```

15 jobs per page, path-based tag filtering.

## JSON-LD on Category Page

Each category page contains ~15 separate `<script type="application/ld+json">` blocks (not an array), each a complete `JobPosting`:

```json
{
  "@context": "https://schema.org",
  "@type": "JobPosting",
  "datePosted": "2026-02-24 18:53:32 +0000",
  "description": "LayerZero The Future is Omnichain...",
  "baseSalary": {
    "@type": "MonetaryAmount",
    "currency": "USD",
    "value": {
      "@type": "QuantitativeValue",
      "minValue": 135000.0,
      "maxValue": 250000.0,
      "unitText": "YEAR"
    }
  },
  "jobLocationType": "TELECOMMUTE",
  "applicantLocationRequirements": {
    "@type": "Country",
    "name": "Anywhere"
  },
  "title": "Backend Engineer",
  "hiringOrganization": {
    "@type": "Organization",
    "name": "Layerzerolabs"
  }
}
```

## Parsed Fields (JobIngestRequest)

| Field | Source | Example |
|---|---|---|
| title | JSON-LD `title` | Backend Engineer |
| company | JSON-LD `hiringOrganization.name` | Layerzerolabs |
| url | HTML `<a href>` | https://web3.career/backend-engineer-layerzerolabs/73714 |
| description | JSON-LD `description` | LayerZero The Future is Omnichain... |
| source | Hardcoded | web3career |
| salary | JSON-LD `baseSalary` | 135000-250000 USD/YEAR |
| location | JSON-LD `applicantLocationRequirements.name` | Anywhere |
| remote | JSON-LD `jobLocationType` | true |
| publishedAt | JSON-LD `datePosted` | 2026-02-24 18:53:32 +0000 |
| rawData | Full JSON-LD `JobPosting` object | `{...}` |

## Differences from Djinni Scraper

| Aspect | Djinni | web3.career |
|---|---|---|
| URL filter | `?primary_keyword={cat}` | `/{cat}+remote-jobs` (path-based) |
| Uses `remoteOnly` from criteria | No | Yes (`+remote` in URL) |
| Salary | null | Structured (baseSalary in JSON-LD) |
| Location | null | From JSON-LD `applicantLocationRequirements` |
| rawData | Not sent | JSON-LD object |
| Batching | 1 req/1s | 1 req/2s (be polite) |

## API Prerequisite

The Job Hunter API `source` enum needs `"web3career"` added to:
- `JobIngestRequest.source` enum
- `SearchCriteriaResponse` / `/criteria` endpoint
- `SearchPreferenceRequest.disabledSources` enum
- All other places where source enum is used

## Edge Cases

1. **No JSON-LD blocks** — page has no jobs for this category, Parse Jobs skips it
2. **URL count mismatch** — if JSON-LD blocks > HTML links, unmatched entries skipped (no URL = no job)
3. **Missing baseSalary** — not all jobs have salary data, salary = null for those
4. **Duplicate jobs across categories** — Prepare Ingest deduplicates by URL
5. **remoteOnly = false** — URL becomes `/{cat}-jobs` (no `+remote`)

## Performance

| Metric | Estimate |
|---|---|
| Requests per category | 1 (page 1 only) |
| Jobs per request | ~15 |
| Total (5 categories) | 5 requests, ~75 jobs |
| Total time | ~12-15 seconds |
| Schedule interval | 15 minutes |

## Environment Variables

No additional env vars needed. Uses existing:

| Variable | Purpose |
|---|---|
| `JOB_HUNTER_API_URL` | API base URL |
| `TELEGRAM_CHAT_ID` | Telegram group chat ID |
| `TELEGRAM_LOG_TOPIC_ID` | Forum topic for info logs |
| `TELEGRAM_ALERT_TOPIC_ID` | Forum topic for errors/warnings |

## Observability

| Event | Level | Source |
|---|---|---|
| Jobs sent to API | `info` | Send Jobs sub-workflow |
| No jobs found | `warn` | Send Jobs sub-workflow |
| API error (criteria) | `error` | Get Criteria sub-workflow |
| API error (ingest) | `error` | Send Jobs sub-workflow |
| Page fetch error | `error` | Web3.career Scraper (Format Error → Notify Error) |
