public with sharing class ChatBotController {

    @AuraEnabled
    public static String sendMessage(String userMessage, String provider, String model, String conversationSummary, String contextRecordsJson) {
        String jsonResp = initChat(userMessage, null, provider, model, conversationSummary, contextRecordsJson);
        for (Integer i = 0; i < 5; i++) {
            Map<String, Object> step = (Map<String, Object>) JSON.deserializeUntyped(jsonResp);
            String type = (String) step.get('type');
            if (type == 'answer' || type == 'error') return (String) step.get('text');
            String toolName = (String) step.get('toolName');
            String toolResult = (String) step.get('toolResult');
            jsonResp = continueChat(toolName, toolResult);
        }
        return 'Action completed.';
    }

    @AuraEnabled
    public static ChatBotService.ChatResponse sendMessageDetailed(String userMessage, String recordId, String provider, String model, String conversationSummary, String contextRecordsJson) {
        ChatBotService.resetState();
        String json = initChat(userMessage, recordId, provider, model, conversationSummary, contextRecordsJson);
        return buildFromJson(json);
    }

    @AuraEnabled
    public static ChatBotService.ChatResponse summarizeCurrentRecordDetailed(String recordId, String provider, String model) {
        ChatBotService.resetState();
        String answer = summarize(recordId, provider, model);
        ChatBotService.ChatResponse r = new ChatBotService.ChatResponse();
        r.answer = answer; r.usedTool = true;
        r.model = ChatBotService.aiModel; r.provider = ChatBotService.aiProvider;
        return r;
    }

    @AuraEnabled
    public static String getRecordInfo(String recordId) {
        try {
            Id rid = Id.valueOf(recordId);
            String objName = rid.getSObjectType().getDescribe().getName();
            String nameField = objName == 'Case' ? 'CaseNumber' : 'Name';
            List<SObject> records = Database.query(
                'SELECT Id, ' + nameField + ' FROM ' + objName + ' WHERE Id = :rid LIMIT 1');
            if (records.isEmpty()) return null;
            SObject rec = records[0];
            String name = objName == 'Case'
                ? (String) rec.get('CaseNumber') + ' - ' + (String) rec.get('Subject')
                : (String) rec.get('Name');
            if (String.isBlank(name)) name = objName;
            return JSON.serialize(new Map<String, String>{
                'id' => rec.Id, 'name' => name, 'objectType' => objName });
        } catch (Exception e) { return null; }
    }

    @AuraEnabled
    public static String searchRecords(String query) {
        if (String.isBlank(query) || query.length() < 2) return '[]';
        String term = '*' + String.escapeSingleQuotes(query).replace('*', '\\*') + '*';
        try {
            List<List<SObject>> results = Search.query(
                'FIND :term IN NAME FIELDS RETURNING ' +
                'Account(Id, Name LIMIT 5), Contact(Id, Name LIMIT 5), ' +
                'Opportunity(Id, Name LIMIT 5), Lead(Id, Name LIMIT 5), ' +
                'Case(Id, CaseNumber, Subject LIMIT 5)');
            List<Map<String, String>> items = new List<Map<String, String>>();
            for (List<SObject> soList : results) {
                for (SObject so : soList) {
                    String objName = so.getSObjectType().getDescribe().getName();
                    String label = objName == 'Case'
                        ? (String) so.get('CaseNumber') + ' - ' + (String) so.get('Subject')
                        : (String) so.get('Name');
                    if (String.isBlank(label)) label = objName;
                    items.add(new Map<String, String>{
                        'id' => so.Id, 'name' => label, 'objectType' => objName });
                }
            }
            return JSON.serialize(items);
        } catch (Exception e) { return '[]'; }
    }

    @AuraEnabled
    public static String getAvailableModels() {
        Map<String, Object> m = new Map<String, Object>();
        m.put('OpenRouter', new List<String>{
            'nex-agi/nex-n2-pro:free', 'nvidia/nemotron-3-super-120b-a12b:free',
            'google/gemma-4-31b-it:free', 'openrouter/free',
            'deepseek/deepseek-chat', 'deepseek/deepseek-r1',
            'anthropic/claude-3.5-haiku', 'google/gemini-2.0-flash-001' });
        m.put('DeepSeek', new List<String>{ 'deepseek-chat', 'deepseek-reasoner' });
        return JSON.serialize(m);
    }

    @AuraEnabled
    public static String getMcpToolList() {
        if (!ChatBotService.initMcp())
            return '{"error":"MCP init failed"}';
        String r = ChatBotService.callMcp('tools/list', null);
        return r != null ? r : '{"error":"No tools"}';
    }

    @AuraEnabled
    public static String debugMcpConnection() {
        return JSON.serialize(new Map<String, Object>{
            'initSuccess' => ChatBotService.initMcp(),
            'lastError' => ChatBotService.lastMcpError
        }, true);
    }

    @AuraEnabled
    public static String initChat(String userMessage, String recordId, String provider, String model, String conversationSummary, String contextRecordsJson) {
        ChatBotService.resetState();
        ChatBotService.activeMessages = new List<Map<String, Object>>();
        ChatBotService.activeProvider = provider;
        ChatBotService.activeModel = model;

        if (String.isBlank(userMessage))
            return JSON.serialize(new Map<String, Object>{'type' => 'error', 'text' => 'Please enter a message.'});

        String apiKey = ChatBotService.getApiKey(provider);
        if (apiKey == null)
            return JSON.serialize(new Map<String, Object>{'type' => 'error', 'text' => provider + ' API key not configured.'});
        ChatBotService.setActiveApiKey(apiKey);

        if (!ChatBotService.initMcp())
            return JSON.serialize(new Map<String, Object>{'type' => 'error', 'text' => 'MCP init failed'});

        ChatBotService.activeTools = ChatBotService.getTools();
        if (ChatBotService.activeTools == null)
            return JSON.serialize(new Map<String, Object>{'type' => 'error', 'text' => 'Could not retrieve MCP tools.'});

        List<Map<String, Object>> msgs = ChatBotService.activeMessages;
        msgs.add(ChatBotService.msg('system',
            'Salesforce assistant. When user asks to create/update/delete — DO it immediately using the appropriate tool. ' +
            'Never say you\'ll do something and then not do it. If the user gives vague input (like "any name"), ' +
            'use reasonable defaults. Don\'t ask for confirmation unless the request is ambiguous. Keep replies brief.'));

        String rid = ChatBotService.normalizeRecordId(recordId);
        if (rid != null) {
            msgs.add(ChatBotService.msg('system',
                'Context: ' + ChatBotService.getObjectApiName(rid) + ' (' + rid + '). Only for "this"/"current"/"it".'));
        }
        if (!String.isBlank(conversationSummary))
            msgs.add(ChatBotService.msg('system', 'Recent: ' + conversationSummary));
        String ctxText = ChatBotService.buildContextText(contextRecordsJson);
        if (!String.isBlank(ctxText)) msgs.add(ChatBotService.msg('system', ctxText));
        msgs.add(ChatBotService.msg('user', userMessage));

        return callAndCheck();
    }

    @AuraEnabled
    public static String continueChat(String toolName, String toolResults) {
        List<Map<String, Object>> msgs = ChatBotService.activeMessages;
        if (msgs == null || msgs.isEmpty()) return '{"type":"error","text":"No active conversation."}';

        ChatBotService.executedToolName = toolName;
        ChatBotService.executedToolArguments = toolResults;
        ChatBotService.executedTools.add(new Map<String, String>{
            'name' => toolName, 'arguments' => toolResults });

        msgs.add(new Map<String, Object>{
            'role' => 'assistant', 'content' => null,
            'tool_calls' => new List<Map<String, Object>>{
                new Map<String, Object>{
                    'id' => 'call_0', 'type' => 'function',
                    'function' => new Map<String, Object>{
                        'name' => toolName, 'arguments' => toolResults
                    }
                }
            }
        });
        msgs.add(new Map<String, Object>{
            'role' => 'tool', 'tool_call_id' => 'call_0', 'content' => toolResults
        });

        return callAndCheck();
    }

    private static String callAndCheck() {
        List<Map<String, Object>> msgs = ChatBotService.activeMessages;
        String body = ChatBotService.callAi(ChatBotService.activeProvider, ChatBotService.activeModel,
            ChatBotService.getActiveApiKey(), msgs, ChatBotService.activeTools);
        if (body == null)
            return JSON.serialize(new Map<String, Object>{
                'type' => 'answer', 'text' => 'AI unavailable.' });

        List<ChatBotService.McpToolCall> toolCalls = ChatBotService.parseAllToolCalls(body);
        if (toolCalls.isEmpty()) {
            String answer = ChatBotService.extractContent(body);
            ChatBotService.aiModel = ChatBotService.activeModel;
            ChatBotService.aiProvider = ChatBotService.activeProvider;
            return JSON.serialize(new Map<String, Object>{
                'type' => 'answer', 'text' => answer,
                'model' => ChatBotService.aiModel,
                'provider' => ChatBotService.aiProvider,
                'streamChunks' => ChatBotService.streamChunks
            });
        }

        ChatBotService.McpToolCall tc = toolCalls[0];
        ChatBotService.executedToolName = tc.name;
        ChatBotService.executedToolArguments = JSON.serialize(tc.arguments);
        Map<String, Object> params = new Map<String, Object>{
            'name' => tc.name, 'arguments' => tc.arguments };
        String result = ChatBotService.extractToolResult(ChatBotService.callMcp('tools/call', params));

        msgs.add(new Map<String, Object>{
            'role' => 'assistant', 'content' => null,
            'tool_calls' => new List<Map<String, Object>>{
                new Map<String, Object>{
                    'id' => tc.id, 'type' => 'function',
                    'function' => new Map<String, Object>{
                        'name' => tc.name, 'arguments' => JSON.serialize(tc.arguments)
                    }
                }
            }
        });
        msgs.add(new Map<String, Object>{
            'role' => 'tool', 'tool_call_id' => tc.id, 'content' => result
        });

        ChatBotService.executedTools.add(new Map<String, String>{
            'name' => tc.name, 'arguments' => (String) JSON.serialize(tc.arguments) });

        return JSON.serialize(new Map<String, Object>{
            'type' => 'tool',
            'toolName' => tc.name,
            'toolArgs' => tc.arguments,
            'toolResult' => result
        });
    }

    private static ChatBotService.ChatResponse buildFromJson(String jsonText) {
        Map<String, Object> step = (Map<String, Object>) JSON.deserializeUntyped(jsonText);
        ChatBotService.ChatResponse r = new ChatBotService.ChatResponse();
        r.answer = (String) step.get('text');
        r.model = (String) step.get('model');
        r.provider = (String) step.get('provider');
        r.streamChunks = (List<String>) step.get('streamChunks');
        r.toolName = (String) step.get('toolName');
        r.usedTool = !ChatBotService.executedTools.isEmpty();
        return r;
    }

    private static String extractTextFromChatJson(String jsonText) {
        Map<String, Object> step = (Map<String, Object>) JSON.deserializeUntyped(jsonText);
        return (String) step.get('text');
    }

    private static String summarize(String recordId, String provider, String model) {
        String validId = ChatBotService.normalizeRecordId(recordId);
        if (validId == null) return 'Open on a record page to summarize.';
        String obj = ChatBotService.getObjectApiName(validId);
        String apiKey = ChatBotService.getApiKey(provider);
        if (String.isBlank(apiKey)) return 'API key not configured.';
        if (!ChatBotService.initMcp()) return 'MCP init failed.';

        String query = 'SELECT FIELDS(ALL) FROM ' + obj + ' WHERE Id = \'' + validId + '\' LIMIT 1';
        Map<String, Object> params = new Map<String, Object>{
            'name' => 'soqlQuery', 'arguments' => new Map<String, Object>{ 'q' => query } };
        ChatBotService.executedToolName = 'soqlQuery';
        String toolResult = ChatBotService.extractToolResult(ChatBotService.callMcp('tools/call', params));

        List<Map<String, Object>> msgs = new List<Map<String, Object>>();
        msgs.add(ChatBotService.msg('system', 'Summarize this ' + obj + ' record concisely.'));
        msgs.add(ChatBotService.msg('user', 'Data:\n' + toolResult));

        String body = ChatBotService.callAi(provider, model, apiKey, msgs, null);
        return body != null ? ChatBotService.extractContent(body) : 'Tool result: ' + toolResult;
    }
}
