const fs = require('fs');
const path = require('path');
const { getContentType } = require('./content-types');

function listDirectory(dirPath) {
    return fs.readdirSync(dirPath)
        .map(name => {
            const fullPath = path.join(dirPath, name);
            const stats = fs.statSync(fullPath);
            return {
                name,
                type: stats.isDirectory() ? 'directory' : 'file',
                size: stats.size
            };
        })
        .sort((a, b) => a.name.localeCompare(b.name));
}

function serveFile(res, filePath, sendText) {
    fs.readFile(filePath, (err, content) => {
        if (err) {
            console.error(`[error] filePath=${filePath} err=${err.code} message=${err.message}`);
            if (err.code === 'ENOENT') {
                sendText(res, 404, 'File not found');
            } else {
                sendText(res, 500, 'Server error: ' + err.message);
            }
            return;
        }

        sendText(res, 200, content, getContentType(filePath));
    });
}

module.exports = {
    listDirectory,
    serveFile
};
