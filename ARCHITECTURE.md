# SF AI Agent — Architecture & Data Flow

## System Overview

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                        Salesforce Developer Edition Org                       │
│                                                                              │
│  ┌──────────────────────────────────┐     ┌──────────────────────────────┐  │
│  │          LWC (chatBot)           │     │        Salesforce Setup        │  │
│  │  ┌────────────────────────────┐  │     │  ┌──────────────────────────┐ │  │
│  │  │ Provider/Model Selectors   │  │     │  │ Named Credential         │ │  │
│  │  │  DeepSeek / OpenRouter     │  │     │  │  Salesforce_MCP (OAuth)  │ │  │
│  │  ├────────────────────────────┤  │     │  │  → External Client App   │ │  │
│  │  │ Chat Messages (bubbles)    │  │     │  │  → Auth Provider         │ │  │
│  │  │  User ← → Bot              │  │     │  │  → Scopes: api,mcp_api  │ │  │
│  │  ├────────────────────────────┤  │     │  └──────────────────────────┘ │  │
│  │  │ Tool Call Cards            │  │     │  ┌──────────────────────────┐ │  │
│  │  │  ✓ getObjectSchema         │  │     │  │ Custom Metadata Type     │ │  │
│  │  │  ✓ createRecord            │  │     │  │  AI_Provider_Setting__mdt│ │  │
│  │  ├────────────────────────────┤  │     │  │  → DeepSeek: sk-xxx      │ │  │
│  │  │ Context Records (chips)    │  │     │  │  → OpenRouter: sk-or-xxx │ │  │
│  │  │  [ACC] Acme Corp ×  [+]    │  │     │  └──────────────────────────┘ │  │
│  │  ├────────────────────────────┤  │     │  ┌──────────────────────────┐ │  │
│  │  │ Input + Send Button        │  │     │  │ Remote Site Settings     │ │  │
│  │  └────────────────────────────┘  │     │  │  → api.deepseek.com      │ │  │
│  └──────────┬───────────────────────┘     │  │  → openrouter.ai         │ │  │
│             │ @AuraEnabled                │  │  → api.salesforce.com    │ │  │
│             ▼                             │  └──────────────────────────┘ │  │
│  ┌──────────────────────────────────┐     └──────────────────────────────┘  │
│  │    ChatBotController.cls          │                                       │
│  │    (Orchestration - 153 lines)    │                                       │
│  │  ┌────────────────────────────┐  │                                       │
│  │  │ sendMessageDetailed()      │  │                                       │
│  │  │ processMessage() loop      │──┼───────────────────────┐               │
│  │  │ summarize()                │  │                       │               │
│  │  │ getRecordInfo()            │  │                       │               │
│  │  │ searchRecords() (SOSL)     │  │                       │               │
│  │  │ getAvailableModels()       │  │                       │               │
│  │  └────────────────────────────┘  │                       │               │
│  └──────────┬───────────────────────┘                       │               │
│             │ delegates to                                  │               │
│             ▼                                               │               │
│  ┌──────────────────────────────────┐                       │               │
│  │    ChatBotService.cls             │                       │               │
│  │    (Implementation - 490 lines)   │                       │               │
│  │  ┌────────────────────────────┐  │                       │               │
│  │  │ AI Provider Layer          │  │                       │               │
│  │  │  callAi() → dispatch       │──┼───────┐               │               │
│  │  │  callDeepSeek() + Stream   │  │       │               │               │
│  │  │  callOpenRouter() + Chain  │  │       │               │               │
│  │  │  parseAllToolCalls()       │  │       │               │               │
│  │  │  parseStreamChunks() (SSE) │  │       │               │               │
│  │  ├────────────────────────────┤  │       │               │               │
│  │  │ MCP Client Layer           │  │       │               │               │
│  │  │  initMcp() handshake       │  │       │               │               │
│  │  │  callMcp('tools/...')      │──┼───────┼───────────────┘               │
│  │  │  extractToolResult()       │  │       │                               │
│  │  │  getTools() cache          │  │       │                               │
│  │  ├────────────────────────────┤  │       │                               │
│  │  │ Credential Layer           │  │       │                               │
│  │  │  lookupApiKey() CMDT       │  │       │                               │
│  │  │  doAiPost() Bearer header  │  │       │                               │
│  │  │  doMcpPost() NC callout    │  │       │                               │
│  │  └────────────────────────────┘  │       │                               │
│  └──────────────────────────────────┘       │                               │
└─────────────────────────────────────────────┼───────────────────────────────┼──┘
                                              │                               │
                    ┌─────────────────────────┘          ┌────────────────────┘
                    ▼                                    ▼
     ┌──────────────────────────┐          ┌──────────────────────────────┐
     │   DeepSeek / OpenRouter   │          │   Salesforce Platform MCP    │
     │   api.deepseek.com        │          │   api.salesforce.com         │
     │   openrouter.ai           │          │   /platform/mcp/v1/          │
     │                            │          │   platform/sobject-all       │
     │  Auth: Bearer sk-xxx       │          │   Auth: OAuth (Named Cred)   │
     │  SSE: stream=true          │          │   Header: Mcp-Session-Id     │
     │                            │          │                               │
     │  /v1/chat/completions      │          │   11 curated tools:           │
     │  → messages[]              │          │   soqlQuery, createRecord,   │
     │  → tools[] (MCP schemas)   │          │   updateRecord, deleteRecord,│
     │  → function_call response  │          │   getObjectSchema, etc.      │
     │  ← tool_calls[].function   │          └──────────────────────────────┘
     │  ← content (plain text)    │
     └──────────────────────────┘
```

---

## Message Flow (One User Request)

```
USER: "create a contact on this account"
│
▼
┌─ LWC chatBot.js ──────────────────────────────────────────────────┐
│ 1. addUserMessage(text)                                           │
│ 2. buildConversationSummary() → "User asked: create contact..."   │
│ 3. sendMessageDetailed({ userMessage, recordId, provider, model,  │
│      conversationSummary, contextRecordsJson })                   │
└───────────────────────────────────────────────────────────────────┘
│ @AuraEnabled
▼
┌─ ChatBotController.processMessage() ──────────────────────────────┐
│ 4. lookupApiKey('DeepSeek') → CMDT → sk-xxx                       │
│ 5. initMcp() → POST initialize to MCP → get Mcp-Session-Id       │
│ 6. getTools() → POST tools/list → build OpenAI function schemas   │
│ 7. Build messages[]: system prompt + record context + user msg    │
│                                                                   │
│ ┌─── TOOL LOOP (max 5 turns) ─────────────────────────────────┐  │
│ │ 8. callAi(provider, model, apiKey, msgs, tools)              │  │
│ │    └→ POST https://api.deepseek.com/v1/chat/completions      │  │
│ │       Header: Authorization Bearer sk-xxx                    │  │
│ │       Body: { model, messages, tools, stream:false }         │  │
│ │                                                               │  │
│ │ 9. AI returns: { choices[0].message.tool_calls: [            │  │
│ │      { function: { name:"getObjectSchema",                   │  │
│ │        arguments: { objects: "Contact" } } } ] }             │  │
│ │                                                               │  │
│ │ 10. parseAllToolCalls() → McpToolCall(name, id, arguments)   │  │
│ │                                                               │  │
│ │ 11. callMcp('tools/call', { name, arguments })               │  │
│ │     └→ POST callout:Salesforce_MCP/.../tools/call            │  │
│ │        (Named Credential auto-adds OAuth Bearer)             │  │
│ │        ← { result: { content: [{ type:"text",               │  │
│ │             text: "Contact object schema..." }] } }           │  │
│ │                                                               │  │
│ │ 12. extractToolResult() → extracts text content               │  │
│ │                                                               │  │
│ │ 13. Add tool result to messages[] (role: "tool")             │  │
│ │     Loop back to step 8 with updated messages                 │  │
│ │                                                               │  │
│ │ 14. AI returns: { choices[0].message.content:               │  │
│ │      "Created contact John Doe (003xx)" }                    │  │
│ │     parseAllToolCalls → empty → EXIT LOOP                    │  │
│ └──────────────────────────────────────────────────────────────┘  │
│                                                                   │
│ 15. extractContent() → "Created contact John Doe (003xx)"        │
│ 16. buildResponse() → ChatResponse { answer, toolName,           │
│       usedToolsJson, model, provider, streamChunks }              │
└───────────────────────────────────────────────────────────────────┘
│ returns
▼
┌─ LWC chatBot.js ──────────────────────────────────────────────────┐
│ 17. showToolsThenAnswer(toolList, 0, result)                      │
│     └─ Each tool card appears with 400ms stagger:                 │
│        "getObjectSchema objects=Contact" → ✓ Done                 │
│        "createRecord FirstName=John..." → ✓ Done                  │
│                                                                   │
│ 18. addBotMessage(answer, model, toolName, provider, streamChunks)│
│     └─ typewriterChunks() renders text word-by-word               │
│        "Created | contact | John | Doe | (003xx)"                 │
└───────────────────────────────────────────────────────────────────┘
│
▼
USER SEES: ✓ getObjectSchema → ✓ createRecord → "Created contact John Doe (003xx)"
```

---

## Credential Architecture

```
┌───────────────────────────────────────────────────────────────┐
│                     TWO SEPARATE CREDENTIAL PATHS              │
│                                                               │
│  PATH A: AI Provider Auth (DeepSeek/OpenRouter)               │
│  ───────────────────────────────────                          │
│  CMDT AI_Provider_Setting__mdt                                │
│  ├── Record: MasterLabel="DeepSeek"                           │
│  │   Api_Key__c = "sk-abc123..."                              │
│  └── Record: MasterLabel="OpenRouter"                         │
│      Api_Key__c = "sk-or-v1-xyz789..."                        │
│           │                                                   │
│           ▼                                                   │
│  ChatBotService.lookupApiKey("DeepSeek")                      │
│           │                                                   │
│           ▼                                                   │
│  doAiPost(): req.setHeader('Authorization', 'Bearer ' + key)  │
│           │                                                   │
│           ▼                                                   │
│  POST https://api.deepseek.com/v1/chat/completions            │
│  (Remote Site Setting: api.deepseek.com)                      │
│                                                               │
│  ⚠ Key stored in CMDT → read by Apex → sent as Bearer header │
│    (API v62 doesn't support ApiKey Named Credentials)         │
│                                                               │
├───────────────────────────────────────────────────────────────┤
│                                                               │
│  PATH B: MCP Auth (Salesforce Platform)                        │
│  ─────────────────────────────────                            │
│  External Client App: "SF MCP Auth"                           │
│  ├── OAuth scopes: api, refresh_token, mcp_api               │
│  └── JWT-based access tokens enabled                          │
│           │                                                   │
│  Auth Provider: "SF_MCP_Auth" (Salesforce type)               │
│           │                                                   │
│           ▼                                                   │
│  Named Credential: "Salesforce_MCP"                           │
│  ├── URL: https://api.salesforce.com                           │
│  ├── Identity: Named Principal                                │
│  ├── Protocol: OAuth 2.0                                      │
│  └── Scope: api refresh_token mcp_api                         │
│           │                                                   │
│           ▼                                                   │
│  doMcpPost(): req.setEndpoint('callout:Salesforce_MCP/...')   │
│  (Salesforce auto-injects OAuth Bearer token)                 │
│           │                                                   │
│           ▼                                                   │
│  POST https://api.salesforce.com/platform/mcp/v1/...          │
│                                                               │
│  ✓ Token never visible in Apex code                            │
│  ✓ Named Credential handles token lifecycle                    │
│  ✓ MCP enforces user's object/field-level security             │
└───────────────────────────────────────────────────────────────┘
```

---

## Class Diagram

```
┌──────────────────────────────────────┐
│        ChatBotController             │
│        (with sharing)                │
├──────────────────────────────────────┤
│ + sendMessage(...): String           │
│ + sendMessageDetailed(...): Response │
│ + summarizeRecordDetailed(...)       │
│ + getRecordInfo(id): String          │
│ + searchRecords(q): String           │
│ + getAvailableModels(): String       │
│ + getMcpToolList(): String           │
├──────────────────────────────────────┤
│ - processMessage(...): String        │
│ - summarize(...): String             │
│ - buildResponse(...): Response       │
└──────────┬───────────────────────────┘
           │ delegates to
           ▼
┌──────────────────────────────────────┐     ┌──────────────────────────────┐
│        ChatBotService                │     │        Inner Classes          │
│        (with sharing)                │     ├──────────────────────────────┤
├──────────────────────────────────────┤     │ McpToolCall                  │
│ # OPENROUTER_URL, DEEPSEEK_URL       │     │  + name: String              │
│ # MCP_SERVER_URL                     │     │  + id: String                │
│ # HTTP_TIMEOUT, AI_TIMEOUT           │     │  + arguments: Object         │
│ # OPENROUTER_FREE_MODELS             │     ├──────────────────────────────┤
├──────────────────────────────────────┤     │ ChatResponse                 │
│ [Credential Layer]                   │     │  + answer: String            │
│ + lookupApiKey(provider): String     │     │  + usedTool: Boolean         │
│                                      │     │  + toolName: String          │
│ [MCP Client Layer]                   │     │  + toolArguments: String     │
│ + initMcp(): Boolean                 │     │  + usedToolsJson: String     │
│ + callMcp(method, params): String    │     │  + model: String             │
│ + getTools(): List<Object>           │     │  + provider: String          │
│ + extractToolResult(json): String    │     │  + streamChunks: List<String>│
│                                      │     └──────────────────────────────┘
│ [AI Provider Layer]                  │
│ + callAi(provider,model,key,msgs,tools)│
│ + parseAllToolCalls(body): List<TC>  │
│ + extractContent(body): String       │
│ + buildContextText(json): String     │
│ + msg(role, content): Map            │
 ├──────────────────────────────────────┤
 │ - callOpenAiCompatible(prv,m,k,url,  │
 │       msgs,tools): String            │
 │ - buildOpenRouterChain(model): List  │
 │ - doAiPost(url,key,body,or): Resp    │
 │ - doMcpPost(body): Response          │
 │ - buildRpc(method,params): Map       │
 │ - parseAllNative(body): List<TC>     │
 │ - parseTagToolCall(content): TC      │
 │ - parseStreamChunks(sse): List<Str>  │
 │ - extractContentOrNull(body): Str    │
 │ - fmtErr(body): String               │
 │ - buildTools(json): List<Object>     │
 │ - extractSseData(body): String       │
 │ - findHeaderInsensitive(res,name)    │
 │ - extractSessionId(body): String     │
 │ - joinChunks(chunks): String         │
 ├──────────────────────────────────────┤
 │ @TestVisible state:                  │
 │ + testModelsMap                      │
 │ + testProviderConfigs                │
 │ + toolsListResponse                  │
 │ + toolCallResponse, mcpInitResponse  │
 │ + mcpSessionIdOverride               │
 │ + lastMcpError, lastAiError          │
│ + executedToolName, executedToolArgs │
│ + executedTools: List<Map>           │
│ + aiModel, aiProvider, streamChunks  │
└──────────────────────────────────────┘
           │
           ▼
┌──────────────────────────────────────────┐
│           External Systems                │
├──────────────────────────────────────────┤
│  DeepSeek API                            │
│  POST /v1/chat/completions               │
│  Auth: Bearer sk-xxx                     │
│  stream: true (SSE deltas)               │
├──────────────────────────────────────────┤
│  OpenRouter API                          │
│  POST /api/v1/chat/completions           │
│  Auth: Bearer sk-or-xxx                  │
│  Free model chain fallback               │
├──────────────────────────────────────────┤
│  Salesforce Platform MCP                 │
│  POST /platform/mcp/v1/.../sobject-all   │
│  Auth: OAuth (Named Credential)          │
│  11 tools: query, CRUD, schema, etc.     │
│  Protocol: JSON-RPC 2.0 + SSE            │
└──────────────────────────────────────────┘
```

---

## MCP Protocol Handshake

```
Apex                                    Salesforce MCP Server
 │                                               │
 │  POST initialize                               │
 │  { "jsonrpc":"2.0", "id":1,                   │
 │    "method":"initialize",                      │
 │    "params":{ "protocolVersion":"2025-03-26",  │
 │      "clientInfo":{ "name":"SF ChatBot" } } }  │
 │ ──────────────────────────────────────────────▶│
 │                                               │
 │  ← Mcp-Session-Id: abc-123                    │
 │  { "result":{ "protocolVersion":"2025-03-26", │
 │      "serverInfo":{...}, "capabilities":{...}│
 │    } }                                         │
 │ ◀──────────────────────────────────────────────│
 │                                               │
 │  POST notifications/initialized                │
 │  { "jsonrpc":"2.0", "method":                 │
 │    "notifications/initialized" }               │
 │  Header: Mcp-Session-Id: abc-123              │
 │ ──────────────────────────────────────────────▶│
 │  (no response expected)                        │
 │                                               │
 │  POST tools/list                               │
 │  Header: Mcp-Session-Id: abc-123              │
 │ ──────────────────────────────────────────────▶│
 │                                               │
 │  ← { "result":{ "tools":[                     │
 │        { "name":"soqlQuery", ... },            │
 │        { "name":"createRecord", ... },         │
 │        ...11 tools...                          │
 │      ] } }                                     │
 │ ◀──────────────────────────────────────────────│
 │                                               │
 │  POST tools/call                               │
 │  { "method":"tools/call",                     │
 │    "params":{ "name":"createRecord",           │
 │      "arguments":{ "sobject":"Contact",        │
 │        "LastName":"Doe" } } }                  │
 │  Header: Mcp-Session-Id: abc-123              │
 │ ──────────────────────────────────────────────▶│
 │                                               │
 │  ← { "result":{ "content":[                   │
 │        { "type":"text",                        │
 │          "text":"Created: 003xx" }             │
 │      ] } }                                     │
 │ ◀──────────────────────────────────────────────│
```

---

## Streaming (SSE) Architecture

```
Apex doAiPost()                             DeepSeek API
 │                                               │
 │  POST /v1/chat/completions                    │
 │  { "model":"deepseek-chat",                   │
 │    "stream":true, "messages":[...] }           │
 │ ──────────────────────────────────────────────▶│
 │                                               │
 │  ← SSE stream begins                          │
 │  data: {"choices":[{"delta":                  │
 │    {"content":"Created"}}]}                    │
 │  ◀──────────────────────────────────────────────│
 │                                               │
 │  data: {"choices":[{"delta":                  │
 │    {"content":" contact"}}]}                   │
 │  ◀──────────────────────────────────────────────│
 │                                               │
 │  data: {"choices":[{"delta":                  │
 │    {"content":" John"}}]}                      │
 │  ◀──────────────────────────────────────────────│
 │                                               │
 │  ... more deltas ...                           │
 │                                               │
 │  data: [DONE]                                  │
 │  ◀──────────────────────────────────────────────│
 │                                               │
 │  parseStreamChunks() splits by \n\n           │
 │  → ["Created", " contact", " John", ...]       │
 │  → joinChunks() → "Created contact John"       │
 │                                               │
 │  Returns to LWC as streamChunks[]              │
 │  LWC typewriterChunks() renders word-by-word  │
 │  with blinking | cursor at 15-40ms intervals   │
```
