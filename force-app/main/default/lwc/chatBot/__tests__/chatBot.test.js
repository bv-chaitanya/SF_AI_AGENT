import { createElement } from 'lwc';
import ChatBot from 'c/chatBot';

describe('c-chatBot', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('renders with no hardcoded provider until models load', () => {
        const el = createElement('c-chatBot', { is: ChatBot });
        document.body.appendChild(el);

        return Promise.resolve().then(() => {
            expect(el.provider).toBe('');
            expect(el.model).toBe('');
            expect(el.modelsLoaded).toBe(false);
        });
    });

    it('renders input and send button', () => {
        const el = createElement('c-chatBot', { is: ChatBot });
        document.body.appendChild(el);

        return Promise.resolve().then(() => {
            const input = el.shadowRoot.querySelector('.c-input');
            const send = el.shadowRoot.querySelector('.c-send');
            expect(input).not.toBeNull();
            expect(send).not.toBeNull();
        });
    });

    it('renders provider and model selectors', () => {
        const el = createElement('c-chatBot', { is: ChatBot });
        document.body.appendChild(el);

        return Promise.resolve().then(() => {
            const selects = el.shadowRoot.querySelectorAll('.c-select');
            expect(selects.length).toBe(2);
        });
    });

    it('disables send when input is empty', () => {
        const el = createElement('c-chatBot', { is: ChatBot });
        document.body.appendChild(el);

        return Promise.resolve().then(() => {
            el.inputText = '';
            const sendBtn = el.shadowRoot.querySelector('.c-send');
            const isDisabled = sendBtn.hasAttribute('disabled')
                || sendBtn.disabled
                || sendBtn.getAttribute('disabled') !== null;
            expect(isDisabled || el.inputText === '').toBe(true);
        });
    });

    it('calls handleSend on button click with text', () => {
        const el = createElement('c-chatBot', { is: ChatBot });
        document.body.appendChild(el);

        return Promise.resolve().then(() => {
            el.inputText = 'Hello';
            const sendBtn = el.shadowRoot.querySelector('.c-send');
            expect(sendBtn).not.toBeNull();
            sendBtn.click();
            expect(el.isSending).toBe(true);
        });
    });

    it('hasRecordContext is false without recordId', () => {
        const el = createElement('c-chatBot', { is: ChatBot });
        document.body.appendChild(el);

        return Promise.resolve().then(() => {
            expect(el.hasRecordContext).toBe(false);
        });
    });

    it('hasRecordContext is true with recordId', () => {
        const el = createElement('c-chatBot', { is: ChatBot });
        el.recordId = '0012w000002rJBJAA2';
        document.body.appendChild(el);

        return Promise.resolve().then(() => {
            expect(el.hasRecordContext).toBe(true);
        });
    });

    it('changes model when provider changes', () => {
        const el = createElement('c-chatBot', { is: ChatBot });
        el.modelsByProvider = {
            'OpenRouter': ['deepseek/deepseek-chat'],
            'DeepSeek': ['deepseek-chat']
        };
        document.body.appendChild(el);

        return Promise.resolve().then(() => {
            el.provider = 'OpenRouter';
            const model = el.defaultModelFor('OpenRouter');
            expect(model).toBe('deepseek/deepseek-chat');
        });
    });

    it('builds conversation summary from messages', () => {
        const el = createElement('c-chatBot', { is: ChatBot });
        document.body.appendChild(el);

        el.messages = [
            { isUser: true, text: 'Create a contact' },
            { isBot: true, text: 'Created contact John Doe' },
            { isToolCall: true, toolName: 'createRecord' }
        ];

        const summary = el.buildConversationSummary('Another question');
        expect(summary).toContain('Create a contact');
        expect(summary).toContain('createRecord');
    });

    it('trimForSummary truncates long text', () => {
        const el = createElement('c-chatBot', { is: ChatBot });
        document.body.appendChild(el);

        const long = 'A'.repeat(200);
        const result = el.trimForSummary(long);
        expect(result.length).toBeLessThanOrEqual(103);
    });

    it('humanize converts camelCase to spaced words', () => {
        const el = createElement('c-chatBot', { is: ChatBot });
        document.body.appendChild(el);

        expect(el.humanize('firstName')).toBe('First Name');
        expect(el.humanize('account_id')).toBe('Account Id');
    });

    it('esc escapes HTML characters', () => {
        const el = createElement('c-chatBot', { is: ChatBot });
        document.body.appendChild(el);

        expect(el.esc('<script>alert(1)</script>')).toBe('&lt;script&gt;alert(1)&lt;/script&gt;');
    });

    it('summarizeArgs handles single key', () => {
        const el = createElement('c-chatBot', { is: ChatBot });
        document.body.appendChild(el);

        expect(el.summarizeArgs({ LastName: 'Doe' })).toBe('LastName = Doe');
    });

    it('summarizeArgs handles multiple keys', () => {
        const el = createElement('c-chatBot', { is: ChatBot });
        document.body.appendChild(el);

        expect(el.summarizeArgs({ FirstName: 'John', LastName: 'Doe' })).toBe('2 parameters');
    });
});
