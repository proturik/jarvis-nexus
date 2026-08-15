import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { McpClient, listAllTools, loadMcpConfig } from '../mcp-client.mjs';

const FAKE_SERVER_SOURCE = `import readline from 'node:readline';

process.stdout.write('fake-mcp-server 0.1.0 ready' + String.fromCharCode(10));

const TOOLS = [
  { name: 'echo', description: 'Echoes the provided arguments back.', inputSchema: { type: 'object', properties: { text: { type: 'string' } } } },
  { name: 'fail', description: 'Always returns a JSON-RPC error.', inputSchema: { type: 'object', properties: {} } },
];

function send(message) {
  process.stdout.write(JSON.stringify(message) + String.fromCharCode(10));
}

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on('line', (line) => {
  const trimmed = line.trim();
  if (!trimmed) return;
  let message;
  try { message = JSON.parse(trimmed); } catch { return; }
  if (message.id == null) return;
  if (message.method === 'initialize') {
    send({ jsonrpc: '2.0', id: message.id, result: { protocolVersion: '2024-11-05', capabilities: {}, serverInfo: { name: 'fake-mcp', version: '0.1.0' } } });
  } else if (message.method === 'tools/list') {
    send({ jsonrpc: '2.0', id: message.id, result: { tools: TOOLS } });
  } else if (message.method === 'tools/call') {
    if (message.params && message.params.name === 'fail') {
      send({ jsonrpc: '2.0', id: message.id, error: { code: -32000, message: 'boom from fake server' } });
    } else {
      send({ jsonrpc: '2.0', id: message.id, result: { echoed: message.params && message.params.arguments, tool: message.params && message.params.name } });
    }
  } else {
    send({ jsonrpc: '2.0', id: message.id, error: { code: -32601, message: 'method not found' } });
  }
});

process.stdin.on('end', () => process.exit(0));
`;

test('McpClient initializes, lists and calls tools, and stops the child', async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'jarvis-mcp-test-'));
  const serverFile = path.join(directory, 'fake-mcp-server.mjs');
  await writeFile(serverFile, FAKE_SERVER_SOURCE);
  const client = new McpClient({ name: 'fake', command: process.execPath, args: [serverFile] });
  try {
    await client.start();
    const tools = await client.listTools();
    assert.equal(tools.length, 2);
    assert.deepEqual(tools[0], {
      name: 'echo',
      description: 'Echoes the provided arguments back.',
      inputSchema: { type: 'object', properties: { text: { type: 'string' } } },
    });
    const echoed = await client.callTool('echo', { text: 'hello' });
    assert.deepEqual(echoed, { echoed: { text: 'hello' }, tool: 'echo' });
    await assert.rejects(client.callTool('fail', {}), /boom from fake server/u);
    const child = client.child;
    let closed = false;
    child.once('close', () => { closed = true; });
    await client.stop();
    assert.equal(closed, true);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test('loadMcpConfig reads valid entries, skips disabled ones and passes env through', async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'jarvis-mcp-config-'));
  const filename = path.join(directory, 'mcp-servers.json');
  try {
    await writeFile(filename, JSON.stringify([
      { name: 'filesystem', command: 'node', args: ['server.js'], enabled: true },
      { name: 'disabled-one', command: 'node', args: [], enabled: false },
      { name: 'env-one', command: 'node', args: ['x'], env: { KEY: 'value' } },
    ]));
    assert.deepEqual(loadMcpConfig(filename), [
      { name: 'filesystem', command: 'node', args: ['server.js'] },
      { name: 'env-one', command: 'node', args: ['x'], env: { KEY: 'value' } },
    ]);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test('loadMcpConfig returns [] for malformed, invalid and missing configs', async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'jarvis-mcp-config-'));
  try {
    const malformed = path.join(directory, 'malformed.json');
    await writeFile(malformed, '{ this is not valid json');
    assert.deepEqual(loadMcpConfig(malformed), []);
    const invalid = path.join(directory, 'invalid.json');
    await writeFile(invalid, JSON.stringify([
      { name: 'BAD NAME!', command: '', args: 'nope' },
      { name: 'ok-name', command: 123, args: [] },
    ]));
    assert.deepEqual(loadMcpConfig(invalid), []);
    assert.deepEqual(loadMcpConfig(path.join(directory, 'missing.json')), []);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test('listAllTools merges each tool with its server field', async () => {
  const merged = await listAllTools([
    { name: 'alpha', listTools: async () => [{ name: 'a', description: '', inputSchema: {} }] },
    { name: 'beta', listTools: async () => [{ name: 'b', description: '', inputSchema: {} }] },
  ]);
  assert.deepEqual(merged, [
    { name: 'a', description: '', inputSchema: {}, server: 'alpha' },
    { name: 'b', description: '', inputSchema: {}, server: 'beta' },
  ]);
});
