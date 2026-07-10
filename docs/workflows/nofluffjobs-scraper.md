# NoFluffJobs Scraper

Scrapes senior backend roles from the [NoFluffJobs](https://nofluffjobs.com) search API
(`POST /api/search/posting`, JSON). CEE B2B board with **mandatory salary disclosure**, a
`fullyRemote` flag, and a `help4Ua` (UA-eligible) signal. The `backend` category returns all
backend stacks, so a client-side `technology` filter keeps only JVM roles matching the user's
tracked categories.

**Folder:** Scrapers | **Tags:** `scraper`, `nofluffjobs`

> **Wire slug:** `nofluffjobs` - must equal `JobSource.NOFLUFFJOBS.value`.

## Architecture

Reuses shared sub-workflows: **Get Criteria** (`51QbvQ9rXWCQSL9Y`), **Send Jobs**
(`3JhDuzeLD3FbIOP1`), **Telegram Notify** (`TQShysginOAn9uQs`).

## Data sources per field (verified 2026-07-10)

| Ingest field | NoFluffJobs source | Notes |
|---|---|---|
| title | `title` | |
| company | `name` | |
| url | `https://nofluffjobs.com/job/${url}` | verified 200; dedup key |
| description | `""` (search list has no body) | tech captured in rawData |
| source | `"nofluffjobs"` | hardcoded |
| salary | `salary` `{from,to,currency,type}` | always present (`disclosedAt: VISIBLE`) |
| location | `location.places[].city` excluding the `"Remote"` placeholder city (or `Remote` when fully remote) | |
| remote | `location.fullyRemote` (boolean) | top-level `fullyRemote` is always `false` - the real flag is nested |
| publishedAt | `posted` (epoch ms) → ISO | |
| **category** | matched from Get Criteria against `technology` + `tiles[]` | required |
| rawData | `{ id, technology, seniority, help4Ua, salary }` | |

## Request contract (verified)

```
POST https://nofluffjobs.com/api/search/posting?region=pl&page={N}&salaryCurrency=PLN&salaryPeriod=month&language=en
Content-Type: application/json

{ "criteriaSearch": { "category": ["backend"], "seniority": ["senior"] }, "page": {N} }
```
Response: `{ postings: [...], totalPages, totalCount, ... }`. The query params (`salaryCurrency`,
`salaryPeriod`, `language`) are required - omitting them returns an RFC-7807 error, not results.

## Flow (9 nodes)

```
Schedule Trigger (15 min)
  → Set Source ({source: "nofluffjobs"})
  → Get Criteria (Execute Workflow 51QbvQ9rXWCQSL9Y)
  → Build Pages (one item per page, with POST body)
  → Fetch Postings (POST search, batch 1 req / 2s)
      ├─ [success] → Parse Jobs → Prepare Ingest → Send Jobs
      └─ [error]   → Format Error → Notify Error
```

## Node Details

### 1. Schedule Trigger - every 15 minutes.

### 2. Set Source
```javascript
return [{ json: { source: "nofluffjobs" } }];
```

### 3. Get Criteria (Execute Workflow `51QbvQ9rXWCQSL9Y`)
- Input `{ source: "nofluffjobs" }` → tracked categories. `onError: continueErrorOutput`.

### 4. Build Pages
```javascript
const body = { criteriaSearch: { category: ["backend"], seniority: ["senior"] } };
return [1, 2, 3].map((page) => ({
  json: {
    url: `https://nofluffjobs.com/api/search/posting?region=pl&page=${page}&salaryCurrency=PLN&salaryPeriod=month&language=en`,
    body: { ...body, page },
  },
}));
```

### 5. Fetch Postings
- HTTP Request, **POST** `{{ $json.url }}`.
- Body: JSON, `{{ $json.body }}`. Content-Type: `application/json`. Browser `User-Agent`.
- Response format: **JSON**. Batching: 1 request / 2s. `onError: continueErrorOutput`.

### 6. Parse Jobs
```javascript
const source = $('Set Source').first().json.source;
const categories = $('Get Criteria').all().map((i) => i.json.category.toLowerCase());

const out = [];
const seenRemote = new Set();
for (const item of $input.all()) {
  const postings = item.json?.postings || [];
  for (const p of postings) {
    // match a tracked category against the primary technology + requirement tiles
    const tiles = (p.tiles?.values || []).map((t) => String(t.value).toLowerCase());
    const haystack = `${(p.technology || "").toLowerCase()} ${tiles.join(" ")}`;
    const category = categories.find((c) => haystack.includes(c));
    if (!category) continue;

    const s = p.salary;
    let salary = null;
    if (s && (s.from || s.to)) {
      const cur = (s.currency || "").toUpperCase();
      const type = s.type ? ` (${s.type})` : "";
      if (s.from && s.to) salary = `${cur} ${Math.round(s.from)}–${Math.round(s.to)}/month${type}`;
      else if (s.to) salary = `${cur} up to ${Math.round(s.to)}/month${type}`;
      else salary = `${cur} from ${Math.round(s.from)}/month${type}`;
    }

    const fullyRemote = !!p.location?.fullyRemote;
    // NFJ duplicates a fully-remote posting once per voivodeship - keep one
    if (fullyRemote) {
      const key = `${(p.title || "").toLowerCase()}|${(p.name || "").toLowerCase()}`;
      if (seenRemote.has(key)) continue;
      seenRemote.add(key);
    }
    const cities = (p.location?.places || []).map((pl) => pl.city).filter((c) => c && c !== "Remote");
    const location = fullyRemote ? "Remote" : (cities.join(", ") || null);

    out.push({
      json: {
        title: p.title || "",
        company: p.name || null,
        url: `https://nofluffjobs.com/job/${p.url}`,
        description: "",
        source,
        salary,
        location,
        remote: fullyRemote,
        publishedAt: p.posted ? new Date(p.posted).toISOString() : null,
        category,
        rawData: { id: p.id, technology: p.technology, seniority: p.seniority, help4Ua: p.help4Ua, salary: p.salary },
      },
    });
  }
}
return out;
```

### 7. Prepare Ingest
```javascript
const jobs = $input.all().map((i) => i.json);
return [{ json: { body: jobs, count: jobs.length, source: "nofluffjobs" } }];
```

### 8. Send Jobs (Execute Workflow `3JhDuzeLD3FbIOP1`) - `onError: continueErrorOutput`.

### 9. Format Error → Notify Error (Execute Workflow `TQShysginOAn9uQs`)
```javascript
const err = $input.first().json;
return [{ json: { level: "error", message: `${$workflow.name}: ${err.error || err.message || "Unknown error"}` } }];
```

## Notes

- **POST, not GET** - an n8n HTTP Request node handles this; a plain fetch of the page HTML will not.
- **Salary is always disclosed** on this board, which makes it high-signal for score/ranking.
- **help4Ua** is captured in `rawData` for later ranking - do not hard-filter on it.
- **`region=pl`** returns CEE + remote-EU roles; `location.fullyRemote` is the remote gate.
- **category is mandatory** on every job; postings whose technology/tiles do not match a tracked
  category (e.g. PHP, .NET) are dropped.
- **Fully-remote postings are duplicated per voivodeship** (verified 2026-07-10: the same offer
  appears with `-lower-silesian`, `-masovian`, … slug suffixes, one per region). Parse keeps the
  first variant per `title|company` when `fullyRemote` - non-remote postings are not deduped, since
  same-title offers in different cities are distinct.
