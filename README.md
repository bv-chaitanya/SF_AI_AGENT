# SF AI Agent — Salesforce AI Chatbot

A multi-provider AI chatbot running as a Lightning Web Component inside Salesforce.  
Chat with your records via the **Salesforce Platform MCP Server** using **Neuralwatt**, **DeepSeek**, or **OpenRouter**.

---

## What You Need

| Requirement | Details |
|---|---|
| **Salesforce Org** | Developer Edition (free) or any org with API access |
| **Salesforce CLI** | `sf` CLI installed and authenticated to your org |
| **Neuralwatt API Key** | OpenAI-compatible provider (GLM/Kimi/Qwen models) — the default active provider |
| **DeepSeek API Key** *(optional)* | Get one at [platform.deepseek.com](https://platform.deepseek.com) — starts with `sk-` |
| **OpenRouter API Key** *(optional)* | Get one at [openrouter.ai/keys](https://openrouter.ai/keys) — for fallback/free models |

---

## Quick Start (5 Steps)

### 1. Enable MCP Server
Setup → MCP Servers → `platform.sobject-all` → confirm **Active** (default in Developer Edition).

### 2. Set Up MCP Auth (OAuth)
This is the trickiest part. You need 3 things in sequence:

**a) External Client App** — Setup → External Client Manager → New
- Name: `SF MCP Auth`, API Name: `SF_MCP_Auth`
- Enable OAuth, callback: `https://<your-instance>.my.salesforce.com/services/authcallback/SF_MCP_Auth`
- Scopes: `api`, `refresh_token`, **`mcp_api`** ← easy to miss
- Enable JWT-based access tokens

**b) Auth Provider** — Setup → Auth Providers → New → Salesforce
- Name: `SF_MCP_Auth`, Consumer Key/Secret from step (a)
- Endpoints: `login.salesforce.com`

**c) Named Credential** — Setup → Named Credentials → New
- Label/Name: `Salesforce_MCP` (must match exactly)
- URL: `https://api.salesforce.com`, Named Principal, OAuth 2.0
- Auth Provider: `SF_MCP_Auth`, Scope: `api refresh_token mcp_api`
- Start Auth Flow on Save → log in → verify "Authenticated"

### 3. Deploy
```bash
sf project deploy start --source-dir force-app --target-org YOUR_ORG_ALIAS
```

### 4. Add API Keys
Setup → Custom Metadata Types → **AI Provider Setting** → Manage Records → New:

| MasterLabel | Base_Url__c | Is_Active__c | Api_Key__c |
|---|---|---|---|
| `Neuralwatt` | `https://api.neuralwatt.com/v1` | `true` | *(set manually)* |
| `DeepSeek` | `https://api.deepseek.com` | `false` | *(set manually)* |
| `OpenRouter` | `https://openrouter.ai/api/v1` | `false` | *(set manually)* |

> Only `Is_Active__c = true` providers appear in the UI dropdown. Set the API key after deploying — it is never committed to source.

### 5. Add to Page
Edit any Lightning Record Page → drag in the **chatBot** component → Save.  
The bot auto-detects the current record as context.

---

## How It Works

```
You type: "List my top 10 accounts"
     │
     ▼
LWC sends message → Apex builds prompt with MCP tools → DeepSeek/OpenRouter chooses tool
     │
     ▼
Apex calls MCP server → SOQL query executes → result goes back to AI → AI writes plain-language summary
     │
     ▼
Response streams word-by-word into the chat bubble
```

For the full architecture, see **[ARCHITECTURE.md](ARCHITECTURE.md)** — includes system diagram, message flow trace, credential paths, class diagram, MCP protocol handshake, and SSE streaming details.

---

## Features

- **Multi-provider AI** — Neuralwatt (GLM/Kimi/Qwen), DeepSeek, and OpenRouter (300+ models) via CMDT config
- **Dynamic model loading** — models fetched from `/models` endpoint; no hardcoded lists
- **UI selectors** — pick provider and model from dropdowns above the input
- **Streaming** — responses type out word-by-word (SSE parsed by Apex, rendered in LWC)
- **Conversation memory** — summarized context sent with each message
- **Record context** — auto-adds the page record as a chip; `+` to search and attach any record
- **Multi-tool** — AI can query schema then create/update/delete in one request
- **Tool cards** — each MCP tool call shown with name, args, expandable detail
- **Privacy** — hashed user ID sent to DeepSeek for KVCache isolation
- **Accessibility** — `aria-label` on all controls, keyboard-navigable tool cards

---

## Key Gotchas

- The **`mcp_api`** OAuth scope is buried in the External Client App UI — missing it causes `401 Invalid token`
- MCP handshake is **mandatory**: `initialize` → `notifications/initialized` → then `tools/*`
- Apex `getHeader('Mcp-Session-Id')` returns `null` even when the header exists — iterate `getHeaderKeys()` case-insensitively
- `UserInfo.getSessionId()` does **not** work for MCP API calls — you need a real OAuth flow
- Apex static variables **do not persist** across `@AuraEnabled` calls — if you need multi-step state, handle it in a single transaction

---

## Security

- DeepSeek/OpenRouter API keys stored in CMDT (never in source code)
- MCP uses Named Credential with OAuth — token never visible in Apex
- AI only *proposes* tool calls — Apex validates and forwards to MCP
- MCP server enforces the authenticated user's object/field-level security
- Two completely separate credentials: AI key ≠ MCP token

See the full security audit for line-by-line trace of every credential, HTTP call, and token path.

---

## License

MIT
