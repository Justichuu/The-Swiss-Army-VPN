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

    if (req.method !== 'GET') {
        sendText(res, 405, 'Method not allowed');
        return;
    }

    if (parsedUrl.pathname === '/api/files') {
        serveApiFiles(res, parsedUrl);
        return;
    }

    serveStaticAsset(res, parsedUrl);
}

const server = http.createServer(handleRequest);

function listenOnPort(port) {
    server.listen(port, BIND_HOST, () => {
        console.log(`🚀 Server running at http://${HOST}:${port}`);
        console.log(`📱 Access from phone: http://<your-pc-ip>:${port}`);
        console.log(`⏳ Press Ctrl+C to stop`);
    });
}

server.on('error', err => {
    if (err.code === 'EADDRINUSE' && PORT === DEFAULT_PORT) {
        const fallbackPort = DEFAULT_PORT + 1;
        console.warn(`Port ${DEFAULT_PORT} is in use. Trying port ${fallbackPort}...`);
        listenOnPort(fallbackPort);
        return;
    }

    if (err.code === 'EADDRINUSE') {
        console.error(`Port ${PORT} is already in use. Set PORT=<free port> and retry.`);
    } else {
        console.error('Server error:', err.message);
    }
    process.exit(1);
});

listenOnPort(PORT);
