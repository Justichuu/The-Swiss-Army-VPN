const path = require('path');

const contentTypes = {
    '.html': 'text/html',
    '.css': 'text/css',
    '.js': 'application/javascript',
    '.json': 'application/json',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.svg': 'image/svg+xml',
    '.txt': 'text/plain'
};

function getContentType(filePath) {
    return contentTypes[path.extname(filePath).toLowerCase()] || 'application/octet-stream';
}

module.exports = {
    getContentType
};
