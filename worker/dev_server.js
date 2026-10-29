const http = require('http');
const port = process.env.PORT || 8787;

const server = http.createServer((req, res) => {
  if (req.method === 'POST' && req.url === '/chat') {
    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      Connection: 'keep-alive',
    });

    const chunks = [
      JSON.stringify({ type: 'content_block_delta', delta: { type: 'text_delta', text: 'Hello from Clicky (dev mode).' } }),
      JSON.stringify({ type: 'content_block_delta', delta: { type: 'text_delta', text: ' This is a mock unlimited-response stream.' } }),
    ];

    let i = 0;
    function pushNext() {
      if (i >= chunks.length) {
        res.write('data: [DONE]\n\n');
        res.end();
        return;
      }
      res.write('data: ' + chunks[i] + '\n\n');
      i++;
      setTimeout(pushNext, 120);
    }

    pushNext();
  } else {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not found');
  }
});

server.listen(port, () => {
  console.log(`Dev SSE server listening on http://127.0.0.1:${port}`);
});
