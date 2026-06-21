# SF AI Agent — Salesforce AI Chatbot

A multi-provider AI chatbot running as a Lightning Web Component inside a Salesforce Developer Edition org. Talks to your records via the **Salesforce Platform MCP Server** and reasons with **DeepSeek** or **OpenRouter**.

![Stack](https://img.shields.io/badge/Salesforce-Developer%20Edition-blue) ![LWC](https://img.shields.io/badge/UI-LWC-7474f0) ![Apex](https://img.shields.io/badge/Backend-Apex-1798c1) ![AI](https://img.shields.io/badge/AI-DeepSeek%20%7C%20OpenRouter-green)

---

## What It Does

Type a question — *"List my top 10 accounts"*, *"Create a contact on this record"*, *"Summarize open opportunities over 50K"* — and the bot:

1. Sends your message to DeepSeek or OpenRouter with available MCP tools
2. The LLM decides which tool to call (SOQL query, record create, schema describe, etc.)
3. Apex executes the tool against the Salesforce Platform MCP server
4. The LLM summarizes the result in plain language — streamed word-by-word

## Architecture

```
User (LWC) → Apex Controller → ChatBotService
                                   ├── MCP Session (initialize → tools/list → tools/call)
                                   └── AI Provider (DeepSeek / OpenRouter with SSE streaming)
```

- **Controller** (`ChatBotController.cls`, 220 lines) — `@AuraEnabled` entry points + conversation orchestration
- **Service** (`ChatBotService.cls`, 470 lines) — MCP client, AI provider calls, SSE streaming parser, tool call parsing
- **LWC** (`chatBot/`) — SLDS-inspired clean UI with provider/model selection, record context chips, search

## Features

- **Dual AI providers** — DeepSeek (`deepseek-chat`, `deepseek-reasoner`) and OpenRouter (8 models including free tier)
- **Provider + model selectable in the UI** — defaults to DeepSeek
- **Real-time tool calls** — each tool executes in its own round-trip, shown one-by-one with real timing
- **SSE streaming** — AI responses type out word-by-word via server-sent events
- **Conversation memory** — summarized context sent with each message
- **Record context chips** — auto-adds the page record, + button to search and attach any record
- **Multi-tool chain** — AI can query schema then create/update/delete in one request
- **MCP protocol** — full `initialize → notifications/initialized → tools/list → tools/call` handshake
- **Privacy** — hashed `user_id` sent to DeepSeek for KVCache isolation

## Setup

### Prerequisites
- Salesforce Developer Edition org
- SFDX CLI (`sfdx`) installed
- DeepSeek API key (starts with `sk-`) and/or OpenRouter API key

### 1. Enable MCP Server
Setup → MCP Servers → `platform.sobject-all` → Confirm **Active** (default in Developer Edition)

### 2. External Client App + Auth Provider + Named Credential
Follow the 3-step OAuth flow for MCP access (see [full setup guide](#mcp-auth-flow)):
- External Client App with `mcp_api` scope
- Auth Provider → Named Credential `Salesforce_MCP`
- Verify "Authenticated" status

### 3. Deploy
```bash
sfdx force:source:deploy -p force-app -u YOUR_ORG_ALIAS
```

### 4. Add API Keys
Setup → Custom Metadata Types → **AI Provider Setting** → Manage Records → New:
- Record 1: `MasterLabel` = `DeepSeek`, `Api_Key__c` = your key (starts with `sk-`)
- Record 2: `MasterLabel` = `OpenRouter`, `Api_Key__c` = your key

### 5. Add to Lightning Page
Edit any Record Page → drag **chatBot** component → Save

## MCP Auth Flow

1. **External Client App** (Setup → External Client Manager → New): `SF MCP Auth`
   - Enable OAuth, callback `https://<org>.my.salesforce.com/services/authcallback/SF_MCP_Auth`
   - Scopes: `api`, `refresh_token`, **`mcp_api`** (easy to miss)
   - Enable JWT-based access tokens
2. **Auth Provider** (Setup → Auth Providers → New → Salesforce): `SF_MCP_Auth`
   - Consumer Key/Secret from step 1, endpoints: `login.salesforce.com`
3. **Named Credential** (Setup → Named Credentials → New): `Salesforce_MCP`
   - URL: `https://api.salesforce.com`, Named Principal, OAuth 2.0
   - Auth Provider: `SF_MCP_Auth`, Scope: `api refresh_token mcp_api`

## Project Structure

```
force-app/main/default/
├── classes/
│   ├── ChatBotController.cls        # Aura-enabled entry points
│   ├── ChatBotService.cls           # MCP + AI implementation
│   └── ChatBotControllerTest.cls    # Unit tests
├── lwc/chatBot/
│   ├── chatBot.html                 # LWC template
│   ├── chatBot.js                   # UI logic, tool loop, streaming
│   └── chatBot.css                  # Clean minimal styling
├── objects/AI_Provider_Setting__mdt/ # CMDT for API keys
└── remoteSiteSettings/              # Callout allowlisting
```

## Key Lessons

- `mcp_api` OAuth scope is non-obvious — add it upfront
- MCP handshake is mandatory: `initialize` → `notifications/initialized` → then `tools/*`
- Apex `getHeader('Mcp-Session-Id')` returns null — iterate keys case-insensitively
- `UserInfo.getSessionId()` does NOT work for MCP — need real OAuth flow

## License

MIT
