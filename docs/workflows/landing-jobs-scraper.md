# Landing.jobs Scraper

Scrapes remote backend roles from the [Landing.jobs](https://landing.jobs) public REST API
(`GET /api/v1/jobs`, JSON, no auth). Pan-European, remote-first board with strong senior
Java/Spring volume and EUR salary bands. Categories are fetched dynamically from the API and
used to keep only jobs whose skill tags match the user's tracked categories (e.g. `java`,
`kotlin`).

**Folder:** Scrapers | **Tags:** `scraper`, `landingjobs`

> **Wire slug:** `landingjobs` — must equal `JobSource.LANDINGJOBS.value` exactly. The API's
> `fromValue` is case-insensitive but NOT separator-insensitive, so `landing_jobs` would 400.

## Architecture

Reuses the shared sub-workflows (folder: Shared, tag: `shared`):

| Sub-workflow | ID | Purpose |
|---|---|---|
| **Get Criteria** | `51QbvQ9rXWCQSL9Y` | `GET /criteria?source=landingjobs` — returns tracked categories. Logs errors, throws on failure. |
| **Send Jobs** | `3JhDuzeLD3FbIOP1` | has-jobs check, `POST /jobs/ingest`, success/warn/error Telegram logging. |
| **Telegram Notify** | `TQShysginOAn9uQs` | routes `{level, message}` to Telegram topics. |

## Data sources per field (verified 2026-07-10)

| Ingest field | Landing.jobs source | Notes |
|---|---|---|
| title | `title` | |
| company | parsed from `url` path `/at/{company}/…` | API does not expose company name directly |
| url | `url` | dedup key (server dedups by url) |
| description | `role_description` + `main_requirements`, HTML stripped | |
| source | `"landingjobs"` | hardcoded |
| salary | `gross_salary_low` / `gross_salary_high` + `currency_code` | e.g. `EUR 45000–60000` |
| location | `locations[]` objects (`{city, country_code}`) mapped to city names, or `Remote` when `remote` | |
| remote | `remote` (boolean) | |
| publishedAt | `published_at` (ISO) | |
| **category** | matched from Get Criteria against `tags[]` | **required by ingest DTO** |
| rawData | `{ id, tags, type }` | |

## Flow (9 nodes)

```
Schedule Trigger (15 min)
  → Set Source ({source: "landingjobs"})
  → Get Criteria (Execute Workflow 51QbvQ9rXWCQSL9Y)
  → Build Request (single item; categories collected for Parse)
  → Fetch Jobs (GET /api/v1/jobs, browser UA)
      ├─ [success] → Parse Jobs → Prepare Ingest → Send Jobs (Execute Workflow 3JhDuzeLD3FbIOP1)
      └─ [error]   → Format Error → Notify Error (Execute Workflow TQShysginOAn9uQs)
```

## Node Details

### 1. Schedule Trigger
- Interval: every 15 minutes.

### 2. Set Source
```javascript
return [{ json: { source: "landingjobs" } }];
```

### 3. Get Criteria (Execute Workflow `51QbvQ9rXWCQSL9Y`)
- Input: `{ source: "landingjobs" }`
- Output: `[{ category: "java" }, { category: "kotlin" }, …]`
- `onError: continueErrorOutput` (pipeline stops if criteria fetch fails).

### 4. Build Request
Landing.jobs returns all open jobs in one array; we fetch once and filter by tags in Parse.
```javascript
// one fetch item; categories are read back from the Get Criteria node inside Parse
return [{ json: { url: "https://landing.jobs/api/v1/jobs?limit=200" } }];
```

### 5. Fetch Jobs
- HTTP Request, `GET {{ $json.url }}`, Response format: **JSON**.
- Header: `User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36`
- Batching: 1 request / 2s.
- `onError: continueErrorOutput`.

### 6. Parse Jobs
```javascript
const source = $('Set Source').first().json.source;
const categories = $('Get Criteria').all().map((i) => i.json.category.toLowerCase());

const stripHtml = (s) => (s || "").replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();
const companyFromUrl = (url) => {
  const m = (url || "").match(/landing\.jobs\/at\/([^/]+)\//);
  return m ? m[1].replace(/-/g, " ") : null;
};

const rows = $input.first().json; // array of job objects
const out = [];

for (const job of Array.isArray(rows) ? rows : []) {
  // keep only jobs whose skill tags intersect a tracked category
  const tags = (job.tags || []).map((t) => String(t).toLowerCase());
  const category = categories.find((c) => tags.some((t) => t.includes(c)));
  if (!category) continue;

  const cur = job.currency_code || "EUR";
  const lo = job.gross_salary_low;
  const hi = job.gross_salary_high;
  let salary = null;
  if (lo && hi) salary = `${cur} ${lo}–${hi}`;
  else if (hi) salary = `${cur} up to ${hi}`;
  else if (lo) salary = `${cur} from ${lo}`;

  const location = job.remote
    ? "Remote"
    : (job.locations || []).map((l) => l.city || l.country_code).filter(Boolean).join(", ") || null;

  out.push({
    json: {
      title: job.title || "",
      company: companyFromUrl(job.url),
      url: job.url,
      description: stripHtml(job.role_description) + "\n\n" + stripHtml(job.main_requirements),
      source,
      salary,
      location,
      remote: !!job.remote,
      publishedAt: job.published_at || null,
      category,
      rawData: { id: job.id, tags: job.tags, type: job.type },
    },
  });
}

return out;
```

### 7. Prepare Ingest
```javascript
const jobs = $input.all().map((i) => i.json);
return [{ json: { body: jobs, count: jobs.length, source: "landingjobs" } }];
```

### 8. Send Jobs (Execute Workflow `3JhDuzeLD3FbIOP1`)
- `onError: continueErrorOutput`.

### 9. Format Error → Notify Error
```javascript
const err = $input.first().json;
return [{ json: { level: "error", message: `${$workflow.name}: ${err.error || err.message || "Unknown error"}` } }];
```
- Notify Error → Execute Workflow `TQShysginOAn9uQs`, `onError: continueRegularOutput`.

## Notes

- **Pagination:** the API accepts `?limit=`; add `?offset=` pages in Build Request if 200 is not
  enough. Volume is modest, so a single page is usually sufficient.
- **Geo:** Landing.jobs is pan-EU and remote-first; no US-authorization filter is needed. When
  `remote` is false the role is on-site in an EU city — kept only if you want relocation leads,
  otherwise add `if (!job.remote) continue;` to Parse.
- **category is mandatory** on every ingested job (`JobIngestRequest.category`, no default). Jobs
  with no tag match to a tracked category are dropped rather than sent without one.
