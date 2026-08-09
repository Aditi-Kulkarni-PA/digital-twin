# Digital Twin

A conversational AI "digital twin" — a chatbot that represents you on your personal/professional website, answering questions about your background, skills, and experience as if it were you. Built with a FastAPI backend and a Next.js frontend, deployable serverlessly on AWS.

> Full AWS architecture, request/data flow diagrams, and setup cheat sheets live in [`architecture.md`](./architecture.md). This README covers what the project is and how to run/deploy it; `architecture.md` covers how the AWS pieces fit together.

---

## Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Tech Stack](#tech-stack)
- [Project Structure](#project-structure)
- [Prerequisites](#prerequisites)
- [Getting Started (Local Development)](#getting-started-local-development)
- [Personalizing Your Twin](#personalizing-your-twin)
- [Environment Variables](#environment-variables)
- [Running the App](#running-the-app)
- [Deployment (AWS)](#deployment-aws)
- [Project Status](#project-status)
- [Troubleshooting](#troubleshooting)
- [Cost](#cost)
- [Roadmap](#roadmap)

---

## Overview

The Digital Twin is an AI agent that:

- Is briefed with your personal facts, resume/LinkedIn, and communication style
- Chats with visitors on your website as a faithful representation of you
- Remembers conversations per session (locally as JSON, or in S3 when deployed)
- Runs as a serverless backend (AWS Lambda) behind a static, globally-cached frontend (CloudFront + S3)
- Can be powered by either OpenAI or AWS Bedrock (Nova models) for generating responses

## Features

- **Conversational chat UI** — Next.js frontend, chat-style interface
- **Personalized context** — pulls from `facts.json`, `summary.txt`, `style.txt`, and a parsed LinkedIn PDF to ground responses in real information (no hallucinated background)
- **Session memory** — conversation history persisted per `session_id`, either to local disk or an S3 bucket
- **Pluggable AI backend** — swap between OpenAI (`gpt-4o-mini`) and AWS Bedrock (Amazon Nova Micro/Lite/Pro) via config
- **Serverless deployment** — FastAPI wrapped with Mangum, deployed to AWS Lambda behind API Gateway
- **Global HTTPS delivery** — CloudFront CDN in front of an S3-hosted static frontend
- **Guardrails** — the system prompt instructs the model not to hallucinate, not to be jailbroken, and to stay professional

## Tech Stack

**Backend**
- Python 3.12, [FastAPI](https://fastapi.tiangolo.com/), [Uvicorn](https://www.uvicorn.org/) (local dev server)
- [Mangum](https://mangum.io/) — adapts FastAPI to run on AWS Lambda
- [boto3](https://boto3.amazonaws.com/) — AWS SDK (S3, Bedrock)
- [pypdf](https://pypdf.readthedocs.io/) — parses your LinkedIn PDF export
- [OpenAI SDK](https://github.com/openai/openai-python) and/or AWS Bedrock `bedrock-runtime`
- Dependency management via [uv](https://docs.astral.sh/uv/)

**Frontend**
- [Next.js](https://nextjs.org/) 16 (App Router, static export)
- React 19, TypeScript, Tailwind CSS 4
- [lucide-react](https://lucide.dev/) for icons

**Infrastructure (AWS)**
- Lambda, API Gateway (HTTP API), S3 (frontend hosting + memory storage), CloudFront, IAM, CloudWatch, Bedrock

## Project Structure

```
twin/
├── architecture.md          # AWS architecture, data flow, setup cheat sheets
├── README.md                 # This file
├── .env                       # Project-level config (AWS account, region) — not committed
├── week2-instructions/        # Course walkthroughs (day1–day5)
├── memory/                    # Local conversation history (JSON per session) — dev only
├── backend/
│   ├── server.py               # FastAPI app — /, /health, /chat, /conversation/{id}
│   ├── lambda_handler.py       # Mangum entrypoint for AWS Lambda
│   ├── context.py              # Builds the system prompt from personal data
│   ├── resources.py            # Loads facts.json, summary.txt, style.txt, linkedin.pdf
│   ├── deploy.py                # Builds the Lambda deployment zip (via Docker)
│   ├── requirements.txt / pyproject.toml
│   ├── data/
│   │   ├── facts.json            # Structured facts about you
│   │   ├── summary.txt           # Free-text personal summary
│   │   ├── style.txt             # Communication style notes
│   │   ├── linkedin.pdf          # Exported LinkedIn profile
│   │   └── resume.html           # Resume/CV (reference copy — not yet loaded by resources.py)
│   └── .env                     # Backend secrets (API keys, CORS origins) — not committed
└── frontend/
    ├── app/                      # Next.js App Router pages
    ├── components/               # Chat UI components (e.g. twin.tsx)
    ├── next.config.ts            # Static export config for S3 hosting
    └── package.json
```

## Prerequisites

- Python 3.12+
- [uv](https://docs.astral.sh/uv/) for Python dependency management
- Node.js 18+ and npm
- Docker Desktop (only needed when building the Lambda deployment package)
- An AWS account with an IAM user set up (see `architecture.md` §5)
- An OpenAI API key (if using the OpenAI backend) — get one at [platform.openai.com](https://platform.openai.com/)
- AWS CLI configured locally (only needed for deployment steps)

## Getting Started (Local Development)

### 1. Clone and enter the project

```bash
cd twin
```

### 2. Backend setup

```bash
cd backend
uv sync                     # installs dependencies from pyproject.toml / requirements.txt
```

Create `backend/.env` (see [Environment Variables](#environment-variables) below).

### 3. Frontend setup

```bash
cd frontend
npm install
```

## Personalizing Your Twin

Before running the app, fill in your own details:

1. **`backend/data/facts.json`** — structured info: name, role, location, specialties, education, etc.
2. **`backend/data/summary.txt`** — a short free-text bio.
3. **`backend/data/style.txt`** — notes on how you communicate (tone, phrasing habits).
4. **`backend/data/linkedin.pdf`** — export your LinkedIn profile to PDF (LinkedIn → "More" → "Save to PDF"), or use a resume PDF instead.
5. **`backend/data/resume.html`** — an HTML copy of your resume, kept alongside the other source data. Not currently parsed by `resources.py`/`context.py` — if you want its content in the twin's context, add a loader for it similar to the `facts.json`/`style.txt` reads.

`context.py` combines the files above into the system prompt that grounds the model's responses — the model is instructed not to invent details beyond what's here.

## Environment Variables

**Project root `.env`** (used by deploy tooling):

| Variable | Description |
|---|---|
| `AWS_ACCOUNT_ID` | Your 12-digit AWS account ID |
| `DEFAULT_AWS_REGION` | AWS region for deployment (e.g. `us-east-1`) |
| `OPENAI_API_KEY` | Only needed if using the OpenAI backend |
| `PROJECT_NAME` | `twin` |

**`backend/.env`** (used by the FastAPI app):

| Variable | Description | Default |
|---|---|---|
| `OPENAI_API_KEY` | OpenAI key (OpenAI backend only) | — |
| `CORS_ORIGINS` | Comma-separated allowed origins | `http://localhost:3000` |
| `USE_S3` | Use S3 for conversation memory instead of local disk | `false` |
| `S3_BUCKET` | S3 bucket name for memory (if `USE_S3=true`) | — |
| `MEMORY_DIR` | Local directory for memory when `USE_S3=false` | `../memory` |
| `DEFAULT_AWS_REGION` | Region for the Bedrock client | `us-east-1` |
| `BEDROCK_MODEL_ID` | Bedrock model to use (Bedrock backend only) | `global.amazon.nova-2-lite-v1:0` |

**Never commit `.env` files** — both are already excluded via `.gitignore`. If a key ever ends up committed or shared, rotate it immediately.

## Running the App

**Backend** (from `backend/`):

```bash
uv run uvicorn server:app --reload
```

Runs at `http://localhost:8000`. Check `http://localhost:8000/health`.

**Frontend** (from `frontend/`, in a separate terminal):

```bash
npm run dev
```

Runs at `http://localhost:3000` and talks to the local backend.

## Deployment (AWS)

The app deploys as:
- **Backend** → AWS Lambda (behind API Gateway)
- **Frontend** → static export hosted on S3, served through CloudFront

Full step-by-step setup (IAM groups, Lambda config, S3 buckets, API Gateway routes, CloudFront distribution, Bedrock migration) is documented in [`architecture.md`](./architecture.md) and the original walkthroughs in [`week2-instructions/`](./week2-instructions/) (`day2.md` for the initial AWS deploy, `day3.md` for the Bedrock migration).

Quick reference — redeploying after a backend change:

```bash
cd backend
uv run deploy.py                       # rebuilds lambda-deployment.zip
aws lambda update-function-code \
  --function-name twin-api \
  --zip-file fileb://lambda-deployment.zip
```

Redeploying after a frontend change:

```bash
cd frontend
npm run build                          # requires output: 'export' in next.config.ts
aws s3 sync out/ s3://twin-frontend-167769273848/ --delete
# then create a CloudFront invalidation on /*
```

### Deployed AWS Resources (this project)

| Resource | Value |
|---|---|
| Region | `ap-south-2` |
| AWS Account | `167769273848` |
| Frontend bucket (ARN) | `arn:aws:s3:::twin-frontend-167769273848` |
| S3 static website endpoint | `http://twin-frontend-167769273848.s3-website.ap-south-2.amazonaws.com` |

The S3 website endpoint above is **HTTP only** — it's meant to be used as the CloudFront origin, not visited directly as your public URL. Once CloudFront is set up, share the CloudFront domain (`https://dxxxx.cloudfront.net`) instead.

## Project Status

Currently configured for the **OpenAI backend** (`server.py` imports `openai`, `requirements.txt`/`pyproject.toml` include the `openai` package). The Bedrock migration described in `week2-instructions/day3.md` and `architecture.md` §2 has not yet been applied to this codebase — swap in the Bedrock version of `server.py` when ready to move off OpenAI.

## Troubleshooting

See `architecture.md` §11 for a fuller table. Most common issues:

- **CORS errors** → `CORS_ORIGINS` on the backend/Lambda must exactly match your frontend origin (no trailing slash).
- **500 errors after deploy** → check CloudWatch logs (`/aws/lambda/twin-api`) for the real stack trace.
- **Chat replies with a generic error message** → check the browser's JS console for the underlying HTTP status.
- **Frontend shows stale content after redeploy** → CloudFront caches aggressively; create an invalidation.

## Cost

Running on AWS free-tier-eligible services (Lambda, API Gateway, S3, CloudFront), typical cost for moderate personal usage is **under $5/month**. See `architecture.md` §12 for a breakdown, and consider setting a billing budget/alert.

## Roadmap

Per the course track (`week2-instructions/`):
- Day 4: Infrastructure as Code (Terraform), environment management, DynamoDB for memory, secret management
- Day 5: Further hardening and features (see `day5.md`)
