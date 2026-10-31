const http = require('http');
const fs = require('fs');
const path = require('path');

const ROOT = __dirname;
const PORT = 8765;

const MIME = {
    '.lua': 'text/plain; charset=utf-8',
    '.luau': 'text/plain; charset=utf-8',
    '.md': 'text/plain; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.js': 'text/plain; charset=utf-8',
    '.html': 'text/html; charset=utf-8',
};

http.createServer((req, res) => {
    const name = decodeURIComponent(String(req.url).split('?')[0]).replace(/^\/+/, '');
    const file = path.resolve(ROOT, name);

    if (!file.startsWith(path.resolve(ROOT))) {
        res.writeHead(403);
        return res.end('forbidden');
    }

    fs.readFile(file, (err, data) => {
        if (err) {
            res.writeHead(404);
            return res.end('not found');
        }
        res.writeHead(200, {
            'Content-Type': MIME[path.extname(file).toLowerCase()] || 'application/octet-stream',
            'Cache-Control': 'no-store',
        });
        res.end(data);
    });
}).listen(PORT, '127.0.0.1', () => {
    console.log(`serving ${ROOT}`);
    console.log(`inject: loadstring(game:HttpGet("http://127.0.0.1:${PORT}/lua/loaders/ftf_loader.lua"))()`);
});
