public with sharing class ChatBotService {

    private static final String MCP_SERVER_URL = 'callout:Salesforce_MCP/platform/mcp/v1/platform/sobject-all';
    private static final Integer HTTP_TIMEOUT = 60000;
    private static final Integer AI_TIMEOUT = 30000;

    @TestVisible public static Map<String, List<String>> testModelsMap;
    @TestVisible public static String toolsListResponse;
    @TestVisible public static String toolCallResponse;
    @TestVisible public static String mcpInitResponse;
    @TestVisible public static String mcpSessionIdOverride;
    @TestVisible public static String lastMcpError;
    @TestVisible public static String lastAiError;
    @TestVisible public static Map<String, ProviderConfig> testProviderConfigs;

    private static String sessionId;
    private static String cachedToolsJson;
    private static List<Object> cachedTools;
    private static Map<String, ProviderConfig> providerConfigCache;

    public class ProviderConfig {
        @TestVisible public String apiKey;
        @TestVisible public String baseUrl;
        public ProviderConfig(String key, String url) { apiKey = key; baseUrl = url; }
    }

    public static String executedToolName;
    public static String executedToolArguments;
    public static List<Map<String, String>> executedTools = new List<Map<String, String>>();
    public static String aiModel;
    public static String aiProvider;
    public static List<String> streamChunks;

    public static ProviderConfig getProviderConfig(String provider) {
        if (providerConfigCache != null && providerConfigCache.containsKey(provider)) {
            return providerConfigCache.get(provider);
        }
        ProviderConfig config;
        if (testProviderConfigs != null && testProviderConfigs.containsKey(provider)) {
            config = testProviderConfigs.get(provider);
        } else {
            List<AI_Provider_Setting__mdt> settings = [
                SELECT Api_Key__c, Base_Url__c FROM AI_Provider_Setting__mdt
                WHERE MasterLabel = :provider AND Is_Active__c = true LIMIT 1
            ];
            if (settings.isEmpty()) {
                config = null;
            } else {
                config = new ProviderConfig(settings[0].Api_Key__c, settings[0].Base_Url__c);
            }
        }
        if (providerConfigCache == null) providerConfigCache = new Map<String, ProviderConfig>();
        providerConfigCache.put(provider, config);
        return config;
    }

    public static List<String> fetchModelsList(String baseUrl, String apiKey) {
        List<String> models = new List<String>();
        if (String.isBlank(baseUrl) || String.isBlank(apiKey)) return models;
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(baseUrl + '/models');
            req.setMethod('GET');
            req.setHeader('Authorization', 'Bearer ' + apiKey);
            req.setHeader('Accept', 'application/json');
            req.setTimeout(AI_TIMEOUT);
            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
                lastAiError = 'models HTTP ' + res.getStatusCode();
                return models;
            }
            Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            List<Object> data = (List<Object>) root.get('data');
            if (data == null) return models;
            for (Object m : data) {
                Map<String, Object> mo = (Map<String, Object>) m;
                String id = (String) mo.get('id');
                if (String.isNotBlank(id)) models.add(id);
            }
        } catch (Exception e) {
            lastAiError = 'fetchModels: ' + e.getMessage();
        }
        return models;
    }

    public static String normalizeRecordId(String recordId) {
        if (String.isBlank(recordId)) return null;
        try { return String.valueOf(Id.valueOf(recordId.trim())); }
        catch (Exception e) { return null; }
    }

    public static String getObjectApiName(String recordId) {
        return Id.valueOf(recordId).getSObjectType().getDescribe().getName();
    }

    public static void resetState() {
        executedToolName = null;
        executedToolArguments = null;
        executedTools.clear();
        aiModel = null;
        aiProvider = null;
        streamChunks = null;
        providerConfigCache = null;
    }

    public static Boolean initMcp() {
        if (sessionId != null) return true;
        if (mcpSessionIdOverride != null) { sessionId = mcpSessionIdOverride; return true; }

        Map<String, Object> rpcBody = buildRpc('initialize', new Map<String, Object>{
            'protocolVersion' => '2025-03-26',
            'capabilities' => new Map<String, Object>(),
            'clientInfo' => new Map<String, Object>{ 'name' => 'SF ChatBot', 'version' => '1.0.0' }
        });

        try {
            HttpResponse res = doMcpPost(rpcBody);
            if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
                lastMcpError = 'Initialize HTTP ' + res.getStatusCode() + ': ' + res.getBody();
                return false;
            }
            sessionId = findHeaderInsensitive(res, 'mcp-session-id');
            if (sessionId == null) {
                String body = res.getBody();
                if (body.startsWith('event:') || body.contains('data:')) body = extractSseData(body);
                if (mcpInitResponse != null) body = mcpInitResponse;
                sessionId = extractSessionId(body);
                if (sessionId == null) {
                    lastMcpError = 'No session ID found. Headers: ' + res.getHeaderKeys()
                        + '. Body: ' + body.substring(0, Math.min(500, body.length()));
                    return false;
                }
            }
            sendMcpNotification('notifications/initialized');
            return true;
        } catch (Exception e) {
            lastMcpError = 'Init exception: ' + e.getTypeName() + ': ' + e.getMessage();
            return false;
        }
    }

    public static String callMcp(String method, Map<String, Object> params) {
        if (method == 'tools/list' && toolsListResponse != null) return toolsListResponse;
        if (method == 'tools/call' && toolCallResponse != null) return toolCallResponse;

        try {
            HttpResponse res = doMcpPost(buildRpc(method, params));
            if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
                lastMcpError = 'HTTP ' + res.getStatusCode() + ': ' + res.getBody();
                return null;
            }
            String body = res.getBody();
            return (body.startsWith('event:') || body.contains('data:')) ? extractSseData(body) : body;
        } catch (Exception e) {
            lastMcpError = e.getTypeName() + ': ' + e.getMessage();
            return null;
        }
    }

    public static List<Object> getTools() {
        if (cachedTools != null && !cachedTools.isEmpty()) return cachedTools;
        if (cachedToolsJson == null) cachedToolsJson = callMcp('tools/list', null);
        if (cachedToolsJson == null) return null;
        cachedTools = buildTools(cachedToolsJson);
        return cachedTools;
    }

    public static String extractToolResult(String jsonStr) {
        if (jsonStr == null) return 'No response from MCP server. Error: ' + lastMcpError;
        try {
            Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(jsonStr);
            Map<String, Object> rm = (Map<String, Object>) root.get('result');
            if (rm == null) rm = root;
            List<Object> content = (List<Object>) rm.get('content');
            if (content != null && !content.isEmpty()) {
                List<String> texts = new List<String>();
                for (Object c : content) {
                    Map<String, Object> item = (Map<String, Object>) c;
                    if ('text' == item.get('type')) texts.add((String) item.get('text'));
                }
                return String.join(texts, '\n');
            }
            return (Boolean) rm.get('isError') == true
                ? 'Tool error: ' + JSON.serialize(rm)
                : JSON.serialize(rm);
        } catch (Exception e) { return jsonStr; }
    }

    public static String callAi(String provider, String model, String apiKey, String baseUrl,
            List<Map<String, Object>> messages, List<Object> tools) {
        lastAiError = null;
        Boolean useStream = (tools == null || tools.isEmpty());
        Boolean isDeepSeek = (provider == 'DeepSeek');
        Boolean isOpenRouter = (provider == 'OpenRouter');

        Map<String, Object> body = new Map<String, Object>{
            'model' => model, 'messages' => messages,
            'temperature' => 0.2, 'max_tokens' => 2048, 'stream' => useStream
        };
        if (isDeepSeek) {
            body.put('user_id', 'sf-' + EncodingUtil.convertToHex(
                Crypto.generateDigest('SHA-256', Blob.valueOf(UserInfo.getUserId()))
            ).substring(0, 16));
        }
        if (tools != null && !tools.isEmpty()) { body.put('tools', tools); body.put('tool_choice', 'auto'); }

        List<String> modelChain = isOpenRouter ? buildOpenRouterChain(model) : new List<String>{ model };
        for (String m : modelChain) {
            body.put('model', m);
            try {
                HttpResponse res = doAiPost(baseUrl + '/chat/completions', apiKey, body, isOpenRouter);
                if (res.getStatusCode() >= 200 && res.getStatusCode() < 300) {
                    if (useStream) {
                        List<String> chunks = parseStreamChunks(res.getBody());
                        String answer = joinChunks(chunks);
                        if (String.isNotBlank(answer)) {
                            aiModel = m; aiProvider = provider; streamChunks = chunks; return answer;
                        }
                        lastAiError = m + ' empty';
                    } else if (String.isNotBlank(extractContentOrNull(res.getBody()))
                        || !parseAllNative(res.getBody()).isEmpty()) {
                        aiModel = m; aiProvider = provider; return res.getBody();
                    }
                    lastAiError = m + ' empty';
                } else {
                    lastAiError = m + ' HTTP ' + res.getStatusCode() + fmtErr(res.getBody());
                }
            } catch (Exception e) { lastAiError = m + ': ' + e.getMessage(); }
        }
        return null;
    }

    private static List<String> buildOpenRouterChain(String model) {
        List<String> freeModels = new List<String>{
            'nex-agi/nex-n2-pro:free',
            'nvidia/nemotron-3-super-120b-a12b:free',
            'google/gemma-4-31b-it:free',
            'openrouter/free'
        };
        Integer idx = freeModels.indexOf(model);
        if (idx < 0) return new List<String>{ model };
        List<String> chain = new List<String>();
        for (Integer i = idx; i < freeModels.size(); i++) chain.add(freeModels[i]);
        return chain;
    }

    public static List<McpToolCall> parseAllToolCalls(String responseBody) {
        List<McpToolCall> result = parseAllNative(responseBody);
        if (!result.isEmpty()) return result;
        McpToolCall tag = parseTagToolCall(extractContentOrNull(responseBody));
        return tag != null ? new List<McpToolCall>{ tag } : result;
    }

    public static String extractContent(String responseBody) {
        String c = extractContentOrNull(responseBody);
        return String.isBlank(c) ? 'The model returned an empty response.' : c;
    }

    public static String buildContextText(String contextJson) {
        if (String.isBlank(contextJson)) return null;
        try {
            List<Object> records = (List<Object>) JSON.deserializeUntyped(contextJson);
            if (records == null || records.isEmpty()) return null;
            List<String> lines = new List<String>();
            lines.add('Context records (ref by name/ID when relevant):');
            for (Object item : records) {
                Map<String, Object> r = (Map<String, Object>) item;
                lines.add('- ' + r.get('objectType') + ': ' + r.get('name')
                    + (r.get('id') != null ? ' (' + r.get('id') + ')' : ''));
            }
            return String.join(lines, '\n');
        } catch (Exception e) { return null; }
    }

    public static Map<String, Object> msg(String role, String content) {
        return new Map<String, Object>{ 'role' => role, 'content' => content };
    }

    public static String truncate(String text, Integer maxLen) {
        if (text == null) return null;
        return text.length() > maxLen ? text.substring(0, maxLen) + '\n...(truncated)' : text;
    }

    private static Map<String, Object> buildRpc(String method, Map<String, Object> params) {
        Map<String, Object> rpc = new Map<String, Object>();
        rpc.put('jsonrpc', '2.0');
        rpc.put('id', 1);
        rpc.put('method', method);
        rpc.put('params', params != null ? params : new Map<String, Object>());
        return rpc;
    }

    private static final Integer NOTIFICATION_TIMEOUT = 5000;

    private static HttpResponse doMcpPost(Map<String, Object> body) {
        return doMcpPost(body, HTTP_TIMEOUT);
    }

    private static HttpResponse doMcpPost(Map<String, Object> body, Integer timeoutMs) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(MCP_SERVER_URL);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json, text/event-stream');
        if (sessionId != null) req.setHeader('Mcp-Session-Id', sessionId);
        req.setBody(JSON.serialize(body));
        req.setTimeout(timeoutMs);
        return new Http().send(req);
    }

    private static void sendMcpNotification(String method) {
        try { doMcpPost(buildRpc(method, null), NOTIFICATION_TIMEOUT); }
        catch (Exception e) { lastMcpError = 'Notification ' + method + ' failed: ' + e.getMessage(); }
    }

    private static String extractSseData(String body) {
        for (String line : body.split('\n')) {
            if (line.startsWith('data:')) return line.substring(5).trim();
        }
        return body;
    }

    private static String extractSessionId(String body) {
        try {
            Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(body);
            Map<String, Object> result = (Map<String, Object>) root.get('result');
            if (result != null) {
                if (result.get('sessionId') != null) return (String) result.get('sessionId');
                if (result.get('sessionKey') != null) return (String) result.get('sessionKey');
                if (result.get('id') != null) return String.valueOf(result.get('id'));
            }
            return (String) root.get('sessionId');
        } catch (Exception e) { return null; }
    }

    private static String findHeaderInsensitive(HttpResponse res, String name) {
        for (String key : res.getHeaderKeys()) {
            if (key != null && key.toLowerCase() == name.toLowerCase()) return res.getHeader(key);
        }
        return null;
    }

    private static HttpResponse doAiPost(String url, String apiKey, Map<String, Object> body, Boolean openRouter) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(url);
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + apiKey);
        req.setHeader('Content-Type', 'application/json');
        if (openRouter) {
            req.setHeader('HTTP-Referer', 'https://salesforce.lightning.force.com');
            req.setHeader('X-Title', 'SF ChatBot');
        }
        req.setBody(JSON.serialize(body));
        req.setTimeout(AI_TIMEOUT);
        return new Http().send(req);
    }

    private static String extractContentOrNull(String body) {
        try {
            Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(body);
            List<Object> choices = (List<Object>) root.get('choices');
            if (choices == null || choices.isEmpty()) return null;
            Map<String, Object> msg = (Map<String, Object>) ((Map<String, Object>) choices[0]).get('message');
            return msg == null ? null : (String) msg.get('content');
        } catch (Exception e) { return null; }
    }

    private static String fmtErr(String body) {
        try {
            Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(body);
            Map<String, Object> err = (Map<String, Object>) root.get('error');
            String msg1 = err == null ? null : (String) err.get('message');
            return String.isBlank(msg1) ? '' : ': ' + msg1.substring(0, Math.min(180, msg1.length()));
        } catch (Exception e) { return ''; }
    }

    private static List<McpToolCall> parseAllNative(String body) {
        List<McpToolCall> result = new List<McpToolCall>();
        try {
            Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(body);
            List<Object> choices = (List<Object>) root.get('choices');
            if (choices == null || choices.isEmpty()) return result;
            Map<String, Object> msg = (Map<String, Object>) ((Map<String, Object>) choices[0]).get('message');
            List<Object> tcList = msg == null ? null : (List<Object>) msg.get('tool_calls');
            if (tcList == null || tcList.isEmpty()) return result;
            for (Object tc : tcList) {
                Map<String, Object> tcMap = (Map<String, Object>) tc;
                Map<String, Object> fn = (Map<String, Object>) tcMap.get('function');
                if (fn == null || fn.get('name') == null) continue;
                McpToolCall call = new McpToolCall();
                call.name = (String) fn.get('name');
                call.id = (String) tcMap.get('id');
                Object args = fn.get('arguments');
                call.arguments = args instanceof String ? JSON.deserializeUntyped((String) args) : args;
                if (call.arguments == null) call.arguments = new Map<String, Object>();
                result.add(call);
            }
        } catch (Exception e) { lastAiError = 'parseAllNative: ' + e.getMessage(); }
        return result;
    }

    private static McpToolCall parseTagToolCall(String content) {
        if (content == null) return null;
        String lt = String.fromCharArray(new List<Integer>{ 60 });
        String gt = String.fromCharArray(new List<Integer>{ 62 });
        String startTag = lt + 'tool_call' + gt;
        String endTag = lt + '/tool_call' + gt;
        if (!content.contains(startTag)) return null;
        Integer startPos = content.indexOf(startTag) + startTag.length();
        Integer endPos = content.indexOf(endTag);
        if (endPos <= startPos) return null;
        try {
            String block = content.substring(startPos, endPos).trim();
            Map<String, Object> p = (Map<String, Object>) JSON.deserializeUntyped(block);
            McpToolCall call = new McpToolCall();
            call.name = (String) p.get('name');
            if (call.name == null) return null;
            call.arguments = p.get('arguments');
            return call;
        } catch (Exception e) { return null; }
    }

    private static List<Object> buildTools(String jsonStr) {
        List<Object> result = new List<Object>();
        try {
            Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(jsonStr);
            Map<String, Object> rm = (Map<String, Object>) root.get('result');
            List<Object> tools = rm == null ? null : (List<Object>) rm.get('tools');
            if (tools == null) return result;
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
        } catch (Exception e) { lastAiError = 'Tool conversion error: ' + e.getMessage(); }
        return result;
    }

    private static List<String> parseStreamChunks(String sseBody) {
        List<String> chunks = new List<String>();
        if (String.isBlank(sseBody)) return chunks;
        for (String block : sseBody.split('\n\n')) {
            String t = block.trim();
            if (t.startsWith('data:') && t != 'data: [DONE]') {
                String jsonStr = t.substring(5).trim();
                if (jsonStr == '[DONE]') continue;
                try {
                    Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(jsonStr);
                    List<Object> choices = (List<Object>) root.get('choices');
                    if (choices == null || choices.isEmpty()) continue;
                    Map<String, Object> delta = (Map<String, Object>) ((Map<String, Object>) choices[0]).get('delta');
                    if (delta == null) continue;
                    String content = (String) delta.get('content');
                    if (String.isNotBlank(content)) chunks.add(content);
                } catch (Exception e) { lastAiError = 'parseStreamChunks: ' + e.getMessage(); }
            }
        }
        return chunks;
    }

    private static String joinChunks(List<String> chunks) {
        return chunks == null || chunks.isEmpty() ? '' : String.join(chunks, '');
    }

    public class McpToolCall {
        @AuraEnabled public String name;
        @AuraEnabled public String id;
        @AuraEnabled public Object arguments;
    }

    public class ChatResponse {
        @AuraEnabled public String answer;
        @AuraEnabled public Boolean usedTool;
        @AuraEnabled public String toolName;
        @AuraEnabled public String toolArguments;
        @AuraEnabled public String usedToolsJson;
        @AuraEnabled public String model;
        @AuraEnabled public String provider;
        @AuraEnabled public List<String> streamChunks;
    }
}
