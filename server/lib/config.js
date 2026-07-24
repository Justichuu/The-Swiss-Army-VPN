const path = require('path');

const ROOT_DIR = path.resolve(__dirname, '..', '..');
const PUBLIC_DIR = path.join(__dirname, '..', 'public');
const INDEX_PAGE = path.join(PUBLIC_DIR, 'index.html');
const DEFAULT_PORT = 8000;
const PORT = Number(process.env.PORT) || DEFAULT_PORT;
const BIND_HOST = '0.0.0.0';
const HOST = '127.0.0.1';
const REPO_URL = 'https://github.com/Justichuu/The-Swiss-Army-VPN';

module.exports = {
    ROOT_DIR,
    PUBLIC_DIR,
    INDEX_PAGE,
    DEFAULT_PORT,
    PORT,
    BIND_HOST,
    HOST,
    REPO_URL
};
