# EU Remote Jobs Scraper

Scrapes remote job listings from euremotejobs.com via WordPress REST API. Categories are fetched dynamically from the Job Hunter API, then mapped to WordPress tag IDs for filtered queries.

**Folder:** Scrapers | **Tags:** `scraper`, `euremotejobs`

## Architecture

Uses 3 shared sub-workflows (folder: Shared, tag: `shared`):

| Sub-workflow | Purpose |
|---|---|
| **Get Criteria** | `GET /criteria?source={source}` — returns categories. Logs errors to Telegram, throws on failure. |
| **Send Jobs** | Checks count, `POST /jobs/ingest`, logs success/warn/error to Telegram. |
| **Telegram Notify** | Routes `{level, message}` to Telegram forum topics (error/warn → alerts, info → logs). |

## Data Strategy

### Why WordPress REST API?

| Approach | Data quality | Speed | Complexity |
|---|---|---|---|
| HTML scraping | Medium (fragile selectors) | Slow (needs parsing) | High |
| AJAX load_more | Medium (HTML in response) | Medium | Medium |
| **WP REST API** (chosen) | High (structured JSON) | Fast | Low |

euremotejobs.com runs on WordPress + WP Job Manager. The REST API (`/wp-json/wp/v2/job-listings`) returns structured JSON with full job descriptions, company names, taxonomy data — no HTML parsing needed.

**Trade-off:** Salary data is not reliably in meta fields (sometimes embedded in `content.rendered` HTML). Location comes from embedded taxonomy terms.

### Data sources per field

| Field | Source | Reliability |
|---|---|---|
| title | `title.rendered` | Stable (WP API) |
| company | `meta._company_name` | Stable |
| url | `link` | Stable |
| description | `content.rendered` (HTML) | Stable |
| source | Hardcoded `"euremotejobs"` | — |
| salary | — | Not reliably available in meta |
| location | `_embedded.wp:term` (regions taxonomy) | Stable |
| remote | Always `true` (EU remote job board) | — |
| publishedAt | `date` (ISO 8601) | Stable |

## Flow

```
Schedule Trigger (15 min)
  → Get Criteria (Execute Workflow)
  → Resolve Tags (build WP tag search URLs per category)
  → Fetch Tags (HTTP Request, batch 1/1s)
  → Build Queries (match tag IDs, deduplicate)
  → Fetch Jobs (HTTP Request, batch 1/2s, per tag)
      ├─ [success] → Parse & Dedup → Send Jobs
      └─ [error] → Format Error → Notify Error
```

- **Get Criteria** handles its own error logging + throws to stop pipeline
- **Send Jobs** handles has-jobs check, success/warn/error logging internally
- EU Remote Jobs Scraper only logs **Fetch Jobs** errors (the only external HTTP call that can fail)

## Node Details

### 1. Schedule Trigger
- Interval: every 15 minutes

### 2. Get Criteria (Execute Workflow)
- Calls shared sub-workflow
- Input: `{source: "euremotejobs"}`
- Output: `[{category: "Kotlin"}, {category: "Java"}, ...]`
- `onError: continueErrorOutput` → pipeline stops if criteria fetch fails

### 3. Resolve Tags
```javascript
const categories = $input.all().map(i => i.json.category);
return categories.map(cat => ({
  json: { category: cat }
}));
```

### 4. Fetch Tags
- HTTP Request node
- GET `https://euremotejobs.com/wp-json/wp/v2/job_listing_tag?search={{ $json.category }}&per_page=5`
- Batching: 1 request / 1s interval
- `onError: continueErrorOutput`

### 5. Build Queries
```javascript
const seen = new Set();
const queries = [];

for (const item of $input.all()) {
  const tags = item.json;
  if (!Array.isArray(tags) || tags.length === 0) continue;

  // Exact match (case-insensitive) with the category
  const category = item.json.category; // from paired input
  const tag = tags.find(t =>
    t.name.toLowerCase() === category?.toLowerCase()
  ) || tags[0];

  if (!seen.has(tag.id)) {
    seen.add(tag.id);
    queries.push({ json: { tagId: tag.id, tagName: tag.name } });
  }
}

return queries;
```

### 6. Fetch Jobs
- HTTP Request node
- GET `https://euremotejobs.com/wp-json/wp/v2/job-listings?per_page=100&page=1&_embed&job_listing_tag={{ $json.tagId }}&orderby=date&order=desc`
- Batching: 1 request / 2s interval
- Timeout: 30s
- `onError: continueErrorOutput`

### 7. Parse & Dedup
```javascript
const source = 'euremotejobs';
const seen = new Set();
const jobs = [];

for (const item of $input.all()) {
  const listings = Array.isArray(item.json) ? item.json : [item.json];

  for (const wp of listings) {
    if (!wp.link || seen.has(wp.link)) continue;
    seen.add(wp.link);

    // Extract location from embedded region terms
    const terms = wp._embedded?.['wp:term'] || [];
    const regions = terms.flat().filter(t =>
      t.taxonomy === 'job_listing_region'
    );
    const location = regions.map(r => r.name).join(', ') || null;

    jobs.push({
      title: wp.title?.rendered || '',
      company: wp.meta?._company_name || null,
      url: wp.link,
      description: wp.content?.rendered || '',
      source,
      salary: null,
      location,
      remote: true,
      publishedAt: wp.date || null,
      rawData: wp
    });
  }
}

return [{ json: { body: jobs, count: jobs.length, source } }];
```

### 8. Send Jobs (Execute Workflow)
- Calls shared sub-workflow
- Handles has-jobs check, POST to API, success/error logging internally
- `onError: continueErrorOutput`

### 9. Format Error
```javascript
const err = $input.first().json;
const source = 'euremotejobs';
const msg = err.error?.message || err.message || JSON.stringify(err).substring(0, 200);
return [{ json: { level: 'error', message: msg, source } }];
```

### 10. Notify Error (Execute Workflow)
- Calls shared Telegram Notify
- `onError: continueRegularOutput`

## WordPress REST API

### Job listings endpoint

```
GET https://euremotejobs.com/wp-json/wp/v2/job-listings
```

| Parameter | Description | Example |
|---|---|---|
| `per_page` | Results per page (max 100) | `100` |
| `page` | Page number | `1` |
| `_embed` | Include taxonomy terms inline | — |
| `job_listing_tag` | Filter by tag ID | `229` (Java) |
| `job-categories` | Filter by category ID | `65` (Engineering) |
| `orderby` | Sort field | `date` |
| `order` | Sort direction | `desc` |

### Tag search endpoint

```
GET https://euremotejobs.com/wp-json/wp/v2/job_listing_tag?search={name}
```

Returns matching tags with `id`, `name`, `slug`, `count`.

### Known tag IDs

| Tag | ID | Count |
|---|---|---|
| Java | 229 | ~150 |
| Kotlin | 543 | ~20 |
| Python | 237 | ~250 |
| Spring | 2677 | ~15 |
| React | 238 | ~200 |

Tag IDs are resolved dynamically at runtime — not hardcoded in the workflow.

## Parsed Fields (JobIngestRequest)

| Field | Source | Example |
|---|---|---|
| title | `title.rendered` | Senior Software Engineer |
| company | `meta._company_name` | Zencargo |
| url | `link` | https://euremotejobs.com/job/senior-software-engineer-12/ |
| description | `content.rendered` | `<p>Zencargo is looking for...</p>` |
| source | Hardcoded | euremotejobs |
| salary | — (not reliably in meta) | null |
| location | `_embedded` region terms | Europe |
| remote | Always true | true |
| publishedAt | `date` | 2026-03-04T11:35:24 |
| category | Matched via WP tag → Build Queries category map | Kotlin |

## API Prerequisite

The Job Hunter API `source` enum currently only supports `["dou", "djinni", "linkedin"]`. Before this scraper can work, the API must be updated to add `"euremotejobs"` to:
- `JobIngestRequest.source` enum
- `SearchCriteriaResponse` / `/criteria` endpoint
- `SearchPreferenceRequest.disabledSources` enum
- All other places where source enum is used

### JobIngestRequest (required fields)

```
POST /jobs/ingest
```

| Field | Required | Type | Source |
|---|---|---|---|
| title | **yes** | string | `title.rendered` |
| url | **yes** | string | `link` |
| description | **yes** | string | `content.rendered` (HTML) |
| source | **yes** | enum | `"euremotejobs"` |
| rawData | **yes** | object | Full WP REST API response object |
| company | no | string | `meta._company_name` |
| salary | no | string | null (not reliably available) |
| location | no | string | `_embedded` region taxonomy terms |
| remote | no | boolean | `true` (all jobs are remote) |
| publishedAt | no | string | `date` field (ISO 8601) |

## Edge Cases

- **Tag search returns no match** — category skipped (no query for it)
- **Tag search returns partial match** — exact name match preferred, falls back to first result
- **Empty API response** — 0 jobs for that tag, Parse & Dedup handles gracefully
- **Rate limiting** — 2s delay between job fetches; no known rate limit on WP REST API
- **Large response** — max 100 jobs per tag; for 15-min polling, page 1 is sufficient
- **HTML in description** — kept as-is (same as LinkedIn), API handles storage

## Performance

| Metric | Estimate |
|---|---|
| Tag resolution requests | 1 per category (~5) |
| Job fetch requests | 1 per matched tag (~5) |
| Jobs per request | up to 100 |
| Total time | ~15-20 seconds |
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
| Job fetch error | `error` | EU Remote Jobs Scraper (Format Error → Notify Error) |
