# JustJoinIT Scraper

Scrapes senior remote JVM roles from the [JustJoinIT](https://justjoin.it) v2 API
(`GET https://api.justjoin.it/v2/user-panel/offers`, JSON, no auth, requires header
`Version: 2`). Largest EU B2B board for JVM, ФОП/B2B-friendly, multi-currency salary bands,
and an `openToHireUkrainians` signal. Categories drive a client-side skill filter.

**Folder:** Scrapers | **Tags:** `scraper`, `justjoinit`

> **Wire slug:** `justjoinit` — must equal `JobSource.JUSTJOINIT.value`. Not
> separator-insensitive, so `just_join_it` would 400.

## Architecture

Reuses shared sub-workflows: **Get Criteria** (`51QbvQ9rXWCQSL9Y`), **Send Jobs**
(`3JhDuzeLD3FbIOP1`), **Telegram Notify** (`TQShysginOAn9uQs`) — same roles as the other scrapers.

## Data sources per field (verified 2026-07-10)

| Ingest field | JustJoinIT source | Notes |
|---|---|---|
| title | `title` | |
| company | `companyName` | |
| url | `https://justjoin.it/job-offer/${slug}` | verified 200; dedup key |
| description | `""` (list endpoint has no body) | skills captured in rawData |
| source | `"justjoinit"` | hardcoded |
| salary | `employmentTypes[0]` `{from,to,currency,unit}` | e.g. `EUR 4000–6000/month` |
| location | `city` (or `Remote` when `workplaceType==='remote'`) | |
| remote | `workplaceType === 'remote'` | the `workplaceType=remote` query param is IGNORED by the API - non-remote offers are dropped client-side in Parse |
| publishedAt | `publishedAt` (ISO) | |
| **category** | matched from Get Criteria against `title` + `requiredSkills[]` | required |
| rawData | `{ guid, experienceLevel, employmentTypes, openToHireUkrainians, categoryId }` | |

## Flow (9 nodes)

```
Schedule Trigger (15 min)
  → Set Source ({source: "justjoinit"})
  → Get Criteria (Execute Workflow 51QbvQ9rXWCQSL9Y)
  → Build Pages (one item per API page)
  → Fetch Offers (GET v2 offers, header Version: 2, batch 1 req / 2s)
      ├─ [success] → Parse Jobs → Prepare Ingest → Send Jobs
      └─ [error]   → Format Error → Notify Error
```

## Node Details

### 1. Schedule Trigger — every 15 minutes.

### 2. Set Source
```javascript
return [{ json: { source: "justjoinit" } }];
```

### 3. Get Criteria (Execute Workflow `51QbvQ9rXWCQSL9Y`)
- Input `{ source: "justjoinit" }` → `[{ category: "java" }, { category: "kotlin" }, …]`.
- `onError: continueErrorOutput`.

### 4. Build Pages
```javascript
// Page the remote+senior feed. meta.totalPages is available after the first fetch;
// a fixed 3-page cap keeps runtime bounded (perPage=100 → up to 300 offers).
const base = "https://api.justjoin.it/v2/user-panel/offers"
  + "?workplaceType=remote&sortBy=published&orderBy=DESC&perPage=100";
return [1, 2, 3].map((page) => ({ json: { url: `${base}&page=${page}` } }));
```

### 5. Fetch Offers
- HTTP Request, `GET {{ $json.url }}`, Response format: **JSON**.
- Headers: `Version: 2` **and** a browser `User-Agent` (as in the other scrapers).
- Batching: 1 request / 2s. `onError: continueErrorOutput`.

### 6. Parse Jobs
```javascript
const source = $('Set Source').first().json.source;
const categories = $('Get Criteria').all().map((i) => i.json.category.toLowerCase());

const out = [];
for (const item of $input.all()) {
  const offers = item.json?.data || [];
  for (const o of offers) {
    if (o.experienceLevel && o.experienceLevel !== "senior" && o.experienceLevel !== "c-level") continue;
    // API ignores the workplaceType query param - enforce remote here
    if (o.workplaceType !== "remote") continue;

    // match a tracked category against title + required skills
    const skills = (o.requiredSkills || []).map((s) => String(s?.name || s).toLowerCase());
    const haystack = `${(o.title || "").toLowerCase()} ${skills.join(" ")}`;
    const category = categories.find((c) => haystack.includes(c));
    if (!category) continue;

    const et = (o.employmentTypes || [])[0];
    let salary = null;
    if (et && (et.from || et.to)) {
      const cur = (et.currency || "").toUpperCase();
      const unit = et.unit || "month";
      if (et.from && et.to) salary = `${cur} ${et.from}–${et.to}/${unit}`;
      else if (et.to) salary = `${cur} up to ${et.to}/${unit}`;
      else salary = `${cur} from ${et.from}/${unit}`;
    }

    out.push({
      json: {
        title: o.title || "",
        company: o.companyName || null,
        url: `https://justjoin.it/job-offer/${o.slug}`,
        description: "",
        source,
        salary,
        location: o.workplaceType === "remote" ? "Remote" : (o.city || null),
        remote: o.workplaceType === "remote",
        publishedAt: o.publishedAt || o.lastPublishedAt || null,
        category,
        rawData: {
          guid: o.guid,
          experienceLevel: o.experienceLevel,
          employmentTypes: o.employmentTypes,
          openToHireUkrainians: o.openToHireUkrainians,
          categoryId: o.categoryId,
        },
      },
    });
  }
}
return out;
```

### 7. Prepare Ingest
```javascript
const jobs = $input.all().map((i) => i.json);
return [{ json: { body: jobs, count: jobs.length, source: "justjoinit" } }];
```

### 8. Send Jobs (Execute Workflow `3JhDuzeLD3FbIOP1`) — `onError: continueErrorOutput`.

### 9. Format Error → Notify Error (Execute Workflow `TQShysginOAn9uQs`)
```javascript
const err = $input.first().json;
return [{ json: { level: "error", message: `${$workflow.name}: ${err.error || err.message || "Unknown error"}` } }];
```

## Notes

- **`Version: 2` header is mandatory.** The legacy `justjoin.it/api/offers` endpoint is dead (404);
  only `api.justjoin.it/v2/user-panel/offers` works.
- **`workplaceType=remote` query param does nothing** (verified 2026-07-10: the filtered feed still
  returns hybrid/office offers). The remote gate is the client-side check in Parse Jobs.
- **openToHireUkrainians** is captured in `rawData` (not a filter) — useful later for ranking; do
  not hard-filter on it, most remote offers still hire from UA.
- **No description on the list endpoint.** If richer text is needed, add an optional enrichment
  fetch of the offer detail endpoint; not required for matching (skills live in rawData).
- **category is mandatory** on every job; offers with no skill match to a tracked category are dropped.
