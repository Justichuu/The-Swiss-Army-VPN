const http = require('http');
const { URL } = require('url');
const fs = require('fs');
const {
    DEFAULT_PORT,
    PORT,
    BIND_HOST,
    HOST,
    INDEX_PAGE
} = require('./lib/config');
const { resolveRootPath, isPathUnderRoot } = require('./lib/path-utils');
const { listDirectory, serveFile } = require('./lib/file-service');
const { sendJson, sendText } = require('./lib/response-utils');

function serveStaticAsset(res, parsedUrl) {
    const pathname = parsedUrl.pathname;
    const rawPath = pathname === '/' ? '' : pathname.slice(1);
    const filePath = resolveRootPath(rawPath);

    if (!filePath || !isPathUnderRoot(filePath)) {
        sendText(res, 403, 'Access denied');
        return;
    }

    fs.stat(filePath, (err, stats) => {
        if (!err && stats.isDirectory()) {
            serveFile(res, INDEX_PAGE, sendText);
            return;
        }

        if (err) {
            if (err.code === 'ENOENT') {
                sendText(res, 404, 'File not found');
            } else {
                sendText(res, 500, 'Server error: ' + err.message);
            }
            return;
        }

        serveFile(res, filePath, sendText);
    });
}

function serveApiFiles(res, parsedUrl) {
    const rawDir = parsedUrl.searchParams.get('path') || '';
    const dirPath = resolveRootPath(rawDir);

    if (dirPath === null || !isPathUnderRoot(dirPath)) {
        sendJson(res, 403, { error: 'Access denied' });
        return;
    }

    try {
        const stats = fs.statSync(dirPath);
        if (!stats.isDirectory()) {
            sendJson(res, 400, { error: 'Path is not a directory' });
            return;
        }
    } catch (err) {
        sendJson(res, 404, { error: 'Directory not found' });
        return;
    }

    const items = listDirectory(dirPath);
    sendJson(res, 200, { path: rawDir || '', items });
}

function handleRequest(req, res) {
    const parsedUrl = new URL(req.url, 'http://localhost');

    // Allow only API endpoints. No HTML UI served.
    if (parsedUrl.pathname === '/api/list' && req.method === 'GET') {
        serveApiFiles(res, parsedUrl);
        return;
    }

    if (parsedUrl.pathname === '/api/read' && req.method === 'GET') {
        serveFileContent(res, parsedUrl);
        return;
    }

    if (parsedUrl.pathname === '/api/write' && req.method === 'POST') {
        handleWriteRequest(req, res, parsedUrl);
        return;
    }

    sendJson(res, 404, { error: 'This server is API-only. Use /api/list, /api/read, or /api/write.' });
}

function serveFileContent(res, parsedUrl) {
    const rawPath = parsedUrl.searchParams.get('path') || '';
    const filePath = resolveRootPath(rawPath);
    if (filePath === null || !isPathUnderRoot(filePath)) {
        sendJson(res, 403, { error: 'Access denied' });
        return;
    }

    try {
        const stats = fs.statSync(filePath);
        if (!stats.isFile()) {
            sendJson(res, 400, { error: 'Path is not a file' });
            return;
        }
    } catch (err) {
        sendJson(res, 404, { error: 'File not found' });
        return;
    }

    try {
        // Try to read as UTF-8 text first
        const text = fs.readFileSync(filePath, { encoding: 'utf8' });
        sendJson(res, 200, { path: rawPath || '', isBinary: false, encoding: 'utf8', content: text });
    } catch (e) {
        // Fallback to binary base64
        try {
            const buf = fs.readFileSync(filePath);
            sendJson(res, 200, { path: rawPath || '', isBinary: true, encoding: 'base64', content: buf.toString('base64') });
        } catch (err) {
            sendJson(res, 500, { error: 'Failed to read file' });
        }
    }
}

function handleWriteRequest(req, res, parsedUrl) {
    let body = '';
    req.on('data', chunk => { body += chunk.toString(); });
    req.on('end', () => {
        try {
            const payload = JSON.parse(body || '{}');
            const rawPath = payload.path || '';
            const encoding = payload.encoding || 'utf8';
            const content = payload.content;

            if (!rawPath || typeof content === 'undefined') {
                sendJson(res, 400, { error: 'Invalid payload. Expect {path, content, encoding?}' });
                return;
            }

            const filePath = resolveRootPath(rawPath);
            if (filePath === null || !isPathUnderRoot(filePath)) {
                sendJson(res, 403, { error: 'Access denied' });
                return;
            }

            // Ensure directory exists
            const dir = require('path').dirname(filePath);
            fs.mkdirSync(dir, { recursive: true });

            if (encoding === 'base64') {
                const buf = Buffer.from(content, 'base64');
                fs.writeFileSync(filePath, buf);
            } else {
                fs.writeFileSync(filePath, content, { encoding: 'utf8' });
            }

            sendJson(res, 200, { ok: true, path: rawPath });
        } catch (err) {
            sendJson(res, 500, { error: 'Failed to write file', details: err.message });
        }
    });
}

let currentPort = PORT;
let server = null;

function createServer() {
    const s = http.createServer(handleRequest);
    s.on('error', handleServerError);
    s.on('listening', () => {
        console.log(`🚀 Server running at http://${HOST}:${currentPort}`);
        console.log(`📱 Access from phone: http://<your-pc-ip>:${currentPort}`);
        console.log(`⏳ Press Ctrl+C to stop`);
    });
    return s;
}

function listenOnPort(port) {
    currentPort = port;
    server = createServer();
    server.listen(port, BIND_HOST);
}

function handleServerError(err) {
    if (err.code === 'EADDRINUSE') {
        const nextPort = currentPort + 1;
        if (nextPort <= 65535) {
            console.warn(`Port ${currentPort} is in use. Trying port ${nextPort}...`);
            if (server && server.listening) {
                server.close(() => listenOnPort(nextPort));
            } else {
                listenOnPort(nextPort);
            }
            return;
        }

        console.error(`All ports from ${PORT} to 65535 are in use. Set PORT=<free port> and retry.`);
    } else {
        console.error('Server error:', err.message);
    }
    process.exit(1);
}

function shutdown(signal, exitCode = 0) {
    if (server && server.listening) {
        console.log(`Shutting down server on port ${currentPort} (${signal})...`);
        server.close(() => process.exit(exitCode));
        setTimeout(() => process.exit(exitCode), 5000).unref();
    } else {
        process.exit(exitCode);
    }
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGHUP', () => shutdown('SIGHUP'));
process.on('uncaughtException', err => {
    console.error('Uncaught exception:', err);
    shutdown('uncaughtException', 1);
});
process.on('unhandledRejection', reason => {
    console.error('Unhandled rejection:', reason);
    shutdown('unhandledRejection', 1);
});

listenOnPort(PORT);
