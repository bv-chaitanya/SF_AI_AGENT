# SF_AI_AGENT — Salesforce AI Chatbot

## Project Skill (loaded by opencode)
Multi-provider AI chatbot (OpenRouter + DeepSeek) + Salesforce Platform MCP, running as an LWC inside a Developer Edition org. Provider and model selectable from the UI.

## Deploy
```bash
# Full deploy:
sf project deploy start --source-dir force-app --target-org venkatachaitanyabhimisetty@gmail.com

# Partial deploy (changed files only):
sf project deploy start --source-dir force-app/main/default/classes/ChatBotService.cls --target-org venkatachaitanyabhimisetty@gmail.com

# Run tests:
sf apex run test --class-name ChatBotControllerTest --target-org venkatachaitanyabhimisetty@gmail.com --wait 1
```

## Salesforce Org
- **Org**: Developer Edition, `venkatachaitanyabhimisetty@gmail.com`
- **Instance**: `chap-dev-ed.my.salesforce.com`
- **Login**: `sf org login web --instance-url https://login.salesforce.com --set-default`

## AI Providers (dynamic, OpenAI-compatible)
All provider config lives in one CMDT: `AI_Provider_Setting__mdt`. Create one record per provider:
- **MasterLabel**: provider display name (e.g. `Neuralwatt`, `DeepSeek`, `OpenRouter`)
- **Api_Key__c**: bearer token for the provider
- **Base_Url__c**: OpenAI-compatible base URL (code appends `/chat/completions` and `/models`)

### To add a new provider
1. Add a CMDT record (MasterLabel + API key + base URL)
2. Add a `RemoteSiteSetting` for the base URL host
3. Done — Apex and LWC pick it up automatically; no code changes needed

### How models are loaded
- `ChatBotService.fetchModelsList(baseUrl, apiKey)` calls `GET {baseUrl}/models` (standard OpenAI-compatible endpoint)
- `ChatBotController.getAvailableModels()` iterates all CMDT records and returns `{providerName: [modelId, ...]}` as JSON
- LWC uses first provider + first model as the default

### Provider-specific extras (handled in `callOpenAiCompatible()`)
- **OpenRouter**: sends `HTTP-Referer` + `X-Title` headers; free models chain fallback (`nex-agi/nex-n2-pro:free` → `nvidia/...` → `google/gemma-...` → `openrouter/free`)
- **DeepSeek**: sends `user_id` (SHA-256 of `UserInfo.getUserId()`, truncated) for rate-limit privacy

### Recommended provider base URLs
| Provider | Base URL | Notes |
|----------|----------|-------|
| Neuralwatt | `https://api.neuralwatt.com/v1` | OpenAI-compatible, GLM/Kimi/Qwen models |
| DeepSeek | `https://api.deepseek.com` | Note: no `/v1` suffix per their docs |
| OpenRouter | `https://openrouter.ai/api/v1` | OpenAI-compatible, 300+ models |

### TODO: Upgrade to Named Credentials
When org upgrades to API v64+, replace CMDT key storage with Named Credentials (ApiKey protocol). Create one NC per provider with:
- Protocol: **API Key**
- Generate Authorization Header: true  
- API Key: `Bearer sk-xxx`
- Apex: use `callout:<ProviderName>_API`
- Remove `getProviderConfig()` and `Authorization` header from `doAiPost()`
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

## SF CLI Notes
- **Partial deploys**: Use `--source-dir <path>` for single files, `--metadata` for type-level deploys
- **Run tests**: `sf apex run test --class-name <class> --wait <minutes>`
- **`sfdx-project.json`**: Still the standard config file name — not renamed to `sf-project.json`

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
├── ARCHITECTURE.md                    # UML diagrams + data flow
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
│   │   ├── ChatBotService.cls         # MCP + AI provider implementation
│   │   ├── ChatBotService.cls-meta.xml
│   │   ├── ChatBotControllerTest.cls  # 9 test methods with HttpCalloutMock
│   │   └── ChatBotControllerTest.cls-meta.xml
│   ├── objects/AI_Provider_Setting__mdt/
│   │   ├── AI_Provider_Setting__mdt.object-meta.xml
│   │   └── fields/Api_Key__c.field-meta.xml
│   └── remoteSiteSettings/
│       ├── OpenRouter.remoteSite-meta.xml        # https://openrouter.ai
│       ├── DeepSeek.remoteSite-meta.xml          # https://api.deepseek.com
│       └── SalesforcePlatformApi.remoteSite-meta.xml # https://api.salesforce.com
```
