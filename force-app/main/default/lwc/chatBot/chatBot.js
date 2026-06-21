import { LightningElement, api } from 'lwc';
import getAvailableModels from '@salesforce/apex/ChatBotController.getAvailableModels';
import getRecordInfo from '@salesforce/apex/ChatBotController.getRecordInfo';
import searchRecords from '@salesforce/apex/ChatBotController.searchRecords';
import sendMessageDetailed from '@salesforce/apex/ChatBotController.sendMessageDetailed';
import summarizeCurrentRecordDetailed from '@salesforce/apex/ChatBotController.summarizeCurrentRecordDetailed';

export default class ChatBot extends LightningElement {
    @api recordId;
    messages = [];
    inputText = '';
    isSending = false;
    messageId = 0;

    provider = '';
    model = '';
    modelsByProvider = {};
    modelsLoaded = false;
    contextRecords = [];
    showSearch = false;
    searchQuery = '';
    searchResults = [];
    isSearching = false;
    _searchTimer = null;

    connectedCallback() {
        this.loadModels();
        if (this.recordId) {
            getRecordInfo({ recordId: this.recordId })
                .then(result => {
                    if (result) {
                        const info = JSON.parse(result);
                        if (info.id) {
                            this.addContextRecord(info);
                        }
                    }
                })
                .catch(() => {});
        }
    }

    loadModels() {
        getAvailableModels()
            .then(result => {
                const parsed = JSON.parse(result);
                this.modelsByProvider = parsed;
                const providers = Object.keys(parsed);
                if (providers.length > 0) {
                    if (!this.provider || !parsed[this.provider]) {
                        this.provider = providers[0];
                    }
                    const models = parsed[this.provider];
                    if (!this.model || !models.includes(this.model)) {
                        this.model = models && models.length ? models[0] : '';
                    }
                }
                this.modelsLoaded = true;
            })
            .catch(() => { this.modelsLoaded = true; });
    }

    defaultModelFor(prov) {
        const models = this.modelsByProvider[prov];
        return models && models.length ? models[0] : '';
    }

    get providerOptions() {
        return Object.keys(this.modelsByProvider || {}).map(p => ({ label: p, value: p }));
    }

    get modelOptions() {
        const models = (this.modelsByProvider && this.modelsByProvider[this.provider]) || [];
        return models.map(m => ({ label: m, value: m }));
    }

    handleProviderChange(event) {
        this.provider = event.target.value;
        this.model = this.defaultModelFor(this.provider);
    }

    handleModelChange(event) {
        this.model = event.target.value;
    }

    addContextRecord(rec) {
        if (!rec.id) return;
        if (this.contextRecords.some(r => r.id === rec.id)) return;
        this.contextRecords = [...this.contextRecords, rec];
    }

    removeContextRecord(event) {
        const id = event.currentTarget.dataset.id;
        this.contextRecords = this.contextRecords.filter(r => r.id !== id);
    }

    toggleSearch() {
        this.showSearch = !this.showSearch;
        this.searchQuery = '';
        this.searchResults = [];
    }

    handleSearchInput(event) {
        this.searchQuery = event.target.value;
        if (this._searchTimer) clearTimeout(this._searchTimer);
        if (this.searchQuery.length < 2) {
            this.searchResults = [];
            return;
        }
        this._searchTimer = setTimeout(() => {
            this.isSearching = true;
            searchRecords({ query: this.searchQuery })
                .then(result => {
                    this.searchResults = JSON.parse(result);
                    this.isSearching = false;
                })
                .catch(() => {
                    this.searchResults = [];
                    this.isSearching = false;
                });
        }, 300);
    }

    selectSearchResult(event) {
        const id = event.currentTarget.dataset.id;
        const rec = this.searchResults.find(r => r.id === id);
        if (rec) {
            this.addContextRecord(rec);
        }
        this.toggleSearch();
    }

    handleInputChange(event) {
        this.inputText = event.target.value;
    }

    handleKeyDown(event) {
        if (event.code === 'Enter' && !event.shiftKey && !this.isSending) {
            event.preventDefault();
            this.handleSend();
        }
    }

    handleSend() {
        const text = this.inputText.trim();
        if (!text || this.isSending) return;
        this.inputText = '';
        this.submitMessage(text);
    }

    get hasRecordContext() {
        return Boolean(this.recordId);
    }

    get providerInitials() {
        return (this.provider || 'SF').substring(0, 2).toUpperCase();
    }

    submitMessage(text) {
        this.addUserMessage(text);
        this.isSending = true;

        const summary = this.buildConversationSummary(text);

        sendMessageDetailed({
            userMessage: text,
            recordId: this.recordId,
            provider: this.provider,
            model: this.model,
            conversationSummary: summary,
            contextRecordsJson: JSON.stringify(this.contextRecords)
        })
        .then(result => {
            this.isSending = false;
            if (result.usedTool && result.usedToolsJson) {
                const toolList = JSON.parse(result.usedToolsJson);
                this.showToolsThenAnswer(toolList, 0, result);
            } else {
                this.addBotMessage(result.answer, result.model, null, result.provider, result.streamChunks);
            }
        })
        .catch(error => {
            this.isSending = false;
            this.addBotMessage('Error: ' + this.reduceError(error), null, null, null, null);
        });
    }

    showToolsThenAnswer(toolList, index, result) {
        if (index >= toolList.length) {
            this.addBotMessage(result.answer, result.model, result.toolName, result.provider, result.streamChunks);
            return;
        }
        const tool = toolList[index];
        const argsShort = this.summarizeArgs(this.tryParseJson(tool.arguments || '{}'));
        const id = this.addToolCall(tool.name, argsShort, tool.arguments || '{}', null);
        setTimeout(() => {
            this.updateToolCallResult(id, 'Done', null);
            this.showToolsThenAnswer(toolList, index + 1, result);
        }, 400);
    }

    handleSummarizeCurrentRecord() {
        if (!this.hasRecordContext || this.isSending) return;
        this.addUserMessage('Summarize this record');
        this.isSending = true;

        summarizeCurrentRecordDetailed({
            recordId: this.recordId,
            provider: this.provider,
            model: this.model
        })
            .then(result => {
                if (result.usedTool && result.usedToolsJson) {
                    const toolList = JSON.parse(result.usedToolsJson);
                    toolList.forEach(tool => {
                        this.addToolCall(tool.name,
                            JSON.stringify(tool.arguments || 'Record query'),
                            tool.arguments || '{}', 'Record data retrieved');
                    });
                }
                this.addBotMessage(result.answer, result.model, result.toolName, result.provider, result.streamChunks);
            })
            .catch(error => {
                this.addBotMessage('Error: ' + this.reduceError(error), null, null, null, null);
            })
            .finally(() => {
                this.isSending = false;
            });
    }

    addUserMessage(text) {
        this.messages = [...this.messages, {
            id: 'msg-' + this.messageId++,
            type: 'user',
            isUser: true,
            text: text,
            time: this.now()
        }];
        this.scrollDown();
    }

    addBotMessage(text, model, toolName, provider, streamChunks) {
        let subtitle = '';
        if (provider) {
            subtitle = provider;
            if (model) subtitle += ' / ' + model;
        } else if (model) {
            subtitle = 'Powered by ' + model;
        }
        if (toolName) {
            subtitle = (subtitle ? subtitle + ' \u2014 ' : '') + 'via ' + toolName;
        }

        const id = 'msg-' + this.messageId++;
        const msg = {
            id: id,
            type: 'bot',
            isBot: true,
            text: '',
            time: this.now(),
            subtitle: subtitle,
            formattedText: ''
        };
        this.messages = [...this.messages, msg];
        this.scrollDown();

        if (streamChunks && streamChunks.length > 0) {
            this.typewriterChunks(id, streamChunks, 0);
        } else {
            this.updateBotMessage(id, text);
        }
    }

    typewriterChunks(id, chunks, index) {
        if (index >= chunks.length) {
            this.finalizeStreaming(id);
            return;
        }
        this.updateBotMessage(id, chunks.slice(0, index + 1).join('') + '|');
        const delay = Math.min(15 + chunks[index].length * 1.5, 40);
        setTimeout(() => this.typewriterChunks(id, chunks, index + 1), delay);
    }

    finalizeStreaming(id) {
        this.messages = this.messages.map(m => {
            if (m.id === id) {
                const clean = (m.text || '').replace(/\|$/, '');
                return {
                    ...m,
                    text: clean,
                    formattedText: this.formatBotResponse(clean)
                };
            }
            return m;
        });
        this.scrollDown();
    }

    updateBotMessage(id, fullText) {
        this.messages = this.messages.map(m => {
            if (m.id === id) {
                return {
                    ...m,
                    text: fullText,
                    formattedText: this.formatBotResponse(fullText)
                };
            }
            return m;
        });
        this.scrollDown();
    }

    addToolCall(name, argsShort, detail, result) {
        const id = 'msg-' + this.messageId++;
        this.messages = [...this.messages, {
            id: id,
            type: 'toolCall',
            isToolCall: true,
            toolName: name,
            toolArgs: argsShort,
            toolDetail: detail || '{}',
            toolResult: result,
            expanded: false,
            toggleExpanded: this.createToggle(id)
        }];
        this.scrollDown();
        return id;
    }

    createToggle(id) {
        const self = this;
        return function() {
            self.messages = self.messages.map(m => {
                if (m.id === id) {
                    return { ...m, expanded: !m.expanded };
                }
                return m;
            });
        };
    }

    updateToolCallResult(id, result, error) {
        this.messages = this.messages.map(m => {
            if (m.id === id) {
                return {
                    ...m,
                    toolResult: result || null,
                    toolError: error || null
                };
            }
            return m;
        });
    }

    formatBotResponse(text) {
        const trimmed = String(text || '').trim();
        try {
            const parsed = JSON.parse(trimmed);
            return this.formatStructuredValue(parsed);
        } catch (e) {
            return this.formatMarkdown(trimmed);
        }
    }

    formatStructuredValue(value) {
        if (Array.isArray(value)) {
            if (value.length === 0) return '<p>No records found.</p>';
            return '<ol>' + value.map(v => '<li>' + this.formatStructuredValue(v) + '</li>').join('') + '</ol>';
        }
        if (value !== null && typeof value === 'object') {
            return '<ul>' + Object.entries(value).map(([k, v]) =>
                '<li><strong>' + this.esc(this.humanize(k)) + ':</strong> ' + this.formatStructuredValue(v) + '</li>'
            ).join('') + '</ul>';
        }
        if (value === null || value === '') return '<em>&mdash;</em>';
        return this.esc(String(value));
    }

    formatMarkdown(text) {
        const lines = text.split(/\r?\n/);
        let html = '';
        let listTag = null;

        const closeList = () => {
            if (listTag) { html += '</' + listTag + '>'; listTag = null; }
        };

        for (const line of lines) {
            const t = line.trim();
            const bullet = t.match(/^[-*]\s+(.+)$/);
            const numbered = t.match(/^\d+[.)]\s+(.+)$/);

            if (bullet || numbered) {
                const tag = bullet ? 'ul' : 'ol';
                if (listTag !== tag) { closeList(); listTag = tag; html += '<' + tag + '>'; }
                html += '<li>' + this.formatInline(bullet ? bullet[1] : numbered[1]) + '</li>';
            } else {
                closeList();
                if (!t) continue;
                const h = t.match(/^(#{1,3})\s+(.+)$/);
                if (h) {
                    const lvl = h[1].length + 2;
                    html += '<h' + lvl + '>' + this.formatInline(h[2]) + '</h' + lvl + '>';
                } else {
                    html += '<p>' + this.formatInline(t) + '</p>';
                }
            }
        }
        closeList();
        return html || '<p>No response.</p>';
    }

    formatInline(text) {
        return this.esc(text)
            .replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
            .replace(/`([^`]+)`/g, '<code>$1</code>');
    }

    humanize(key) {
        return key.replace(/_/g, ' ').replace(/([a-z])([A-Z])/g, '$1 $2')
            .replace(/\b\w/g, c => c.toUpperCase());
    }

    esc(val) {
        return String(val).replace(/&/g, '&amp;').replace(/</g, '&lt;')
            .replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
    }

    now() {
        return new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    }

    tryParseJson(str) {
        try { return JSON.parse(str); } catch (e) { return str; }
    }

    summarizeArgs(args) {
        if (!args || (typeof args === 'object' && Object.keys(args).length === 0)) return '{}';
        if (typeof args === 'string') return args;
        const keys = Object.keys(args);
        const firstKey = keys[0];
        const firstVal = args[firstKey];
        if (keys.length === 1) {
            const s = String(firstVal);
            return firstKey + ' = ' + (s.length > 60 ? s.substring(0, 60) + '...' : s);
        }
        return keys.length + ' parameters';
    }

    scrollDown() {
        requestAnimationFrame(() => {
            const el = this.querySelector('.chat-body');
            if (el) el.scrollTop = el.scrollHeight;
        });
    }

    reduceError(error) {
        if (!error) return 'Unknown error';
        if (error.body) {
            if (error.body.message) return error.body.message;
            if (error.body.pageErrors && error.body.pageErrors.length) {
                return error.body.pageErrors.map(e => e.message).join('; ');
            }
            if (error.body.fieldErrors) {
                const fieldMsgs = [];
                Object.keys(error.body.fieldErrors).forEach(f => {
                    fieldMsgs.push(error.body.fieldErrors[f].map(e => e.message).join('; '));
                });
                if (fieldMsgs.length) return fieldMsgs.join('; ');
            }
            if (error.body.output && error.body.output.errors && error.body.output.errors.length) {
                return error.body.output.errors.map(e => e.message).join('; ');
            }
        }
        if (error.message) return error.message;
        if (typeof error === 'string') return error;
        return 'Unknown error';
    }

    buildConversationSummary(currentText) {
        const parts = [];
        for (let i = this.messages.length - 1; i >= 0 && parts.length < 6; i--) {
            const msg = this.messages[i];
            if (msg.isUser && msg.text !== currentText) {
                parts.unshift('User asked: ' + this.trimForSummary(msg.text));
            } else if (msg.isBot && msg.text) {
                parts.unshift('Bot said: ' + this.trimForSummary(msg.text));
            } else if (msg.isToolCall && msg.toolName) {
                parts.unshift('Called ' + msg.toolName);
            }
        }
        return parts.join('. ');
    }

    trimForSummary(text) {
        const cleaned = text.replace(/<[^>]*>/g, '').replace(/\s+/g, ' ').trim();
        return cleaned.length > 100 ? cleaned.substring(0, 100) + '...' : cleaned;
    }
}
