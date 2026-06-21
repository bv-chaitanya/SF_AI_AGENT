# LinkedIn Post: Building an AI Chatbot in Salesforce with Platform MCP + OpenRouter

I built an LWC chatbot inside Salesforce Developer Edition that chats with users about their records, analyzes them with an LLM (via OpenRouter), and reads/updates data through the Salesforce Platform MCP server — safely.

Here's the exact setup that worked. No theory, just the steps.

---

## What I built

A Lightning Web Component where a user types a question ("List my top 10 accounts", "Summarize open opportunities over 50K"). Apex calls OpenRouter for the LLM reasoning, the LLM proposes a tool call, Apex executes it against the Salesforce Platform MCP server, then the LLM summarizes the result in plain language.

## The 7 setup steps that actually worked

### 1. Enable the Salesforce Platform MCP Server
- Setup → MCP Servers → open `platform.sobject-all`
- Confirm Status = **Active** (it is by default in Developer Edition)
- Server URL: `https://api.salesforce.com/platform/mcp/v1/platform/sobject-all`
- Note: 11 curated tools + 2 prompts are exposed out of the box

### 2. Create an External Client App (replaces Connected Apps)
Salesforce moved away from Connected Apps — use External Client Manager now.
- Setup → External Client Manager → New
- External Client App Name: `SF MCP Auth`
- API Name: `SF_MCP_Auth`
- Contact Email: your email
- Distribution State: `Local`
- Check **Enable OAuth**
  - Callback URL: `https://<your-org>.my.salesforce.com/services/authcallback/SF_MCP_Auth`
  - **Critical scopes** (the one that took me 4 attempts to find):
    - `Access and manage your data (api)`
    - `Perform requests at any time (refresh_token, offline_access)`
    - **`Access Salesforce hosted MCP servers (mcp_api)`** ← this is the one most people miss
- Also enable: **Issue JSON Web Token (JWT)-based access tokens for named users**
- Save → note the Consumer Key and Consumer Secret

### 3. Create an Auth Provider
- Setup → Auth Providers → New
- Provider Type: **Salesforce**
- Name: `SF_MCP_Auth`
- Consumer Key / Secret: from Step 2
- Authorize Endpoint URL: `https://login.salesforce.com/services/oauth2/authorize`
- Token Endpoint URL: `https://login.salesforce.com/services/oauth2/token`
- Default Scope: `api refresh_token mcp_api`
- Save

### 4. Create a Named Credential (legacy type still works)
- Setup → Named Credentials → New
- Label / Name: `Salesforce_MCP` (must match exactly — Apex references it as `callout:Salesforce_MCP`)
- URL: `https://api.salesforce.com`
- Identity Type: **Named Principal**
- Authentication Protocol: **OAuth 2.0**
- Authorization Provider: `SF_MCP_Auth` (from Step 3)
- Scope: `api refresh_token mcp_api`
- Check **Start Authentication Flow on Save**
- Save → browser opens → log in → click Allow
- Verify Authentication Status = **Authenticated**

### 5. The MCP protocol handshake (the gotcha that cost me a day)
The Salesforce Platform MCP server follows the standard MCP spec — you can't just call `tools/list` directly. You MUST:
1. Send an `initialize` request with protocol version `2025-03-26` and client info
2. Capture the `Mcp-Session-Id` **response header** (Apex `getHeader()` is case-sensitive — search header keys case-insensitively or you'll miss it)
3. Send a `notifications/initialized` notification
4. Only THEN call `tools/list` or `tools/call`, including the `Mcp-Session-Id` header on every request

Skip step 1 and you get: `"Session Key missing, but it's not an initialize request"` (HTTP 400).
Skip the header and you get: `"Invalid token"` (HTTP 401).

### 6. Wire up OpenRouter for the LLM brain
- Get an API key from https://openrouter.ai/keys
- Store it in a Custom Metadata Type record (Setup → Custom Metadata Types → OpenRouter Setting → Manage Records → New → Label "Default", API Key = your key)
- Never commit the key to source

The controller now prefers `nex-agi/nex-n2-pro:free` for agentic, structured tool use, then retries free Nemotron, Gemma, and `openrouter/free` fallbacks. Successful responses must contain message content or a native tool call; otherwise Apex tries the next model. If every option is rate-limited, the user gets a clear temporary-unavailability message instead of a blank chat bubble.

### 7. Apex = MCP client + OpenRouter orchestrator
The flow on each user message:
1. `initialize` MCP session (once per request — cache the session ID)
2. `tools/list` to get the 11 available tools
3. Convert MCP schemas into native OpenRouter function tools and send them with the user message (`nex-agi/nex-n2-pro:free` first)
4. LLM responds with a native function call containing the tool name and arguments
5. `tools/call` on the MCP server to execute it
6. Send tool result back to OpenRouter for a plain-language summary
7. Return summary to the LWC

### 8. Render readable responses in the LWC
The final polish was replacing plain-text output with `lightning-formatted-rich-text`. Normal model answers can now display headings, lists, bold text, and inline code. If a free model is rate-limited during the final summarization call, the LWC recognizes the structured MCP fallback JSON and renders nested fields and record collections as labeled lists instead of exposing a raw JSON blob. Dynamic values are HTML-escaped before rendering, and the Salesforce base component sanitizes the rich text.

### 9. Add record-page context and one-click summaries
On Lightning record pages, Salesforce automatically supplies the LWC's public `recordId`. The component passes that ID to a context-aware Apex method with every message, so phrases such as "this record" and "current record" have an explicit meaning. A record-page-only **Ask for Summary** button sends a focused request to retrieve the current record through MCP and summarize its important fields and status. The system prompt explicitly requires an MCP lookup before answering, preventing the model from inventing details based only on an ID.

## Safety model
- The LLM only PROPOSES a tool call — it never touches the database
- Apex validates and forwards to the MCP server
- The MCP server's 11 tools are curated by Salesforce
- The OAuth token carries the user's `api` + `mcp_api` scopes — the bot can't access anything the user can't
- The OpenRouter API key lives in Custom Metadata, never in source code

## What I'd tell my past self
- `UserInfo.getSessionId()` does NOT work for `api.salesforce.com` MCP calls — you need a real OAuth flow
- The `mcp_api` OAuth scope is non-obvious and the docs are JS-rendered (can't be scraped) — add it upfront
- The MCP handshake is mandatory — `initialize` first, then `notifications/initialized`, then everything else with the `Mcp-Session-Id` header
- Apex `getHeader('Mcp-Session-Id')` returns null even when the header exists — iterate `getHeaderKeys()` and compare case-insensitively
- "Invalid token" from the MCP server can mean either (a) missing `mcp_api` scope, or (b) missing session ID — check both

## Stack
- Salesforce Developer Edition (free)
- Platform MCP server `platform.sobject-all` (hosted by Salesforce)
- OpenRouter free-model chain led by `nex-agi/nex-n2-pro:free` (API key still required; free-tier availability and rate limits apply)
- External Client Manager + Auth Provider + Named Credential (OAuth 2.0)
- LWC + Apex (Apex is the MCP client)
- Custom Metadata Type for the OpenRouter key

## Try it
Ask the bot: "List my top 10 accounts by name", "Show contacts where LastName starts with Smith", "Summarize the open opportunities over 50000".

---

#Salesforce #MCP #ModelContextProtocol #OpenRouter #LWC #Apex #Agentforce #AI #DeveloperEdition #SalesforceDevelopment
