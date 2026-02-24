# job-hunter-n8n

**TL;DR:** n8n workflows для скрапинга вакансий. Часть системы [job-hunter](https://github.com/mshykhov/job-hunter). Собирает вакансии с DOU, Djinni, Indeed и отправляет в job-hunter-api через REST.

> **Стек**: n8n (Community), PostgreSQL 16, Docker Compose

---

## Руководство для AI

### Принципы работы
- **Workflows — это конфиг, не код.** Редактируются в n8n UI, экспортируются как JSON
- **Не редактировать JSON вручную** — только через n8n UI → export
- **No secrets in code**: API-ключи, токены — только через .env (gitignored) или n8n credentials UI
- **N8N_ENCRYPTION_KEY** — один ключ для всех сред (локалка, прод). Без него credentials не расшифруются
- Документация: **русский**, коммиты: **английский**

### Структура
```
job-hunter-n8n/
├── docker-compose.yml      # Локальная разработка (n8n + PostgreSQL)
├── .env                    # Секреты (gitignored)
├── .env.example            # Шаблон переменных
├── workflows/              # Экспортированные workflow JSON
├── scripts/
│   ├── export.sh           # n8n → Git
│   └── import.sh           # Git → n8n
├── CLAUDE.md
└── README.md
```

### Рабочий цикл
```
1. docker compose up -d
2. Открыть http://localhost:5678
3. Редактировать workflows в UI
4. ./scripts/export.sh
5. git add workflows/ && git commit -m "feat: add dou scraper"
```

### Workflow conventions
- Одна платформа = один workflow (dou-rss-scraper, djinni-scraper, indeed-rss-scraper)
- Каждый workflow отправляет данные POST в job-hunter-api `/api/jobs/ingest`
- Schedule Trigger: каждые 2 часа
- Нормализованный JSON на выходе:
```json
{
  "title": "...",
  "company": "...",
  "url": "...",
  "description": "...",
  "source": "DOU|DJINNI|INDEED",
  "salary": "...",
  "location": "...",
  "remote": true
}
```

### Деплой
- Локально: `docker compose up -d`
- Продакшн: Helm chart в smhomelab/deploy, ArgoCD
- Credentials пересоздаются вручную на каждом инстансе
