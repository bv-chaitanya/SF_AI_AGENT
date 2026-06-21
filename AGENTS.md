# SF_AI_AGENT — Salesforce AI Chatbot

## Project Skill (loaded by opencode)
Multi-provider AI chatbot (OpenRouter + DeepSeek) + Salesforce Platform MCP, running as an LWC inside a Developer Edition org. Provider and model selectable from the UI.

## Deploy
```powershell
# Primary (sfdx — avoids sf CLI JSON parse bug on v2.58.7):
sfdx force:source:deploy -p force-app -u venkatachaitanyabhimisetty@gmail.com

# Backup (sf):
sf project deploy start -d force-app -o "venkatachaitanyabhimisetty@gmail.com"
```

## Salesforce Org
- **Org**: Developer Edition, `venkatachaitanyabhimisetty@gmail.com`
- **Instance**: `chap-dev-ed.my.salesforce.com`
- **Login**: `sf org login web --instance-url https://login.salesforce.com --set-default`

## AI Providers (selectable in UI)
All API keys stored in a single CMDT: `AI_Provider_Setting__mdt`. Create one record per provider (MasterLabel = provider name, Api_Key__c = key).

### OpenRouter
- **API key**: CMDT record with MasterLabel `OpenRouter`
- **Free model chain**: `nex-agi/nex-n2-pro:free` → `nvidia/nemotron-3-super-120b-a12b:free` → `google/gemma-4-31b-it:free` → `openrouter/free`
- **Also available**: `deepseek/deepseek-chat`, `deepseek/deepseek-r1`, `anthropic/claude-3.5-haiku`, `google/gemini-2.0-flash-001`

### DeepSeek
- **API key**: CMDT record with MasterLabel `DeepSeek` — key starts with `sk-`
- **Models**: `deepseek-chat` (fast/Flash), `deepseek-reasoner` (R1 reasoning)
- **Timeout**: 12s per callout

## Salesforce Platform MCP Server (platform.sobject-all)
- **URL**: `https://api.salesforce.com/platform/mcp/v1/platform/sobject-all` (hosted by Salesforce, NOT the npm DX package)
- **11 tools + 2 prompts**, Active by default in Developer Edition
- **Apex callout**: `callout:Salesforce_MCP/platform/mcp/v1/platform/sobject-all` (Named Credential)

## MCP Auth Flow (External Client Manager — replaces Connected Apps)
1. **External Client App** (Setup → External Client Manager → New): `SF MCP Auth`
   - Enable OAuth, callback `https://chap-dev-ed.my.salesforce.com/services/authcallback/SF_MCP_Auth`
   - Scopes: `api`, `refresh_token`, **`mcp_api`** (critical, easy to miss)
   - Enable JWT-based access tokens
2. **Auth Provider** (Setup → Auth Providers → New → Salesforce): `SF_MCP_Auth`
   - Consumer Key/Secret from step 1
   - Endpoints: `login.salesforce.com`
3. **Named Credential** (Setup → Named Credentials → New): `Salesforce_MCP`
   - URL: `https://api.salesforce.com`, Identity: Named Principal, Protocol: OAuth 2.0
   - Auth Provider: `SF_MCP_Auth`, Scope: `api refresh_token mcp_api`
   - Start Authentication Flow on Save → log in → must show "Authenticated"

## MCP Protocol Handshake (GOTCHAS)
1. **`initialize` first**: protocolVersion `2025-03-26`, client name + version
2. **`Mcp-Session-Id` header**: captured from `initialize` response, sent on ALL subsequent calls
3. **Case-insensitive header lookup**: Apex `getHeader('Mcp-Session-Id')` returns null even when header exists — iterate `getHeaderKeys()` with case-insensitive compare
4. **`notifications/initialized`** notification after initialize (no response expected)

## SF CLI MCP in opencode.jsonc
- **Config**: `~/.config/opencode/opencode.jsonc`
- **MCP**: `salesforce` — uses bundled npx from SF CLI install to invoke `@salesforce/mcp@latest`
- **Reference**: `@SF_AI_AGENT` — points to this project folder
- **Auth**: automatic (uses stored `sf org login` session)

## Known SF CLI Bugs (v2.58.7)
- **JSON parse error**: `"Metadata API request failed: Missing message metadata.transfer:Finalizing"` — this is a DISPLAY bug only. Deploy succeeded. Use `sfdx force:source:deploy` or check deploy report to confirm.
- **`sf project deploy report -i ID`** — may throw `InvalidProjectWorkspaceError` when run from wrong dir. Always run from project root.
- **CLI update nag**: `"@salesforce/cli update available from 2.58.7 to 2.139.6"` — safe to ignore, v2.58.7 works for deploy/query.

## LWC Architecture
- **`chatBot`** component — supports `AppPage`, `RecordPage`, `HomePage` targets
- Uses SLDS `lightning-card`, `lightning-combobox`, `lightning-input`, `lightning-button`, `lightning-avatar`, `lightning-layout` base components
- **Provider + Model selectors** in UI — user picks OpenRouter or DeepSeek, then the model
- **`sendMessageDetailed`** returns `ChatResponse` with `answer`, `usedTool`, `toolName`, `toolArguments`, `model`, `provider`
- **`summarizeCurrentRecordDetailed`** — summarize the current record (takes `recordId`)
- Native function calling from AI → Apex parses `message.tool_calls[0].function`
- Fallback: `<tool_call>{"name":"...", "arguments":{...}}</tool_call>` tag parsing for models that don't support native tools
- CSS in `chatBot.css` — minimal, relies on SLDS for styling

## Token Optimization
- OpenRouter native function calling sends MCP tools as `tools` array in the API call
- MCP tools list is fetched once per transaction (static in-memory cache)
- Free model chain with 12s timeout prevents hanging on slow free models
- DeepSeek is direct single-call (no chain needed)

## File map
```
SF_AI_AGENT/
├── AGENTS.md                          # This file — project skill for opencode
├── README.md                          # README for humans
├── LINKEDIN_POST.md                   # LinkedIn post with setup steps
├── .gitignore
├── sfdx-project.json
├── config/project-scratch-def.json
├── force-app/main/default/
│   ├── lwc/chatBot/                   # LWC chat UI (SLDS-based)
│   │   ├── chatBot.html               # Lightning base components + SLDS chat
│   │   ├── chatBot.js                 # Provider/model selection, step-by-step flow
│   │   ├── chatBot.css                # Minimal scroll/height styling
│   │   └── chatBot.js-meta.xml        # Targets: AppPage, RecordPage, HomePage
│   ├── classes/
│   │   ├── ChatBotController.cls      # MCP client + dual-provider AI orchestrator
│   │   ├── ChatBotController.cls-meta.xml
│   │   ├── ChatBotControllerTest.cls  # 11 test methods with HttpCalloutMock
│   │   └── ChatBotControllerTest.cls-meta.xml
│   ├── objects/AI_Provider_Setting__mdt/
│   │   ├── AI_Provider_Setting__mdt.object-meta.xml
│   │   └── fields/Api_Key__c.field-meta.xml
│   └── remoteSiteSettings/
│       ├── OpenRouter.remoteSite-meta.xml        # https://openrouter.ai
│       ├── DeepSeek.remoteSite-meta.xml          # https://api.deepseek.com
│       └── SalesforcePlatformApi.remoteSite-meta.xml # https://api.salesforce.com
```
