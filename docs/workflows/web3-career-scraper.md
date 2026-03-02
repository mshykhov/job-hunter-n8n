# Web3.career Scraper

Scrapes job listings from web3.career listing pages. Uses JSON-LD structured data (`schema.org/JobPosting`) embedded in category pages — all fields (title, company, salary, description, location) available in a single GET request. Categories are fetched dynamically from the API.

**Folder:** Scrapers | **Tags:** `scraper`, `web3_career`

## Architecture

Uses 3 shared sub-workflows (folder: Shared, tag: `shared`):

| Sub-workflow | Purpose |
|---|---|
| **Get Criteria** | `GET /criteria?source={source}` — returns categories. Logs errors to Telegram, throws on failure. |
| **Send Jobs** | Checks count, `POST /jobs/ingest`, logs success/warn/error to Telegram. |
| **Telegram Notify** | Routes `{level, message}` to Telegram forum topics (error/warn → alerts, info → logs). |

## Data Strategy

### Why listing pages?

| Approach | Jobs/request | Company | Location | Salary | Description | Speed |
|---|---|---|---|---|---|---|
| **Listing pages** (chosen) | ~16 | ✓ | ✓ | ✓ | ✓ | Fast (~15s) |

Web3.career listing pages (`/{category}-jobs`) contain **16 separate JSON-LD blocks**, each a complete `JobPosting` with `hiringOrganization`, `baseSalary`, `description`, `jobLocation`, `datePosted`. No enrichment phase needed — all data is in a single GET request.

**No trade-offs:** salary, description, and location are all available on listing pages.

### Data sources per field

| Field | Source | Reliability |
|---|---|---|
| title | JSON-LD `title` | Stable (structured data) |
| company | JSON-LD `hiringOrganization.name` | Stable |
| url | HTML `<a href="/{slug}/{id}">` | Stable (regex) |
| description | JSON-LD `description` | Stable |
| source | Hardcoded `"web3_career"` | — |
| salary | JSON-LD `baseSalary.value.minValue`/`maxValue` + `currency` | Stable |
| location | JSON-LD `jobLocation.address.addressLocality` + `addressCountry` | Stable |
| remote | JSON-LD `jobLocationType === "TELECOMMUTE"` | Stable |
| publishedAt | JSON-LD `datePosted` | Stable |

## Flow (10 nodes)

```
Schedule Trigger (15 min)
  → Set Source ({source: "web3_career"})
  → Get Criteria (Execute Workflow)
  → Build Page URLs
  → Fetch Pages (batch 1 req / 3s, browser UA)
      ├─ [success] → Parse Jobs (JSON-LD) → Prepare Ingest → Send Jobs (Execute Workflow)
      └─ [error] → Format Error → Notify Error (Telegram)
```

- **Get Criteria** handles its own error logging + throws to stop pipeline
- **Send Jobs** handles has-jobs check, success/warn/error logging internally
- Web3.career Scraper only logs **Fetch Pages** errors (the only direct HTTP call)

## Node Details

### 1. Schedule Trigger
- Interval: every 15 minutes

### 2. Set Source
```javascript
return [{json: {source: 'web3_career'}}];
```

### 3. Get Criteria (Execute Workflow)
- Calls shared sub-workflow `51QbvQ9rXWCQSL9Y`
- Input: `{source: "web3_career"}`
- Output: `[{category: "backend"}, {category: "solidity"}, ...]`
- `onError: continueErrorOutput` → pipeline stops if criteria fetch fails

### 4. Build Page URLs
```javascript
return $input.all().map(item => ({
  json: {
    category: item.json.category,
    url: `https://web3.career/${encodeURIComponent(item.json.category)}-jobs`
  }
}));
```

### 5. Fetch Pages
- HTTP Request node
- URL: `={{ $json.url }}`
- Response format: **text** (HTML)
- Batching: 1 request / 3s interval
- Headers: `User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36`
- `onError: continueErrorOutput`

### 6. Parse Jobs
Extracts JSON-LD blocks and job URLs from page HTML:
```javascript
const source = $('Set Source').first().json.source;
const allJobs = [];

for (const inputItem of $input.all()) {
  const html = inputItem.json.data;
  if (!html || typeof html !== 'string') continue;

  // 1. Extract all JSON-LD blocks from page (one per job, not an array)
  const jsonLdPattern = /<script type="application\/ld\+json">([\s\S]*?)<\/script>/g;
  const jobPostings = [];
  let jsonLdMatch;
  while ((jsonLdMatch = jsonLdPattern.exec(html)) !== null) {
    try {
      const parsed = JSON.parse(jsonLdMatch[1]);
      if (parsed['@type'] === 'JobPosting') {
        jobPostings.push(parsed);
      }
    } catch (e) { continue; }
  }
  if (jobPostings.length === 0) continue;

  // 2. Extract job URLs from HTML <a> links
  //    Pattern: href="/backend-engineer-layerzerolabs/73714"
  const urlPattern = /href="(\/[a-z0-9-]+-[a-z0-9-]+\/(\d+))"/g;
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

  // 3. Build job records — match JSON-LD entries to URLs by position
  for (let i = 0; i < jobPostings.length; i++) {
    const posting = jobPostings[i];

    const jobUrl = i < urlList.length
      ? `https://web3.career${urlList[i]}`
      : null;

    // Build location from jobLocation.address
    const addr = posting.jobLocation?.address;
    let location = null;
    if (addr) {
      const parts = [addr.addressLocality, addr.addressCountry].filter(Boolean);
      location = parts.length > 0 ? parts.join(', ') : null;
    }

    // Build salary string from baseSalary
    let salary = null;
    const base = posting.baseSalary?.value;
    if (base && (base.minValue || base.maxValue)) {
      const currency = posting.baseSalary.currency || 'USD';
      if (base.minValue && base.maxValue) {
        salary = `${currency} ${Math.round(base.minValue)}–${Math.round(base.maxValue)}/yr`;
      } else if (base.maxValue) {
        salary = `${currency} up to ${Math.round(base.maxValue)}/yr`;
      } else {
        salary = `${currency} from ${Math.round(base.minValue)}/yr`;
      }
    }

    // Parse datePosted: "2026-02-24 18:53:32 +0000" → ISO
    let publishedAt = null;
    if (posting.datePosted) {
      const cleaned = posting.datePosted.replace(' +0000', 'Z').replace(' ', 'T');
      publishedAt = cleaned;
    }

    allJobs.push({
      json: {
        title: posting.title || '',
        company: posting.hiringOrganization?.name || null,
        url: jobUrl,
        description: posting.description || '',
        source,
        salary,
        location,
        remote: posting.jobLocationType === 'TELECOMMUTE',
        publishedAt
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

## Category Page URL

```
https://web3.career/{category}-jobs
```

Categories come from the API dynamically (`GET /criteria?source=web3_career`).

Expected categories and their URLs:

| Category | URL |
|---|---|
| `backend` | `https://web3.career/backend-jobs` |
| `frontend` | `https://web3.career/frontend-jobs` |
| `solidity` | `https://web3.career/solidity-jobs` |
| `ai` | `https://web3.career/ai-jobs` |
| `devops` | `https://web3.career/devops-jobs` |
| `rust` | `https://web3.career/rust-jobs` |
| `security` | `https://web3.career/security-jobs` |

Available query parameters (can be added later):
- `?page={N}` — pagination (16 jobs per page); page 1 = base URL (`?page=1` redirects)

## JSON-LD on Category Page

Each category page contains **16 separate `<script type="application/ld+json">` blocks** (not an array), each a complete `JobPosting`:

```json
{
  "@context": "https://schema.org",
  "@type": "JobPosting",
  "datePosted": "2026-02-24 18:53:32 +0000",
  "description": "LayerZero The Future is Omnichain. Founded in 2021...",
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
  "employmentType": "Full-time",
  "industry": "Startups",
  "jobLocationType": "TELECOMMUTE",
  "applicantLocationRequirements": {
    "@type": "Country",
    "name": "Anywhere"
  },
  "jobLocation": {
    "address": {
      "@type": "PostalAddress",
      "addressCountry": "Canada",
      "addressLocality": "Vancouver",
      "addressRegion": "",
      "streetAddress": "",
      "postalCode": ""
    }
  },
  "title": "Backend Engineer",
  "image": "",
  "occupationalCategory": "",
  "workHours": "Flexible",
  "validThrough": "2026-05-25 18:53:32 +0100",
  "hiringOrganization": {
    "@type": "Organization",
    "name": "Layerzerolabs",
    "logo": ""
  }
}
```

**Key differences from Djinni JSON-LD:**
- **16 separate `<script>` blocks** vs Djinni's single `<script>` with an array
- **`baseSalary` included** — with minValue, maxValue, currency
- **`jobLocation` included** — full address with country and city
- **`applicantLocationRequirements`** — geographic requirements
- **`datePosted` format** — `"YYYY-MM-DD HH:MM:SS +0000"` (not ISO 8601)

## Parsed Fields (JobIngestRequest)

| Field | Source | Example |
|---|---|---|
| title | JSON-LD `title` | Backend Engineer |
| company | JSON-LD `hiringOrganization.name` | Layerzerolabs |
| url | HTML `<a href>` | https://web3.career/backend-engineer-layerzerolabs/73714 |
| description | JSON-LD `description` | LayerZero The Future is Omnichain... |
| source | Hardcoded | web3_career |
| salary | JSON-LD `baseSalary` | USD 135000–250000/yr |
| location | JSON-LD `jobLocation.address` | Vancouver, Canada |
| remote | JSON-LD `jobLocationType` | true |
| publishedAt | JSON-LD `datePosted` | 2026-02-24T18:53:32Z |

## Differences from Djinni Scraper

| Aspect | Djinni | Web3.career |
|---|---|---|
| Data source | Listing page HTML + JSON-LD array | Category page, 16 separate JSON-LD blocks |
| URL param | `primary_keyword={category}` | `{category}-jobs` (path segment) |
| Company | JSON-LD `hiringOrganization.name` | JSON-LD `hiringOrganization.name` |
| Salary | Not available | JSON-LD `baseSalary` (minValue/maxValue + currency) |
| Location | HTML card metadata | JSON-LD `jobLocation.address` |
| Remote | JSON-LD `jobLocationType` | JSON-LD `jobLocationType` |
| Description | JSON-LD `description` | JSON-LD `description` |
| User-Agent | Default UA works | Browser UA recommended |
| Request interval | 1s | 3s (conservative for Cloudflare) |
| Proxies | Not needed | Not needed |
| Nodes | 10 | 10 |
| Speed | ~10-15s | ~15-20s (slower due to 3s interval) |

## Environment Variables

Same as DOU/Djinni — no additional env vars needed:

| Variable | Purpose |
|---|---|
| `JOB_HUNTER_API_URL` | API base URL (e.g., `http://host.docker.internal:8095`) |
| `TELEGRAM_CHAT_ID` | Telegram group chat ID |
| `TELEGRAM_LOG_TOPIC_ID` | Forum topic ID for info logs |
| `TELEGRAM_ALERT_TOPIC_ID` | Forum topic ID for errors/warnings |

## Edge Cases

1. **No JSON-LD blocks** — page has no jobs for this category, Parse Jobs skips it
2. **URL count mismatch** — if JSON-LD blocks ≠ HTML links, unmatched entries get url = null
3. **Missing baseSalary** — not all jobs have salary data, salary = null for those
4. **Empty address fields** — `addressLocality` or `addressCountry` may be empty strings, filtered out when building location
5. **datePosted format** — `"YYYY-MM-DD HH:MM:SS +0000"` is non-standard, Parse Jobs converts to ISO 8601
6. **Cloudflare Turnstile** — configured with `render=explicit`, doesn't block normal GET requests; browser User-Agent header recommended as precaution
7. **Page 1 redirect** — `?page=1` redirects to base URL; always use base URL for first page
8. **Large description** — JSON-LD `description` contains full job text (can be lengthy), sent as-is

## Performance

| Metric | Estimate |
|---|---|
| Requests per category | 1 (page 1 only) |
| Jobs per request | ~16 |
| Total (5 categories) | 5 requests, ~80 jobs |
| Total time | ~15-20 seconds |
| Schedule interval | 15 minutes |

## Pagination (Future Enhancement)

Page 1 returns ~16 most recent jobs per category. For full coverage:

```
https://web3.career/backend-jobs         → 16 jobs (page 1)
https://web3.career/backend-jobs?page=2  → 16 jobs
...
```

The site reports 2,240+ total jobs. To add pagination:
1. Modify Build Page URLs to generate URLs for pages 1..N
2. Extract total job count or page count from HTML
3. Or use n8n HTTP Request built-in pagination (Options → Pagination)

Not needed for MVP — page 1 captures recent postings, and the 15-min schedule ensures we don't miss new jobs.

## Observability

| Event | Level | Source |
|---|---|---|
| Jobs sent to API | `info` | Send Jobs sub-workflow |
| No jobs found | `warn` | Send Jobs sub-workflow |
| API error (criteria) | `error` | Get Criteria sub-workflow |
| API error (ingest) | `error` | Send Jobs sub-workflow |
| Page fetch error | `error` | Web3.career Scraper (Format Error → Notify Error) |
| Workflow crash | — | n8n Executions tab |
