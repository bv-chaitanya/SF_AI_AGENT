public with sharing class ChatBotController {

    @AuraEnabled
    public static String sendMessage(String userMessage, String provider, String model, String conversationSummary, String contextRecordsJson) {
        ChatBotService.resetState();
        return processMessage(userMessage, null, provider, model, conversationSummary, contextRecordsJson);
    }

    @AuraEnabled
    public static ChatBotService.ChatResponse sendMessageDetailed(String userMessage, String recordId, String provider, String model, String conversationSummary, String contextRecordsJson) {
        ChatBotService.resetState();
        String answer = processMessage(userMessage, recordId, provider, model, conversationSummary, contextRecordsJson);
        return buildResponse(answer);
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
            List<SObject> records = Database.query('SELECT Id, ' + nameField + ' FROM ' + objName + ' WHERE Id = :rid LIMIT 1');
            if (records.isEmpty()) return '{}';
            SObject rec = records[0];
            String name = objName == 'Case' ? (String) rec.get('CaseNumber') + ' - ' + (String) rec.get('Subject') : (String) rec.get('Name');
            if (String.isBlank(name)) name = objName;
            return JSON.serialize(new Map<String, String>{'id' => rec.Id, 'name' => name, 'objectType' => objName });
        } catch (Exception e) { return '{}'; }
    }

    @AuraEnabled
    public static String searchRecords(String query) {
        if (String.isBlank(query) || query.length() < 2) return '[]';
        try {
            String term = '*' + query + '*';
            List<List<SObject>> results = Search.query('FIND :term IN NAME FIELDS RETURNING Account(Id, Name LIMIT 5), Contact(Id, Name LIMIT 5), Opportunity(Id, Name LIMIT 5), Lead(Id, Name LIMIT 5), Case(Id, CaseNumber, Subject LIMIT 5)');
            List<Map<String, String>> items = new List<Map<String, String>>();
            for (List<SObject> soList : results) {
                for (SObject so : soList) {
                    String objName = so.getSObjectType().getDescribe().getName();
                    String label = objName == 'Case' ? (String) so.get('CaseNumber') + ' - ' + (String) so.get('Subject') : (String) so.get('Name');
                    if (String.isBlank(label)) label = objName;
                    items.add(new Map<String, String>{'id' => so.Id, 'name' => label, 'objectType' => objName });
                }
            }
            return JSON.serialize(items);
        } catch (Exception e) { return '[]'; }
    }

    @AuraEnabled
    public static String getAvailableModels() {
        if (ChatBotService.testModelsMap != null) return JSON.serialize(ChatBotService.testModelsMap);
        Map<String, Object> result = new Map<String, Object>();
        try {
            for (AI_Provider_Setting__mdt s : [
                SELECT MasterLabel, Api_Key__c, Base_Url__c
                FROM AI_Provider_Setting__mdt
                WHERE Is_Active__c = true
            ]) {
                if (String.isBlank(s.Base_Url__c) || String.isBlank(s.Api_Key__c)) continue;
                List<String> models = ChatBotService.fetchModelsList(s.Base_Url__c, s.Api_Key__c);
                if (!models.isEmpty()) result.put(s.MasterLabel, models);
            }
        } catch (Exception e) { System.debug('getAvailableModels error: ' + e.getMessage()); }
        return JSON.serialize(result);
    }

    @AuraEnabled
    public static String getMcpToolList() {
        if (!ChatBotService.initMcp()) return '{"error":"MCP init failed"}';
        String r = ChatBotService.callMcp('tools/list', null);
        return r != null ? r : '{"error":"No tools"}';
    }

    private static String processMessage(String userMessage, String recordId, String provider, String model, String conversationSummary, String contextRecordsJson) {
        if (String.isBlank(userMessage)) return 'Please enter a message.';

        ChatBotService.ProviderConfig config = ChatBotService.getProviderConfig(provider);
        String apiKey = config != null ? config.apiKey : null;
        String baseUrl = config != null ? config.baseUrl : null;
        if (String.isBlank(apiKey)) return provider + ' API key not configured. Set Api_Key__c on the AI_Provider_Setting__mdt record in Setup.';
        if (String.isBlank(baseUrl)) return provider + ' Base URL not configured. Set Base_Url__c on the AI_Provider_Setting__mdt record in Setup.';

        if (!ChatBotService.initMcp()) return 'MCP init failed: ' + ChatBotService.lastMcpError;

        List<Object> tools = ChatBotService.getTools();
        if (tools == null) return 'Could not retrieve MCP tools. Error: ' + ChatBotService.lastMcpError;

        List<Map<String, Object>> msgs = new List<Map<String, Object>>();
        msgs.add(ChatBotService.msg('system',
            'Salesforce assistant. When user asks to create/update/delete — DO it immediately using the appropriate tool. ' +
            'Never say you\'ll do something and then not do it. If the user gives vague input ("any name"), ' +
            'use reasonable defaults. Don\'t ask for confirmation unless ambiguous. Keep replies brief.'));
        if (recordId != null)
            msgs.add(ChatBotService.msg('system', 'Context: ' + ChatBotService.getObjectApiName(recordId) + ' (' + recordId + '). Only for "this"/"current"/"it".'));
        if (!String.isBlank(conversationSummary))
            msgs.add(ChatBotService.msg('system', 'Recent: ' + conversationSummary));
        String ctxText = ChatBotService.buildContextText(contextRecordsJson);
        if (!String.isBlank(ctxText)) msgs.add(ChatBotService.msg('system', ctxText));
        msgs.add(ChatBotService.msg('user', userMessage));

        for (Integer turn = 0; turn < 5; turn++) {
            String body = ChatBotService.callAi(provider, model, apiKey, baseUrl, msgs, tools);
            if (body == null) return 'AI unavailable: ' + ChatBotService.lastAiError;

            List<ChatBotService.McpToolCall> tcs = ChatBotService.parseAllToolCalls(body);
            if (tcs.isEmpty()) return ChatBotService.extractContent(body);

            for (ChatBotService.McpToolCall tc : tcs) {
                Map<String, Object> p = new Map<String, Object>{'name' => tc.name, 'arguments' => tc.arguments };
                String result = ChatBotService.extractToolResult(ChatBotService.callMcp('tools/call', p));

                ChatBotService.executedToolName = tc.name;
                ChatBotService.executedToolArguments = JSON.serialize(tc.arguments);
                ChatBotService.executedTools.add(new Map<String, String>{'name' => tc.name, 'arguments' => JSON.serialize(tc.arguments) });

                msgs.add(new Map<String, Object>{'role' => 'assistant', 'content' => null, 'tool_calls' => new List<Map<String, Object>>{ new Map<String, Object>{'id' => tc.id, 'type' => 'function', 'function' => new Map<String, Object>{'name' => tc.name, 'arguments' => JSON.serialize(tc.arguments) } } } });
                msgs.add(new Map<String, Object>{'role' => 'tool', 'tool_call_id' => tc.id, 'content' => ChatBotService.truncate(result, 8000) });
            }
        }

        String body = ChatBotService.callAi(provider, model, apiKey, baseUrl, msgs, null);
        return body != null ? ChatBotService.extractContent(body) : 'Action completed but AI could not summarize. Error: ' + ChatBotService.lastAiError;
    }

    private static String summarize(String recordId, String provider, String model) {
        String vid = ChatBotService.normalizeRecordId(recordId);
        if (vid == null) return 'Open on a record page to summarize.';
        String obj = ChatBotService.getObjectApiName(vid);
        ChatBotService.ProviderConfig config = ChatBotService.getProviderConfig(provider);
        String apiKey = config != null ? config.apiKey : null;
        String baseUrl = config != null ? config.baseUrl : null;
        if (String.isBlank(apiKey)) return 'API key not configured.';
        if (String.isBlank(baseUrl)) return provider + ' Base URL not configured.';
        if (!ChatBotService.initMcp()) return 'MCP init failed.';

        Map<String, Object> p = new Map<String, Object>{'name' => 'soqlQuery', 'arguments' => new Map<String, Object>{'q' => 'SELECT FIELDS(ALL) FROM ' + obj + ' WHERE Id = \'' + String.escapeSingleQuotes(vid) + '\' LIMIT 1' }};
        ChatBotService.executedToolName = 'soqlQuery';
        String tr = ChatBotService.extractToolResult(ChatBotService.callMcp('tools/call', p));

        List<Map<String, Object>> msgs = new List<Map<String, Object>>();
        msgs.add(ChatBotService.msg('system', 'Summarize this ' + obj + ' concisely.'));
        msgs.add(ChatBotService.msg('user', 'Data:\n' + ChatBotService.truncate(tr, 8000)));
        String body = ChatBotService.callAi(provider, model, apiKey, baseUrl, msgs, null);
        return body != null ? ChatBotService.extractContent(body) : 'AI error: ' + ChatBotService.lastAiError + '\n\nTool result: ' + tr;
    }

    private static ChatBotService.ChatResponse buildResponse(String answer) {
        ChatBotService.ChatResponse r = new ChatBotService.ChatResponse();
        r.answer = answer;
        r.toolName = ChatBotService.executedToolName;
        r.toolArguments = ChatBotService.executedToolArguments;
        r.usedToolsJson = JSON.serialize(ChatBotService.executedTools);
        r.model = ChatBotService.aiModel;
        r.provider = ChatBotService.aiProvider;
        r.streamChunks = ChatBotService.streamChunks;
        r.usedTool = !ChatBotService.executedTools.isEmpty();
        return r;
    }
}
