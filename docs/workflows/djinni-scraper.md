# Djinni Scraper

Scrapes job listings from Djinni.co listing pages. Uses JSON-LD structured data embedded in listing pages + HTML parsing for job URLs. Categories are fetched dynamically from the API.

**Folder:** Scrapers | **Tags:** `scraper`, `djinni`

## Architecture

Uses 3 shared sub-workflows (folder: Shared, tag: `shared`):

| Sub-workflow | Purpose |
|---|---|
| **Get Criteria** | `GET /criteria?source={source}` — returns categories. Logs errors to Telegram, throws on failure. |
| **Send Jobs** | Checks count, `POST /jobs/ingest`, logs success/warn/error to Telegram. |
| **Telegram Notify** | Routes `{level, message}` to Telegram forum topics (error/warn → alerts, info → logs). |

## Data Strategy

### Why listing pages instead of RSS?

| Approach | Jobs/request | Company | Location | Salary | Speed |
|---|---|---|---|---|---|
| **RSS only** | 30 | — | — | — | Fast |
| RSS + individual pages | 30 | ✓ | ✓ | ✓ (rare) | Slow (~3 min) |
| **Listing pages** (chosen) | ~20 | ✓ | ✓ | — | Fast (~1 min) |

Djinni listing pages (`/jobs/?primary_keyword=...`) contain a **JSON-LD array** with all ~20 job postings per page, including `hiringOrganization`, `jobLocationType`, `datePosted`. Job URLs are extracted from HTML `<a>` links. Location metadata is in HTML card text.

**Trade-off:** No salary data (only available on individual pages, and ~80% of Djinni listings don't disclose salary anyway).

### Data sources per field

| Field | Source | Reliability |
|---|---|---|
| title | JSON-LD `title` | Stable (structured data) |
| company | JSON-LD `hiringOrganization.name` | Stable |
| url | HTML `<a href="/jobs/{id}-{slug}/">` | Stable (regex) |
| description | JSON-LD `description` | Stable |
| source | Hardcoded `"djinni"` | — |
| salary | — | Not available on listing pages |
| location | HTML card metadata (·-separated) | Medium (HTML structure) |
| remote | JSON-LD `jobLocationType === "TELECOMMUTE"` | Stable |
| publishedAt | JSON-LD `datePosted` | Stable |

## Flow (10 nodes)

```
Schedule Trigger (15 min)
  → Set Source ({source: "djinni"})
  → Get Criteria (Execute Workflow)
  → Build Page URLs
  → Fetch Listing Pages (batch 1 req / 1s)
      ├─ [success] → Parse Jobs (JSON-LD + HTML) → Prepare Ingest → Send Jobs (Execute Workflow)
      └─ [error] → Format Error → Notify Error (Telegram)
```

- **Get Criteria** handles its own error logging + throws to stop pipeline
- **Send Jobs** handles has-jobs check, success/warn/error logging internally
- Djinni Scraper only logs **Fetch Listing Pages** errors (the only direct HTTP call)

## Node Details

### 1. Schedule Trigger
- Interval: every 15 minutes

### 2. Set Source
```javascript
return [{json: {source: 'djinni'}}];
```

### 3. Get Criteria (Execute Workflow)
- Calls shared sub-workflow `51QbvQ9rXWCQSL9Y`
- Input: `{source: "djinni"}`
- Output: `[{category: "Python"}, {category: "Kotlin"}, ...]`
- `onError: continueErrorOutput` → pipeline stops if criteria fetch fails

### 4. Build Page URLs
```javascript
return $input.all().map(item => ({
  json: {
    category: item.json.category,
    url: `https://djinni.co/jobs/?primary_keyword=${encodeURIComponent(item.json.category)}`
  }
}));
```

### 5. Fetch Listing Pages
- HTTP Request node
- URL: `={{ $json.url }}`
- Response format: **text** (HTML)
- Batching: 1 request / 1s interval
- No custom User-Agent needed (Djinni doesn't block default UA)
- `onError: continueErrorOutput`

### 6. Parse Jobs
Extracts JSON-LD array and job URLs from listing page HTML:
```javascript
const source = $('Set Source').first().json.source;
const allJobs = [];

for (const inputItem of $input.all()) {
  const html = inputItem.json.data;
  if (!html || typeof html !== 'string') continue;

  // 1. Extract JSON-LD array from page
  let jobPostings = [];
  const jsonLdMatch = html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/);
  if (jsonLdMatch) {
    try {
      const parsed = JSON.parse(jsonLdMatch[1]);
      jobPostings = Array.isArray(parsed) ? parsed : [parsed];
    } catch (e) { continue; }
  }
  if (jobPostings.length === 0) continue;

  // 2. Extract job URLs from HTML <a> links
  //    Pattern: href="/jobs/798656-senior-python-developer/"
  const urlPattern = /href="(\/jobs\/(\d+)-[^"]+\/)"/g;
  const urlMap = new Map(); // jobId → path
  let match;
  while ((match = urlPattern.exec(html)) !== null) {
    const path = match[1];
    const jobId = match[2];
    if (!urlMap.has(jobId)) {
      urlMap.set(jobId, path);
    }
  }
  const urlList = [...urlMap.values()];

  // 3. Extract location from HTML card metadata
  //    Pattern: "Full Remote · Countries of Europe or Ukraine · Product · 6 years"
  //    Located in card text between company and description
  const locationPattern = /(?:Full Remote|Remote|Office|Hybrid)[^<]*?·\s*([^·<]+?)(?:\s*·|\s*<)/g;
  const locations = [];
  let locMatch;
  while ((locMatch = locationPattern.exec(html)) !== null) {
    locations.push(locMatch[1].trim());
  }

  // 4. Build job records — match JSON-LD entries to URLs by position
  for (let i = 0; i < jobPostings.length; i++) {
    const posting = jobPostings[i];
    if (posting['@type'] !== 'JobPosting') continue;

    const jobUrl = i < urlList.length
      ? `https://djinni.co${urlList[i]}`
      : null;

    const location = i < locations.length ? locations[i] : null;

    allJobs.push({
      json: {
        title: posting.title || '',
        company: posting.hiringOrganization?.name || null,
        url: jobUrl,
        description: posting.description || '',
        source,
        salary: null,
        location,
        remote: posting.jobLocationType === 'TELECOMMUTE',
        publishedAt: posting.datePosted || null
      }
    });
  }
}

return allJobs;
```

### 7. Prepare Ingest
```javascript
const jobs = $input.all().map(i => i.json);
return [{json: {body: jobs, count: jobs.length}}];
```

### 8. Send Jobs (Execute Workflow)
- Calls shared sub-workflow `3JhDuzeLD3FbIOP1`
- `onError: continueErrorOutput`

### 9. Format Error
```javascript
const err = $input.first().json;
const msg = err.error || err.message || 'Unknown error';
return [{json: {level: 'error', message: `${$workflow.name}: ${msg}`}}];
```

### 10. Notify Error (Execute Workflow)
- Calls shared sub-workflow `TQShysginOAn9uQs`
- `onError: continueRegularOutput`

## Listing Page URL

```
https://djinni.co/jobs/?primary_keyword={category}
```

Categories come from the API dynamically (`GET /criteria?source=djinni`).

Available query parameters (can be added later):
- `page={N}` — pagination (20 jobs per page)
- `exp_level=2y` — minimum experience (no_exp, 1y, 2y, 3y, 5y, 10y)
- `english_level=upper_intermediate` — English level filter
- `employment=remote` — remote only
- `region=UKR` — region filter

## JSON-LD on Listing Page

Each listing page contains a single `<script type="application/ld+json">` block with an **array** of ~20 `JobPosting` objects:

```json
[
  {
    "@context": "https://schema.org/",
    "@type": "JobPosting",
    "title": "Senior Python Developer",
    "description": "CodeSmart is seeking an experienced...",
    "datePosted": "2026-02-24T23:01:29.697567",
    "hiringOrganization": {
      "@type": "Organization",
      "name": "Codesmart"
    },
    "experienceRequirements": {
      "monthsOfExperience": 72.0
    },
    "employmentType": "FULL_TIME",
    "jobLocationType": "TELECOMMUTE"
  },
  ...
]
```

**Not included in listing JSON-LD** (only on individual pages): `estimatedSalary`, `applicantLocationRequirements`, `identifier`, `url`, `industry`, `category`.

## Parsed Fields (JobIngestRequest)

| Field | Source | Example |
|---|---|---|
| title | JSON-LD `title` | Senior Python Developer |
| company | JSON-LD `hiringOrganization.name` | Codesmart |
| url | HTML `<a href>` | https://djinni.co/jobs/798656-... |
| description | JSON-LD `description` | CodeSmart is seeking... |
| source | Hardcoded | djinni |
| salary | — (not available) | null |
| location | HTML card metadata | Countries of Europe or Ukraine |
| remote | JSON-LD `jobLocationType` | true |
| publishedAt | JSON-LD `datePosted` | 2026-02-24T23:01:29.697567 |

## Differences from DOU Scraper

| Aspect | DOU | Djinni |
|---|---|---|
| Data source | RSS feed | Listing page HTML + JSON-LD |
| URL param | `category` | `primary_keyword` |
| Company | Parsed from `<title>` heuristic | JSON-LD `hiringOrganization.name` (reliable) |
| Salary | Parsed from `<title>` | Not available (most listings don't disclose) |
| Location | Parsed from `<title>` | HTML card metadata |
| Remote | "віддалено" in `<title>` | JSON-LD `jobLocationType` (reliable) |
| User-Agent | Browser UA required | Default UA works |
| Nodes | 11 | 10 |
| Speed | ~30s | ~10-15s |
| Proxies | Not needed | Not needed |

## Environment Variables

Same as DOU — no additional env vars needed:

| Variable | Purpose |
|---|---|
| `JOB_HUNTER_API_URL` | API base URL (e.g., `http://host.docker.internal:8095`) |
| `TELEGRAM_CHAT_ID` | Telegram group chat ID |
| `TELEGRAM_LOG_TOPIC_ID` | Forum topic ID for info logs |
| `TELEGRAM_ALERT_TOPIC_ID` | Forum topic ID for errors/warnings |

## Edge Cases

- **Empty JSON-LD array** — page has no jobs for this category, Parse Jobs skips it
- **URL count mismatch** — if JSON-LD entries ≠ HTML links, unmatched entries get url = null
- **Location parse fails** — location = null, rest of the data still sent
- **HTML structure change** — JSON-LD is stable (schema.org standard); HTML selectors may break
- **HTML entities in description** — JSON-LD description is already decoded
- **Mixed languages** — descriptions in Ukrainian and English (UTF-8)
- **No salary** — Djinni hides salary on listing pages; ~80% of listings don't disclose it at all

## Performance

| Metric | Estimate |
|---|---|
| Requests per category | 1 (page 1 only) |
| Jobs per request | ~20 |
| Total (5 categories) | 5 requests, ~100 jobs |
| Total time | ~10-15 seconds |
| Schedule interval | 15 minutes |

## Pagination (Future Enhancement)

Page 1 returns ~20 most recent jobs per category. For full coverage:

```
https://djinni.co/jobs/?primary_keyword=Python&page=1   → 20 jobs
https://djinni.co/jobs/?primary_keyword=Python&page=2   → 20 jobs
...
https://djinni.co/jobs/?primary_keyword=Python&page=13  → 17 jobs
                                                  Total: 257 jobs
```

To add pagination:
1. Modify Build Page URLs to generate URLs for pages 1..N
2. Extract total page count from HTML pagination element on page 1
3. Or use n8n HTTP Request built-in pagination (Options → Pagination)

Not needed for MVP — page 1 captures recent postings, and the 15-min schedule ensures we don't miss new jobs.

## Observability

| Event | Level | Source |
|---|---|---|
| Jobs sent to API | `info` | Send Jobs sub-workflow |
| No jobs found | `warn` | Send Jobs sub-workflow |
| API error (criteria) | `error` | Get Criteria sub-workflow |
| API error (ingest) | `error` | Send Jobs sub-workflow |
| Page fetch error | `error` | Djinni Scraper (Format Error → Notify Error) |
| Workflow crash | — | n8n Executions tab |
