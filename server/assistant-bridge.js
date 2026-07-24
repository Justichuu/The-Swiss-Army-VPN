const express = require('express');
const fetch = global.fetch || require('node-fetch');
const path = require('path');

// Assistant Bridge - mediates between the repo API and a local LLM HTTP API
// Usage: set environment variables MODEL_API, REPO_SERVER, ASSISTANT_PORT, ASSISTANT_TOKEN

const app = express();
app.use(express.json({ limit: '5mb' }));

const PORT = process.env.ASSISTANT_PORT || 9090;
const MODEL_API = process.env.MODEL_API || 'http://localhost:1234/v1';
const REPO_SERVER = process.env.REPO_SERVER || 'http://127.0.0.1:8000';
const TOKEN = process.env.ASSISTANT_TOKEN || null; // set to a secret string for simple auth

function verifyToken(req, res) {
    if (!TOKEN) return true; // no token required
    const header = req.headers['x-assistant-token'] || req.headers['authorization'];
    if (!header) return false;
    // allow both bare token or Bearer token
    if (header === TOKEN) return true;
    if (header.startsWith('Bearer ') && header.slice(7) === TOKEN) return true;
    return false;
}

function extractModelText(modelJson) {
    // Try common response shapes
    if (!modelJson) return '';
    if (typeof modelJson === 'string') return modelJson;
    if (modelJson.generated_text) return modelJson.generated_text;
    if (modelJson.text) return modelJson.text;
    if (modelJson.output) return modelJson.output;
    if (Array.isArray(modelJson) && modelJson[0] && modelJson[0].generated_text) return modelJson[0].generated_text;
    if (modelJson.choices && modelJson.choices[0] && modelJson.choices[0].text) return modelJson.choices[0].text;
    // Try nested 'result' arrays
    if (modelJson.result && Array.isArray(modelJson.result) && modelJson.result[0] && modelJson.result[0].text) return modelJson.result[0].text;
    // Fallback: stringify
    try { return JSON.stringify(modelJson); } catch (e) { return '' }
}

app.post('/assistant/edit', async (req, res) => {
    if (!verifyToken(req, res)) return res.status(401).json({ error: 'missing or invalid token' });

    const { path: filePath, instruction } = req.body;
    if (!filePath || !instruction) return res.status(400).json({ error: 'path and instruction required' });

    try {
        // Read file from repo server
        const readUrl = `${REPO_SERVER}/api/read?path=${encodeURIComponent(filePath)}`;
        const r = await fetch(readUrl);
        if (!r.ok) {
            const txt = await r.text();
            return res.status(502).json({ error: 'read failed', status: r.status, body: txt });
        }
        const file = await r.json();
        if (file.isBinary) return res.status(400).json({ error: 'editing binary files is not supported' });

        const fileContent = file.content || '';

        // Build prompt
        const prompt = [
            'You are a precise, conservative code assistant. Only output the full new file contents, nothing else.',
            `File: ${filePath}`,
            '---',
            fileContent,
            '---',
            `Instruction: ${instruction}`,
            '---',
            'Produce the complete updated file contents now.'
        ].join('\n\n');

        // Call model API: try OpenAI-style chat completions first, then fallbacks
        async function callModel(promptText) {
            const endpoints = [
                // OpenAI-style chat completions
                `${MODEL_API.replace(/\/$/, '')}/chat/completions`,
                // completions
                `${MODEL_API.replace(/\/$/, '')}/completions`,
                // webui / generate
                `${MODEL_API.replace(/\/$/, '')}/generate`,
                // raw MODEL_API as-is
                MODEL_API
            ];

            const chatBody = { model: process.env.MODEL_NAME || 'qwen3.5-9b', messages: [{ role: 'user', content: promptText }], max_tokens: 2000 };
            const completionBody = { model: process.env.MODEL_NAME || 'qwen3.5-9b', prompt: promptText, max_tokens: 2000 };
            const generateBody = { prompt: promptText, max_new_tokens: 1024 };

            for (const ep of endpoints) {
                try {
                    let body;
                    if (ep.endsWith('/chat/completions')) body = chatBody;
                    else if (ep.endsWith('/completions')) body = completionBody;
                    else if (ep.endsWith('/generate')) body = generateBody;
                    else body = { prompt: promptText, max_tokens: 2000 };

                    const r = await fetch(ep, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
                    if (!r.ok) {
                        // try next endpoint
                        continue;
                    }
                    const j = await r.json();
                    const text = extractModelText(j).trim();
                    if (text) return { json: j, text };
                } catch (e) {
                    // ignore and try next
                    continue;
                }
            }
            return null;
        }

        const modelResult = await callModel(prompt);
        if (!modelResult) return res.status(502).json({ error: 'model call failed on all endpoints' });
        const modelJson = modelResult.json;
        const newText = modelResult.text;

        // Write back
        const writeResp = await fetch(`${REPO_SERVER}/api/write`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ path: filePath, content: newText, encoding: 'utf8' })
        });
        const writeJson = await writeResp.json();
        return res.json({ ok: true, write: writeJson, model: { raw: modelJson } });
    } catch (err) {
        console.error(err);
        return res.status(500).json({ error: err.message });
    }
});

app.get('/assistant/health', (req, res) => res.json({ ok: true }));

// Chat endpoint: accept conversation array or a single message and return assistant reply
app.post('/assistant/chat', async (req, res) => {
    if (!verifyToken(req, res)) return res.status(401).json({ error: 'missing or invalid token' });
    const { conversation, message } = req.body;
    if (!conversation && !message) return res.status(400).json({ error: 'conversation or message required' });
    try {
        const promptMessages = Array.isArray(conversation) ? conversation.slice() : [];
        if (message) promptMessages.push({ role: 'user', content: message });

        const promptText = promptMessages.map(m => `${m.role}: ${m.content}`).join('\n\n');

        // Reuse callModel logic by building a one-off prompt when chat endpoints are not supported
        // Prefer chat/completions endpoint via callModel
        async function callAsChat() {
            const ep = `${MODEL_API.replace(/\/$/, '')}/chat/completions`;
            const body = { model: process.env.MODEL_NAME || 'qwen3.5-9b', messages: promptMessages, max_tokens: 1000 };
            try {
                const r = await fetch(ep, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
                if (!r.ok) return null;
                const j = await r.json();
                // extract assistant reply
                if (j.choices && j.choices[0] && j.choices[0].message && j.choices[0].message.content) return { json: j, text: j.choices[0].message.content };
                if (j.choices && j.choices[0] && j.choices[0].text) return { json: j, text: j.choices[0].text };
                return null;
            } catch (e) { return null; }
        }

        // Try direct chat endpoint first
        const chatResult = await callAsChat();
        if (chatResult) return res.json({ ok: true, reply: chatResult.text, raw: chatResult.json });

        // Fallback: use generic callModel with serialized messages
        const modelResult = await (async (prompt) => {
            const endpoints = [
                `${MODEL_API.replace(/\/$/, '')}/completions`,
                `${MODEL_API.replace(/\/$/, '')}/generate`,
                MODEL_API
            ];
            const completionBody = { model: process.env.MODEL_NAME || 'qwen3.5-9b', prompt, max_tokens: 1000 };
            const generateBody = { prompt, max_new_tokens: 512 };
            for (const ep of endpoints) {
                try {
                    let body = ep.endsWith('/generate') ? generateBody : completionBody;
                    const r = await fetch(ep, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
                    if (!r.ok) continue;
                    const j = await r.json();
                    const text = extractModelText(j).trim();
                    if (text) return { json: j, text };
                } catch (e) { continue; }
            }
            return null;
        })(promptText);

        if (!modelResult) return res.status(502).json({ error: 'model call failed' });
        return res.json({ ok: true, reply: modelResult.text, raw: modelResult.json });
    } catch (err) {
        console.error(err);
        return res.status(500).json({ error: err.message });
    }
});

app.listen(PORT, () => console.log(`Assistant bridge listening on http://127.0.0.1:${PORT}`));

module.exports = app;
