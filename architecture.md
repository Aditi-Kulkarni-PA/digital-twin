# Digital Twin — AWS Architecture Reference
*Covers Week 2, Day 2 (initial AWS deployment) and Day 3 (AWS Bedrock migration)*

This is the "remember everything" doc. If you forget how the pieces fit together or what to click where, start here.

---

## 0. Your Deployed Resources (this project, fill in as you provision more)

| Resource | Value |
|---|---|
| AWS Account ID | `167769273848` |
| Region | `ap-south-2` |
| Frontend bucket (ARN) | `arn:aws:s3:::twin-frontend-167769273848` |
| Frontend S3 static website endpoint | `http://twin-frontend-167769273848.s3-website.ap-south-2.amazonaws.com` |

Note: this region is `ap-south-2`, not the `us-east-1` used in the walkthrough examples throughout this doc — wherever you see `us-east-1` below, substitute your actual region. Bedrock's region doesn't have to match the rest of your stack (see §6), but Lambda, S3, API Gateway, and CloudFront's origin should all agree on `ap-south-2` for this project.

---

## 1. The One-Line Mental Model

> **Browser → CloudFront → S3 (frontend) → API Gateway → Lambda (backend) → Bedrock (brain) + S3 (memory)**

Six hops. If something breaks, walk the chain hop by hop.

---

## 2. Architecture Diagram (Day 3 — current end state)

```
                              ┌─────────────────────┐
                              │      Your Browser    │
                              └──────────┬───────────┘
                                         │ HTTPS
                                         ▼
                        ┌────────────────────────────────┐
                        │   CloudFront (CDN)               │
                        │   - Global HTTPS endpoint         │
                        │   - Caches static frontend        │
                        │   - Origin protocol: HTTP only    │
                        └───────────────┬────────────────┘
                                         │ HTTP (origin fetch)
                                         ▼
                        ┌────────────────────────────────┐
                        │  S3 — Frontend Bucket             │
                        │  twin-frontend-[suffix]           │
                        │  - Static website hosting ON      │
                        │  - Public read policy              │
                        │  - Serves Next.js static export    │
                        └────────────────────────────────┘
                                         │
                          (frontend JS calls the API directly,
                           not through CloudFront)
                                         │ HTTPS fetch('/chat')
                                         ▼
                        ┌────────────────────────────────┐
                        │   API Gateway (HTTP API)          │
                        │   twin-api-gateway                │
                        │   Routes: GET /, GET /health,     │
                        │   POST /chat, ANY /{proxy+},      │
                        │   OPTIONS /{proxy+} (CORS)        │
                        └───────────────┬────────────────┘
                                         │ Lambda proxy integration
                                         ▼
                        ┌────────────────────────────────┐
                        │   Lambda — twin-api                │
                        │   Runtime: Python 3.12 / x86_64   │
                        │   Handler: lambda_handler.handler │
                        │   Framework: FastAPI + Mangum      │
                        │   Timeout: 30s                     │
                        └───────┬─────────────────┬────────┘
                                │                  │
                    ┌───────────▼──────────┐ ┌─────▼─────────────────┐
                    │  AWS Bedrock            │ │  S3 — Memory Bucket    │
                    │  bedrock-runtime client │ │  twin-memory-[suffix]  │
                    │  Model: global.amazon.  │ │  One JSON file per     │
                    │  nova-2-lite-v1:0       │ │  session_id            │
                    │  (the "brain")          │ │  (conversation history)│
                    └─────────────────────────┘ └────────────────────────┘

    Monitoring/observability (side channel, not in the request path):
    CloudWatch Logs  ← Lambda invocations, errors, duration
    CloudWatch Metrics ← Bedrock InvocationLatency, Invocations, tokens
    AWS Budgets ← billing alert (e.g. $10/month threshold)
```

**Day 2 vs Day 3 — the only thing that changes:**

| | Day 2 (initial deploy) | Day 3 (this week's upgrade) |
|---|---|---|
| AI brain | OpenAI API (`openai` package, `gpt-4o-mini`) | AWS Bedrock (`boto3`, Nova models) |
| Backend calls out to | `api.openai.com` (external) | `bedrock-runtime` (stays inside AWS) |
| Secret needed | `OPENAI_API_KEY` | none — uses Lambda's IAM role |
| requirements.txt | includes `openai` | `openai` removed |

Everything else (CloudFront, S3 frontend, S3 memory, API Gateway, Lambda shell) is identical — Day 3 only swaps out the AI call inside `server.py`.

---

## 3. Request & Data Flow (step-by-step)

This is what happens for a single chat message, in order:

1. **User types a message** in the browser at your CloudFront URL (`https://xxxx.cloudfront.net`).
2. **CloudFront** serves the already-cached static frontend (HTML/JS/CSS) from the S3 frontend bucket. The frontend page itself is now loaded in the browser.
3. **Browser JS calls the API directly**: `fetch('https://YOUR-API-ID.execute-api.<region>.amazonaws.com/chat', {...})` — this call goes to **API Gateway**, not through CloudFront.
4. **API Gateway** matches the route (`POST /chat`), applies CORS headers, and invokes **Lambda** (`twin-api`) via proxy integration.
5. **Lambda cold/warm starts**, `lambda_handler.py` hands the event to **Mangum**, which translates it into a FastAPI request hitting the `/chat` endpoint in `server.py`.
6. **Lambda loads conversation history** for the `session_id` from the **S3 memory bucket** (`get_object`) — or starts a new empty list if none exists yet.
7. **Lambda builds the prompt** using `context.py` (which pulls from `facts.json`, `summary.txt`, `style.txt`, `linkedin.pdf` via `resources.py`) and appends the conversation history + new user message.
8. **Lambda calls Bedrock** (`bedrock_client.converse(...)`) with the model ID (e.g. `global.amazon.nova-2-lite-v1:0`), which generates the reply.
9. **Lambda saves the updated conversation** (user message + assistant reply, with timestamps) back to the **S3 memory bucket** (`put_object`), keyed by `session_id`.
10. **Lambda returns the response** through API Gateway back to the browser.
11. **Every step logs to CloudWatch** (`/aws/lambda/twin-api` log group) — this is your first stop when debugging.

```
Browser ──①②③──▶ CloudFront ──▶ S3 Frontend (page load only)
Browser ────────④─────────────▶ API Gateway ──▶ Lambda
                                                   │
                                    ⑥ read history │ write history ⑨
                                                   ▼
                                          S3 Memory Bucket
                                                   │
                                    ⑦⑧ build prompt, call model
                                                   ▼
                                              AWS Bedrock
                                                   │
                                       ⑩ response flows back up
Browser ◀────────────────────── API Gateway ◀──── Lambda
```

**Key insight:** the frontend and API are two *separate* AWS endpoints. CloudFront only fronts the S3 static site. The API Gateway URL is called directly by the browser — that's why CORS configuration (in both API Gateway *and* the Lambda's `CORS_ORIGINS` env var) matters so much.

---

## 4. What Gets Set Up Where

| Location | What you configure | Why |
|---|---|---|
| **Local repo (`twin/backend`)** | `data/facts.json`, `summary.txt`, `style.txt`, `linkedin.pdf`, `resume.html`, `resources.py`, `context.py`, `server.py`, `lambda_handler.py`, `deploy.py`, `requirements.txt` | Your actual application code and personal context. Note: `resume.html` is stored in `data/` but not yet parsed by `resources.py` — wire it in if you want it in the twin's context. |
| **Local repo (`twin/frontend`)** | `next.config.ts` (`output: 'export'`), `components/twin.tsx` (API URL) | Static site build config |
| **Local `.env` (project root)** | `AWS_ACCOUNT_ID`, `DEFAULT_AWS_REGION`, `OPENAI_API_KEY` (Day 2 only), `PROJECT_NAME` | Local tooling / deploy scripts |
| **IAM (root user, once)** | User group `TwinAccess` with policies attached | Grants your IAM user (`aiengineer`) permission to manage everything below |
| **Lambda console** | Function `twin-api`, handler, timeout, environment variables, execution role permissions | Runs your backend |
| **S3 console** | Bucket 1: `twin-memory-[suffix]` (private, conversation storage). Bucket 2: `twin-frontend-[suffix]` (public, static website hosting) | Storage + static hosting |
| **API Gateway console** | HTTP API `twin-api-gateway`, routes, Lambda integration, CORS | Public API surface |
| **CloudFront console** | Distribution `twin-distribution`, custom origin = S3 website endpoint | Global HTTPS CDN for the frontend |
| **CloudWatch console** | Log groups (auto-created), optional dashboard `twin-monitoring`, metrics | Observability |
| **Billing console** | Budget `twin-budget` with alert threshold | Cost control |

---

## 5. IAM Setup (do this first, once)

**Group name:** `TwinAccess`
**Attached to user:** `aiengineer` (created in Week 1)

Policies to attach (Day 2 + Day 3 combined — attach all of these to avoid repeat trips):

| Policy | Unlocks |
|---|---|
| `AWSLambda_FullAccess` | Create/edit Lambda functions |
| `AmazonS3FullAccess` | Create/edit S3 buckets |
| `AmazonAPIGatewayAdministrator` | Create/edit API Gateway |
| `CloudFrontFullAccess` | Create/edit CloudFront distributions |
| `IAMReadOnlyAccess` | View roles (needed to find Lambda's execution role) |
| `AmazonDynamoDBFullAccess_v2` | Needed later (Day 4/5) |
| `AmazonBedrockFullAccess` | Call Bedrock models (Day 3) |
| `CloudWatchFullAccess` | Dashboards + metrics (Day 3) |

**Workflow every time you need to change IAM:** sign in as **root** → make the IAM change → sign back out → sign in as **`aiengineer`** for everything else. Day-to-day work (Lambda, S3, API Gateway, CloudFront) happens as `aiengineer`, not root.

The **Lambda execution role** (auto-created when you make the function) separately needs `AmazonS3FullAccess` and `AmazonBedrockFullAccess` attached directly to it — this is *different* from the `TwinAccess` group, which only governs your human IAM user.

---

## 6. Lambda — Key Settings Cheat Sheet

| Setting | Value |
|---|---|
| Function name | `twin-api` |
| Runtime | Python 3.12 |
| Architecture | x86_64 |
| Handler | `lambda_handler.handler` |
| Timeout | 30 seconds |
| Package built via | `uv run deploy.py` (uses Docker + `public.ecr.aws/lambda/python:3.12` image to install deps for the correct Lambda runtime) |
| Upload method | Direct upload (<10MB) or via a temporary S3 bucket (recommended, more reliable) |

**Environment variables:**

| Key | Day 2 (OpenAI) | Day 3 (Bedrock) |
|---|---|---|
| `OPENAI_API_KEY` | your key | *(remove)* |
| `CORS_ORIGINS` | `*` → then CloudFront URL | same |
| `USE_S3` | `true` | `true` |
| `S3_BUCKET` | `twin-memory-[suffix]` | same |
| `DEFAULT_AWS_REGION` | — | `us-east-1` |
| `BEDROCK_MODEL_ID` | — | `global.amazon.nova-2-lite-v1:0` (start here; fall back to `us.` / `eu.` / `ap.` prefix if you hit quota issues) |

---

## 7. S3 — Two Buckets, Two Purposes

| Bucket | Purpose | Access | Key setting |
|---|---|---|---|
| `twin-memory-[suffix]` | Stores one JSON file per `session_id` = conversation history | Private, Lambda-only via IAM role | Just needs to exist — no special policy |
| `twin-frontend-[suffix]` | Hosts the static Next.js export | Public read | Static website hosting enabled (index: `index.html`, error: `404.html`) + public bucket policy (`s3:GetObject` for `*`) |

This project's actual frontend bucket: `twin-frontend-167769273848` (ARN `arn:aws:s3:::twin-frontend-167769273848`), website endpoint `http://twin-frontend-167769273848.s3-website.ap-south-2.amazonaws.com` — use this endpoint (minus `http://`) as the CloudFront origin domain in §9.

Deploying frontend updates: `aws s3 sync out/ s3://twin-frontend-167769273848/ --delete`

---

## 8. API Gateway — Routes Reference

HTTP API, name `twin-api-gateway`, single Lambda integration (`twin-api`) for every route:

| Method | Path | Purpose |
|---|---|---|
| GET | `/` | Root/info endpoint |
| GET | `/health` | Health check (used in Lambda test events too) |
| POST | `/chat` | Main chat endpoint |
| ANY | `/{proxy+}` | Catch-all fallback |
| OPTIONS | `/{proxy+}` | CORS preflight |

**CORS config (in API Gateway itself):** Allow-Origin `*`, Allow-Headers `*`, Allow-Methods `*`, Max-Age `300` — remember to click **Add** after typing each value, or it won't save.

---

## 9. CloudFront — Gotchas That Bite Everyone

- Choose **Pay as you go**, never the "free" plan (you can't tear it down without cancelling a subscription).
- Origin type: **Other** (not "Amazon S3") — you're pointing at the S3 *website endpoint*, not the bucket via S3 API.
- Origin domain: the S3 website endpoint **without** `http://` prefix.
- **Origin protocol policy: HTTP only** — S3 static website hosting doesn't support HTTPS. Picking HTTPS here causes 504 errors.
- Viewer protocol policy: **Redirect HTTP to HTTPS** (this is what actually gives you the HTTPS URL users see).
- After creating, get the distribution domain (`dxxxx.cloudfront.net`) and set it as `CORS_ORIGINS` on Lambda — **exact match required**: starts with `https://`, no trailing `/`.
- After any frontend redeploy, create an **invalidation** on path `/*` or you'll see stale content.

---

## 10. The #1 Debugging Rule: CORS_ORIGINS

Almost every mysterious error traces back to a mismatched `CORS_ORIGINS` env var on Lambda. It must:

- Start with `https://`
- Match the CloudFront domain exactly
- Have **no trailing slash**

Wrong value → confusing CORS errors in browser console that look like everything else is broken.

---

## 11. Troubleshooting Quick Reference

| Symptom | Check |
|---|---|
| CORS errors in console | `CORS_ORIGINS` on Lambda matches CloudFront URL exactly; API Gateway CORS configured; OPTIONS route exists |
| 500 Internal Server Error | CloudWatch logs (`/aws/lambda/twin-api`); env vars set; Lambda has S3/Bedrock permissions |
| Chat replies "Sorry, I encountered an error" | Browser JS console for the real status code; if Bedrock-related, try `us.`/`eu.` model ID prefix |
| Frontend not updating | Create a CloudFront invalidation on `/*`; clear browser cache |
| Memory not persisting | `S3_BUCKET` name correct; Lambda has `AmazonS3FullAccess`; `USE_S3=true` |
| Bedrock "Access Denied" | Lambda execution role has `AmazonBedrockFullAccess`; region matches |
| Bedrock "Model Not Found" | Exact model ID string (case-sensitive, correct version); try region-prefixed variant |

---

## 12. Cost Snapshot (approximate, moderate usage)

| Service | Cost |
|---|---|
| Lambda | Free for first 1M requests, then $0.20/1M |
| API Gateway | Free for first 1M requests, then $1.00/1M |
| S3 | ~$0.023/GB stored, ~$0.0004/1,000 requests |
| CloudFront | Free for first 1TB, then ~$0.085/GB |
| **Total** | Typically **under $5/month** |

Set a Billing budget (`twin-budget`) with an 80% alert threshold as a safety net.

---

## 13. Deployment Workflow (repeatable checklist)

Whenever you change backend code:

1. Update code locally (`server.py`, `context.py`, etc.)
2. `cd backend && uv add -r requirements.txt` (if deps changed)
3. `uv run deploy.py` (rebuilds `lambda-deployment.zip` via Docker)
4. Upload the new zip:
   - Small/fast connection → direct upload in Lambda console
   - Preferred → upload to a temp S3 bucket, then `aws lambda update-function-code --s3-bucket ... --s3-key ...`
5. Confirm `"LastUpdateStatus": "Successful"`
6. Re-run the `HealthCheck` test event in Lambda console
7. Test end-to-end via the CloudFront URL

Whenever you change frontend code:

1. `cd frontend && npm run build` (needs `output: 'export'` in `next.config.ts`)
2. `aws s3 sync out/ s3://YOUR-FRONTEND-BUCKET/ --delete`
3. Create a CloudFront invalidation on `/*`
4. Hard-refresh / test in incognito

---

## 14. Full Component Glossary

- **CloudFront** — Global CDN, terminates HTTPS, caches and serves the static frontend.
- **S3 Frontend Bucket** — Holds the built Next.js static export (`out/` folder).
- **S3 Memory Bucket** — Holds per-session conversation history as JSON.
- **API Gateway (HTTP API)** — Public REST-style entry point, routes requests to Lambda, handles CORS.
- **Lambda (`twin-api`)** — Serverless FastAPI backend (via Mangum adapter); the only compute component.
- **AWS Bedrock** — Managed foundation-model service; Nova Micro/Lite/Pro models generate the twin's replies (replaces OpenAI as of Day 3).
- **CloudWatch** — Logs + metrics for Lambda and Bedrock; primary debugging tool.
- **IAM (`TwinAccess` group, `aiengineer` user, Lambda execution role)** — Permission boundaries for humans and for the Lambda function itself.
- **AWS Budgets** — Billing alert safety net.
