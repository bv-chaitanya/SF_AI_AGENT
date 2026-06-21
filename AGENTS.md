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
sf apex run test --class-names ChatBotControllerTest --target-org venkatachaitanyabhimisetty@gmail.com --wait 3
```

## Salesforce Org
- **Org**: Developer Edition, `venkatachaitanyabhimisetty@gmail.com`
- **Instance**: `chap-dev-ed.my.salesforce.com`
- **Login**: `sf org login web --instance-url https://login.salesforce.com --set-default`

## AI Providers (dynamic, OpenAI-compatible)
All provider config lives in `AI_Provider_Setting__mdt` CMDT — one record per provider:
- `MasterLabel` — provider display name (e.g. Neuralwatt, DeepSeek, OpenRouter)
- `Api_Key__c` — bearer token (must be set manually in Setup; never committed to source)
- `Base_Url__c` — OpenAI-compatible base URL (Apex appends `/chat/completions` and `/models`)
- `Is_Active__c` — UI visibility flag; only `true` records appear in the dropdown

### Key security model
- **No API keys in source control.** CMDT records deploy with empty `Api_Key__c`. Admins set the real key manually in Setup → Custom Code → Custom Metadata → AI Provider Settings → Manage Records → Edit → set Api_Key__c → Save.
- Apex adds `Authorization: Bearer <key>` header manually. Remote Site Settings still gate each host.

### To add a new provider
1. Add a `CustomMetadata` record (e.g. `AI_Provider_Setting.NewProvider.md`) with `Base_Url__c` set, `Api_Key__c` empty, `Is_Active__c` = true
2. Add a `RemoteSiteSetting` for the host
3. Deploy, then set `Api_Key__c` manually in Setup
4. Done — Apex and LWC pick it up automatically; no code changes needed

### How models are loaded
- `ChatBotService.fetchModelsList(baseUrl, apiKey)` calls `GET <baseUrl>/models` (standard OpenAI-compatible endpoint)
- `ChatBotController.getAvailableModels()` iterates active CMDT records and returns `{providerName: [modelId, ...]}` as JSON
- LWC uses first provider + first model as the default

### Provider config caching
- One `ProviderConfig` inner class holds both `apiKey` + `baseUrl` (avoids redundant SOQL)
- `getProviderConfig(provider)` does a single SOQL: `SELECT Api_Key__c, Base_Url__c FROM AI_Provider_Setting__mdt WHERE MasterLabel = :provider AND Is_Active__c = true`
- Result cached in static `providerConfigCache` for the transaction
- `@TestVisible testProviderConfigs` map lets tests inject fake config without SOQL

### Provider-specific extras (handled in `callAi()`)
- **OpenRouter**: sends `HTTP-Referer` + `X-Title` headers; free models chain fallback
- **DeepSeek**: sends `user_id` (SHA-256 of `UserInfo.getUserId()`, truncated) for rate-limit privacy

### Recommended provider base URLs
| Provider | Base URL | Notes |
|----------|----------|-------|
| Neuralwatt | `https://api.neuralwatt.com/v1` | OpenAI-compatible, GLM/Kimi/Qwen models |
| DeepSeek | `https://api.deepseek.com` | Note: no `/v1` suffix per their docs |
| OpenRouter | `https://openrouter.ai/api/v1` | OpenAI-compatible, 300+ models |

### Why no Named Credentials for AI providers?
This org edition does not support the `ApiKey` authentication protocol on External Credentials (confirmed via deploy error). Legacy Named Credentials with `NoAuthentication` protocol only hold the URL — they don't encrypt the key — so they add complexity without security benefit. CMDT + RSS is simpler and equivalent. When the org supports ApiKey ECs, replace each CMDT Api_Key pair with a single NamedCredential (type `SecuredEndpoint`, referencing an ExternalCredential with `authenticationProtocol=ApiKey`). The bearer token would then be stored encrypted in the ExternalCredential, and Apex could drop the manual `Authorization` header.

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
- **Run tests**: `sf apex run test --class-names <class> --wait <minutes>`
- **`sfdx-project.json`**: Still the standard config file name — not renamed to `sf-project.json`

## LWC Architecture
- **`chatBot`** component — supports `AppPage`, `RecordPage`, `HomePage` targets
- Uses native HTML `<input>`, `<select>`, `<button>` elements with custom SLDS-styled CSS classes
- **Provider + Model selectors** in UI — user picks any active provider, then the model
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
├── docs/mcp-tool-audit.md             # MCP tool exposure audit
├── .gitignore
├── .gitattributes
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
│   │   ├── ChatBotControllerTest.cls  # 11 test methods with HttpCalloutMock
│   │   └── ChatBotControllerTest.cls-meta.xml
│   ├── objects/AI_Provider_Setting__mdt/
│   │   ├── AI_Provider_Setting__mdt.object-meta.xml
│   │   └── fields/
│   │       ├── Api_Key__c.field-meta.xml
│   │       ├── Base_Url__c.field-meta.xml
│   │       └── Is_Active__c.field-meta.xml
│   └── remoteSiteSettings/
│       ├── OpenRouter.remoteSite-meta.xml        # https://openrouter.ai
│       ├── DeepSeek.remoteSite-meta.xml          # https://api.deepseek.com
│       ├── Neuralwatt.remoteSite-meta.xml        # https://api.neuralwatt.com
│       └── SalesforcePlatformApi.remoteSite-meta.xml # https://api.salesforce.com
```
