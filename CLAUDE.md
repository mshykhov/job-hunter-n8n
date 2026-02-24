# job-hunter-n8n

**TL;DR:** n8n workflows для скрапинга вакансий. Часть системы [job-hunter](https://github.com/mshykhov/job-hunter). Собирает вакансии с DOU, Djinni, Indeed и отправляет в job-hunter-api через REST.

> **Стек**: n8n 2.10 (Community), PostgreSQL 16, Docker Compose

---

## Portfolio Project

**Публичный репозиторий.** Всё должно быть чисто и профессионально.

### Требования
- **README, коммиты** — на английском
- **Осмысленные коммиты** — conventional commits
- **Без мусора** — никаких тестовых/временных workflows в master
- **Без упоминаний AI** в коммитах
- **CLAUDE.md** — единственный файл на русском

---

## Руководство для AI

### Принципы работы
- **Workflows — это конфиг, не код.** Редактируются в n8n UI, экспортируются как JSON
- **Не редактировать JSON вручную** — только через n8n UI → export
- **No secrets in code**: API-ключи, токены — только через .env (gitignored) или n8n credentials UI
- **N8N_ENCRYPTION_KEY** — один ключ для всех сред. Без него credentials не расшифруются

### Структура
```
job-hunter-n8n/
├── docker-compose.yml      # n8n + PostgreSQL (local dev)
├── .env                    # Secrets (gitignored)
├── .env.example
├── workflows/              # Exported workflow JSONs
├── scripts/
│   ├── export.sh           # n8n → Git
│   └── import.sh           # Git → n8n
├── CLAUDE.md
└── README.md
```

### Рабочий цикл
```
1. docker compose up -d
2. http://localhost:5678
3. Редактировать workflows в UI
4. ./scripts/export.sh
5. git add workflows/ && git commit -m "feat: add dou scraper"
```

### Workflow conventions
- Одна платформа = один workflow
- Каждый workflow отправляет POST в job-hunter-api `/api/jobs/ingest`
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
