function sendJson(res, statusCode, payload) {
    res.writeHead(statusCode, { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' });
    res.end(JSON.stringify(payload));
}

function sendText(res, statusCode, body, contentType = 'text/plain') {
    res.writeHead(statusCode, { 'Content-Type': contentType, 'Access-Control-Allow-Origin': '*' });
    res.end(body);
}

module.exports = {
    sendJson,
    sendText
};
