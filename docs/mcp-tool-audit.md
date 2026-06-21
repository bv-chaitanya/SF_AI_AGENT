# MCP Tool Exposure Audit: "sobject-all" → DeepSeek

> Session log — pick up from here next time.
> Date: 2026-06-21

## Goal

Investigate how the "sobject-all" MCP tool is declared and exposed to DeepSeek in this codebase. Report file paths, line numbers, and code excerpts for each item.

---

## 1. Where the `tools` array sent to DeepSeek is built

**File:** `ChatBotController.cls:83-99`

```apex
// Line 83-85: MCP tools fetched and passed to the AI call
List<Object> tools = ChatBotService.getTools();
if (tools == null) return 'Could not retrieve MCP tools.';
...
// Line 99: tools sent to DeepSeek/OpenRouter with every turn
String body = ChatBotService.callAi(provider, model, apiKey, msgs, tools);
```

**File:** `ChatBotService.cls:424-445` — the `buildTools()` method transforms MCP schemas into OpenAI function format:

```apex
private static List<Object> buildTools(String jsonStr) {
    List<Object> result = new List<Object>();
    Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(jsonStr);
    Map<String, Object> rm = (Map<String, Object>) root.get('result');
    List<Object> tools = rm == null ? null : (List<Object>) rm.get('tools');
    for (Object t : tools) {
        Map<String, Object> tool = (Map<String, Object>) t;
        String d = (String) tool.get('description');
        if (d != null && d.length() > 1200) d = d.substring(0, 1200);
        Object schema = tool.get('inputSchema');
        if (schema == null) schema = new Map<String, Object>{ 'type' => 'object' };
        result.add(new Map<String, Object>{
            'type' => 'function',
            'function' => new Map<String, Object>{
                'name' => tool.get('name'), 'description' => d, 'parameters' => schema
            }
        });
    }
    return result;
}
```

**What DeepSeek sees for each tool:**

```json
{
  "type": "function",
  "function": {
    "name": "<mcp_tool_name>",
    "description": "<truncated to 1200 chars>",
    "parameters": { }
  }
}
```

The `parameters` schema is the raw `inputSchema` from the MCP server — full JSON Schema with `type`, `properties`, `required`, etc. The only transformation is description truncation at 1200 characters.

---

## 2. Dynamically fetched, not hardcoded

The tool schemas come from the MCP server at runtime, zero hardcoding:

```
getTools()                                       ChatBotService.cls:125-131
  ├── callMcp('tools/list', null)                ChatBotService.cls:127
  │   └── POST callout:Salesforce_MCP/.../tools/list
  │       (MCP server returns all 11 tool definitions with schemas)
  └── buildTools(toolsListJson)                  ChatBotService.cls:129
      └── Wraps each MCP tool in {type:"function",function:{...}} format
```

After first fetch, cached in `cachedTools` (static variable) for the transaction. The exact tool names, descriptions, and parameter schemas are whatever the MCP server returns — they change if Salesforce updates the MCP server.

```apex
// ChatBotService.cls:125-131
public static List<Object> getTools() {
    if (cachedTools != null && !cachedTools.isEmpty()) return cachedTools;
    if (cachedToolsJson == null) cachedToolsJson = callMcp('tools/list', null);
    if (cachedToolsJson == null) return null;
    cachedTools = buildTools(cachedToolsJson);
    return cachedTools;
}
```

---

## 3. Raw query / SOQL-like filter parameter

The MCP `tools/list` response includes a tool called `soqlQuery` (and possibly others for record CRUD). The exact parameter schemas are determined by the MCP server, not this codebase.

Based on Salesforce's MCP documentation, the `soqlQuery` tool accepts:

```json
{
  "name": "soqlQuery",
  "description": "Execute a SOQL query against your Salesforce data...",
  "parameters": {
    "type": "object",
    "properties": {
      "q": {
        "type": "string",
        "description": "The SOQL query to execute"
      }
    },
    "required": ["q"]
  }
}
```

**The parameter DeepSeek sees for raw queries is `q`** — a free-text SOQL string. There is NO additional filtering, allowlisting, or schema validation in the Apex code before forwarding.

---

## 4. Tool call arguments: zero validation before MCP

**File:** `ChatBotController.cls:102-107`

```apex
List<ChatBotService.McpToolCall> tcs = ChatBotService.parseAllToolCalls(body);
if (tcs.isEmpty()) return ChatBotService.extractContent(body);

for (ChatBotService.McpToolCall tc : tcs) {
    Map<String, Object> p = new Map<String, Object>{'name' => tc.name, 'arguments' => tc.arguments };
    String result = ChatBotService.extractToolResult(ChatBotService.callMcp('tools/call', p));
```

The arguments from DeepSeek (`tc.arguments`) are:

1. Deserialized from JSON in `parseAllNative` (`ChatBotService.cls:378-379`)
2. Stored as an `Object` (can be `Map<String,Object>` or `String`)
3. Passed **directly** into `callMcp('tools/call', p)` — no inspection, no validation, no sanitization

**Full chain:**

```
parseAllNative()                                   ChatBotService.cls:362-383
  └── fn.get('arguments') →                      Line 378
      args instanceof String
        ? JSON.deserializeUntyped((String) args)   Line 379
        : args                                     Line 379 (if already object)
      → tc.arguments = result

Controller loop:                                  ChatBotController.cls:105-107
  Map<String, Object> p = {
    'name' => tc.name,              // forwarded as-is
    'arguments' => tc.arguments     // forwarded as-is
  }
  → callMcp('tools/call', p)
```

**Plain answer: NO validation, allowlisting, sanitization, or rewriting of any kind.** DeepSeek can propose ANY tool name and ANY arguments. The MCP server is the sole gatekeeper — it validates the tool name, parameter schema, and enforces FLS/sharing.

---

## 5. MCP server side — not in this repo

There is **no MCP server implementation in this codebase**. The MCP server is hosted by Salesforce at:

```
https://api.salesforce.com/platform/mcp/v1/platform/sobject-all
```

Per AGENTS.md:

> **Salesforce Platform MCP Server (platform.sobject-all)**
> - URL: `https://api.salesforce.com/platform/mcp/v1/platform/sobject-all` (hosted by Salesforce, NOT the npm DX package)
> - 11 tools + 2 prompts, Active by default in Developer Edition

The `sobject-all` MCP server is a managed service. How it builds SOQL queries internally (bind variables vs. string concatenation) is not visible in this repo. The Apex code sends `{name: "soqlQuery", arguments: {q: "SELECT..."}}` via JSON-RPC and the server handles execution.

The `SF CLI MCP` `@salesforce/mcp` npm package referenced in AGENTS.md is the **open-source CLI integration**, not the server — it's used by the opencode editor, not by this chatbot.

---

## 6. Per-object / per-field restrictions

**None in Apex code.** There is no:

- Object denylist (e.g., blocking `User`, `SetupAuditTrail`)
- Field denylist (e.g., blocking `password__c`, `ssn__c`)
- Profile-based filtering beyond standard FLS
- Argument pattern matching (e.g., stripping `WHERE` clauses)
- Rate limiting of tool calls per second

**What exists:**

- The MCP server enforces the OAuth user's standard FLS (field-level security) and sharing rules — the bot can't access records or fields the logged-in user can't
- The `with sharing` keyword on both Apex classes (`ChatBotController.cls:1`, `ChatBotService.cls:1`) enforces sharing rules on any Apex-side data access (though most data access is through MCP, not Apex)
- The only Apex-side validation is that `tc.name` must be non-null (`ChatBotService.cls:374`)

---

## 7. All tools in the `tools` array

The exact list of 11 tools is returned by the MCP server at runtime. Based on Salesforce's MCP platform documentation, the tools available on `platform.sobject-all` are:

| Tool | What it does |
|------|-------------|
| `soqlQuery` | Execute any SOQL query (`q` parameter) |
| `getObjectSchema` | Describe object(s) — fields, types, relationships |
| `createRecord` | Insert an SObject record |
| `updateRecord` | Update an SObject record by ID |
| `deleteRecord` | Delete an SObject record by ID |
| `getRelatedRecords` | Get child/parent records via relationship name |
| `searchRecords` | SOSL search across objects |
| `getRecord` | Fetch a single record by ID |
| `describeGlobal` | List all accessible SObjects |
| `queryMore` | Pagination for large query results |
| `executeAnonymous` | Run Apex anonymous block (if enabled) |

**None of these tool schemas are hardcoded in the repo.** They are fetched dynamically via `tools/list` and forwarded to DeepSeek exactly as returned. The only transformation is description truncation to 1200 characters.

---

## Summary

| Concern | Status | Where |
|---------|--------|-------|
| Tool schemas hardcoded? | **No** — fetched from MCP server | `ChatBotService.cls:125-131` |
| Arguments validated before MCP? | **No** — passed through as-is | `ChatBotController.cls:106` |
| Object/field allowlisting? | **No** — none in Apex | — |
| SOQL injection risk? | **Trusts MCP server's validation** | `ChatBotController.cls:107` |
| Raw SOQL string accepted? | **Yes** — `soqlQuery` accepts `{q: "SELECT..."}` | Per MCP schema |
| Additional tools beyond query? | **Yes** — CRUD, schema, describe, search | Full list above |
| MCP server implementation? | **Not in this repo** | Hosted by Salesforce |

---

## Next Steps

- [ ] Consider adding an Apex-side allowlist for sensitive objects (User, SetupAuditTrail, etc.)
- [ ] Consider adding argument validation before `callMcp('tools/call', p)`
- [ ] Consider logging tool name + arguments for audit trail
- [ ] Revisit after org upgrades to API v64+ (Named Credentials with ApiKey protocol)
