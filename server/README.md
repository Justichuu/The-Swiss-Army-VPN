# Assistant Bridge (server)

This folder contains `assistant-bridge.js`, a small Express service that connects the local repo API (`/api/read`, `/api/write`) to a local LLM HTTP API (e.g., text-generation-webui, Ollama, etc.). It reads files, asks the model to produce updated content, and writes the results back.

## Files

- `assistant-bridge.js` - the bridge server

## Quick start

1. Ensure the repo API server is running (the repo server we added):

```powershell
cd /d D:\Code\The-Swiss-Army-VPN
node server/index.js
```

2. Start your local model server and note its HTTP endpoint. Example default used by the bridge: `http://127.0.0.1:7860/generate`.

3. Start the assistant bridge (from repo root):

```bash
# optional env overrides
ASSISTANT_PORT=9090 MODEL_API=http://127.0.0.1:7860/generate REPO_SERVER=http://127.0.0.1:8000 node server/assistant-bridge.js
```

### Install Node dependencies

If you see "Cannot find module 'express'" run these commands in PowerShell from the repo root:

```powershell
cd /d D:\Code\The-Swiss-Army-VPN\server
npm install
```

This installs `express` (and `node-fetch`) required by `assistant-bridge.js`.

Then run the bridge from the repo root as shown above.

4. Use the bridge to edit a file (example):

```bash
curl -X POST 'http://127.0.0.1:9090/assistant/edit' \
  -H 'Content-Type: application/json' \
  -d '{"path":"README.md","instruction":"Replace the first paragraph with: This repo is a local AI-editable mirror."}'
```

## Security

Set `ASSISTANT_TOKEN` to a secret string before starting the bridge to require that token in `x-assistant-token` header (or `Authorization: Bearer <token>`).

Example:

```bash
ASSISTANT_TOKEN=secret123 ASSISTANT_PORT=9090 node server/assistant-bridge.js

# then request with header
curl -H 'x-assistant-token: secret123' ...
```

## Adapting to your model

Update `MODEL_API` and the request payload body in `assistant-bridge.js` to match your model server's expected JSON schema and response shape. The bridge contains a best-effort extractor for common response formats.

## Mobile Chat (talk-to-AI from your phone)

This bridge now supports a chat endpoint designed for phone use: `POST /assistant/chat`.

- Request body options:
  - `{ "message": "Hello" }` — single user message
  - `{ "conversation": [ {"role":"user","content":"Hi"}, {"role":"assistant","content":"..."} ] }` — pass full conversation

- Headers:
  - `Content-Type: application/json`
  - `x-assistant-token: <your token>` (recommended)

- Response:
  - `{ "ok": true, "reply": "Assistant text...", "raw": { ... } }

### Quick phone setup (same Wi‑Fi)
1. Find your PC local IP: run `ipconfig` on the PC and note the IPv4 address.
2. Allow the bridge port through Windows Firewall (run as admin):

```powershell
New-NetFirewallRule -DisplayName "Allow Assistant Bridge" -Direction Inbound -LocalPort 9090 -Protocol TCP -Action Allow
```

3. Start bridge on PC (example):

```powershell
$env:MODEL_API='http://localhost:1234/v1'
$env:REPO_SERVER='http://127.0.0.1:8002'
$env:ASSISTANT_TOKEN='secret123'
node server/assistant-bridge.js
```

4. From your phone, point your HTTP client (or browser) to:

```
POST http://<PC_IP>:9090/assistant/chat
Headers: Content-Type: application/json, x-assistant-token: secret123
Body: { "message": "Edit README: make first line a one-sentence summary" }
```

### Quick phone setup (remote phone) — using ngrok
1. Install `ngrok` on the PC and run:

```bash
ngrok http 9090
```

2. Copy the https://ngrok-url it gives you and use that as your base URL on the phone.

### Phone client suggestions
- iPhone: Shortcuts app (create a POST action), HTTPBot, Postman
- Android: Termux + `curl`, HTTP Request Shortcuts, Postman

If you want a one-tap Shortcut/Tasker recipe I can generate it for your platform.

## Commit & create PR (what I changed and how to push)

I added/updated these files in the branch `main-with-verifier`:

- `server/assistant-bridge.js` — added `/assistant/chat` and improved model endpoint fallbacks
- `server/README.md` — mobile chat, install, ngrok, and usage docs
- `server/package.json` — minimal dependencies

To commit and push locally, run from the repo root:

```powershell
git checkout -b main-with-verifier
git add server/assistant-bridge.js server/README.md server/package.json
git commit -m "feat(server): add mobile chat endpoint and docs; bridge improvements"
git push -u origin main-with-verifier
```

Then open a PR on GitHub or run `gh pr create` if you have the GitHub CLI configured.

If you want, paste the output of `git status` here and I will provide the exact commands if anything differs.
