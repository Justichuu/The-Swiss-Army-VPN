const path = require('path');
const { ROOT_DIR } = require('./config');

function safeBrowserPath(rawPath = '') {
    if (rawPath === null || rawPath === undefined) return '';

    const normalized = path.posix.normalize(rawPath.replace(/\\/g, '/'));
    const trimmed = normalized.replace(/^\/+|\/+$/g, '');

    if (!trimmed || trimmed === '.' || trimmed === './') return '';
    if (trimmed.split('/').includes('..')) return null;
    if (trimmed.split('/').some(part => part.startsWith('.'))) return null;

    return trimmed;
}

function resolveRootPath(rawPath = '') {
    const safePath = safeBrowserPath(rawPath);
    return safePath === null ? null : path.resolve(ROOT_DIR, safePath || '.');
}

function isPathUnderRoot(candidate) {
    return candidate === ROOT_DIR || candidate.startsWith(ROOT_DIR + path.sep);
}

module.exports = {
    safeBrowserPath,
    resolveRootPath,
    isPathUnderRoot
};
