@isTest
private class ChatBotControllerTest {

    private static final String PRV = 'OpenRouter';
    private static final String OR_MODEL = 'deepseek/deepseek-chat';

    @isTest
    static void sendMessage_returnsConfigError_whenNoApiKey() {
        ChatBotService.apiKeyOverride = null;
        ChatBotService.lastMcpError = null;
        Test.startTest();
        String r = ChatBotController.sendMessage('Hello', PRV, OR_MODEL, null, null);
        Test.stopTest();
        System.assert(r.contains('not configured'), r);
    }

    @isTest
    static void sendMessage_returnsPlainText_whenNoToolCall() {
        setupTools();
        Test.setMock(HttpCalloutMock.class, new Mock('{"choices":[{"message":{"content":"Hello"}}]}'));
        Test.startTest();
        String r = ChatBotController.sendMessage('Hello', PRV, OR_MODEL, null, null);
        Test.stopTest();
        System.assertEquals('Hello', r);
    }

    @isTest
    static void sendMessage_executesMcpTool_andSummarizes() {
        setupTools();
        ChatBotService.toolCallResponse = '{"jsonrpc":"2.0","result":{"content":[{"type":"text","text":"[{\"Name\":\"Acme\"}]"}]}}';
        Test.setMock(HttpCalloutMock.class, new MultiMock(
            '{"choices":[{"message":{"content":"<tool_call>{\"name\":\"query\",\"arguments\":{\"q\":\"SELECT Id FROM Account\"}}</tool_call>"}}]}',
            '{"choices":[{"message":{"content":"Found Acme"}}]}'));
        Test.startTest();
        String r = ChatBotController.sendMessage('List accounts', PRV, OR_MODEL, null, null);
        Test.stopTest();
        System.assertEquals('Found Acme', r);
    }

    @isTest
    static void sendMessage_handlesAiFailure() {
        setupTools();
        ChatBotService.toolsListResponse = '{"jsonrpc":"2.0","result":{"tools":[]}}';
        Test.setMock(HttpCalloutMock.class, new FailMock());
        Test.startTest();
        String r = ChatBotController.sendMessage('Hello', PRV, OR_MODEL, null, null);
        Test.stopTest();
        System.assert(r.contains('unavailable'), r);
    }

    @isTest
    static void sendMessage_rejectsBlankInput() {
        Test.startTest();
        String r = ChatBotController.sendMessage('   ', PRV, OR_MODEL, null, null);
        Test.stopTest();
        System.assert(r.contains('Please enter a message'), r);
    }

    @isTest
    static void sendMessage_usesDeepSeekProvider() {
        setupTools();
        Test.setMock(HttpCalloutMock.class, new Mock('{"choices":[{"message":{"content":"DS says hi"}}]}'));
        Test.startTest();
        String r = ChatBotController.sendMessage('Hello', 'DeepSeek', 'deepseek-chat', null, null);
        Test.stopTest();
        System.assertEquals('DS says hi', r);
    }

    @isTest
    static void sendMessage_withContextRecords() {
        setupTools();
        Test.setMock(HttpCalloutMock.class, new Mock('{"choices":[{"message":{"content":"Context aware"}}]}'));
        Test.startTest();
        String ctx = '[{"id":"001xx","name":"Acme","objectType":"Account"}]';
        String r = ChatBotController.sendMessage('Update it', PRV, OR_MODEL, null, ctx);
        Test.stopTest();
        System.assertEquals('Context aware', r);
    }

    @isTest
    static void getMcpToolList_returnsTools() {
        ChatBotService.mcpSessionIdOverride = 'test-session';
        ChatBotService.toolsListResponse = '{"jsonrpc":"2.0","result":{"tools":[{"name":"t1","description":"d"}]}}';
        Test.startTest();
        String r = ChatBotController.getMcpToolList();
        Test.stopTest();
        System.assert(r.contains('t1'), r);
    }

    @isTest
    static void getAvailableModels_returnsBoth() {
        Test.startTest();
        String r = ChatBotController.getAvailableModels();
        Test.stopTest();
        System.assert(r.contains('OpenRouter'), r);
        System.assert(r.contains('DeepSeek'), r);
    }

    private static void setupTools() {
        ChatBotService.apiKeyOverride = 'test-key';
        ChatBotService.mcpSessionIdOverride = 'test-session';
        ChatBotService.toolsListResponse = '{"jsonrpc":"2.0","result":{"tools":[{"name":"query","description":"Query","inputSchema":{"type":"object"}}]}}';
    }

    class Mock implements HttpCalloutMock {
        String body; Mock(String b) { body = b; }
        public HttpResponse respond(HttpRequest r) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200); res.setBody(body); return res;
        }
    }

    class MultiMock implements HttpCalloutMock {
        List<String> bodies; Integer i = 0;
        MultiMock(String a, String b) { bodies = new List<String>{ a, b }; }
        public HttpResponse respond(HttpRequest r) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200); res.setBody(i < bodies.size() ? bodies[i] : bodies[bodies.size() - 1]);
            i++; return res;
        }
    }

    class FailMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest r) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500); res.setBody('error'); return res;
        }
    }
}
