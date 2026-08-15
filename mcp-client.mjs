import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';

const MAX_SERVERS = 16;
const MAX_DESCRIPTION = 500;
const STDERR_TAIL = 4096;
const DEFAULT_TIMEOUT_MS = 30_000;
const NAME_PATTERN = /^[a-z0-9-]{1,64}$/u;

function clean(value, limit = 500) {
  return String(value ?? '').replace(/[\u0000-\u001F\u007F]/gu, ' ').replace(/\s+/gu, ' ').trim().slice(0, limit);
}

export class McpClient {
  constructor(serverConfig = {}) {
    this.name = clean(serverConfig.name, 64) || 'mcp-server';
    this.command = typeof serverConfig.command === 'string' ? serverConfig.command : '';
    this.args = Array.isArray(serverConfig.args) ? serverConfig.args.filter((arg) => typeof arg === 'string') : [];
    this.timeoutMs = Number.isFinite(serverConfig.timeoutMs) && serverConfig.timeoutMs > 0 ? serverConfig.timeoutMs : DEFAULT_TIMEOUT_MS;
    this.env = {};
    if (serverConfig.env && typeof serverConfig.env === 'object' && !Array.isArray(serverConfig.env)) {
      for (const [key, value] of Object.entries(serverConfig.env)) {
        if (key) this.env[key] = String(value);
      }
    }
    this.child = null;
    this.initialized = false;
    this.stopped = false;
    this.nextId = 1;
    this.pending = new Map();
    this.stdoutBuffer = '';
    this.stderrTail = '';
  }

  async start() {
    if (this.initialized) return;
    if (!this.command) throw new Error('MCP client start requires a non-empty command.');
    this.child = spawn(this.command, this.args, {
      windowsHide: true,
      shell: false,
      stdio: ['pipe', 'pipe', 'pipe'],
      env: { ...process.env, ...this.env },
    });
    this.child.stdout.setEncoding('utf8');
    this.child.stderr.setEncoding('utf8');
    this.child.stdout.on('data', (chunk) => this._onStdout(chunk));
    this.child.stderr.on('data', (chunk) => this._onStderr(chunk));
    this.child.on('error', (error) => this._onChildError(error));
    this.child.on('close', (code) => this._onChildClose(code));
    try {
      await this._request('initialize', {
        protocolVersion: '2024-11-05',
        capabilities: {},
        clientInfo: { name: 'jarvis-nexus', version: '1.0.0' },
      });
      this._notify('initialized');
      this.initialized = true;
    } catch (error) {
      await this._shutdown(error);
      throw error;
    }
  }

  async listTools() {
    const result = await this._request('tools/list');
    const tools = Array.isArray(result?.tools) ? result.tools : [];
    return tools.map((tool) => ({
      name: clean(tool?.name),
      description: clean(tool?.description, MAX_DESCRIPTION),
      inputSchema: tool?.inputSchema && typeof tool.inputSchema === 'object' ? tool.inputSchema : { type: 'object', properties: {} },
    }));
  }

  async callTool(name, args) {
    return this._request('tools/call', { name, arguments: args });
  }

  async stop() {
    if (this.stopped) return;
    this.stopped = true;
    await this._shutdown(new Error(`MCP ${this.name}: client stopped.`));
  }

  _request(method, params) {
    return new Promise((resolve, reject) => {
      if (!this.child || this.child.exitCode !== null) {
        reject(new Error(`MCP ${this.name}: not started.`));
        return;
      }
      const id = this.nextId++;
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`MCP ${this.name}: ${method} timed out after ${this.timeoutMs}ms.${this._stderrSuffix()}`));
      }, this.timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      try {
        this.child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`);
      } catch (error) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(new Error(`MCP ${this.name}: failed to write ${method} request: ${clean(error.message, 200)}`));
      }
    });
  }

  _notify(method, params) {
    if (!this.child) return;
    try {
      this.child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', method, params })}\n`);
    } catch { /* stdin already closed */ }
  }

  _onStdout(chunk) {
    this.stdoutBuffer += chunk;
    const lines = this.stdoutBuffer.split('\n');
    this.stdoutBuffer = lines.pop();
    for (const line of lines) this._parseLine(line);
  }

  _parseLine(line) {
    const trimmed = line.trim();
    if (!trimmed.startsWith('{')) return;
    let message;
    try { message = JSON.parse(trimmed); } catch { return; }
    if (message && typeof message === 'object' && message.id != null) this._settle(message);
  }

  _flushBuffer() {
    if (this.stdoutBuffer.trim()) this._parseLine(this.stdoutBuffer);
    this.stdoutBuffer = '';
  }

  _settle(message) {
    const pending = this.pending.get(message.id);
    if (!pending) return;
    this.pending.delete(message.id);
    clearTimeout(pending.timer);
    if (message.error) {
      const detail = typeof message.error === 'object' ? message.error : {};
      pending.reject(new Error(`MCP ${this.name}: ${clean(detail.message, 500) || 'JSON-RPC error'}.`));
      return;
    }
    pending.resolve(message.result);
  }

  _onStderr(chunk) {
    this.stderrTail = (this.stderrTail + chunk).slice(-STDERR_TAIL);
  }

  _stderrSuffix() {
    const tail = this.stderrTail.trim();
    return tail ? ` stderr: ${clean(tail, 400)}` : '';
  }

  _onChildError(error) {
    this._rejectPending(new Error(`MCP ${this.name}: failed to launch: ${clean(error.message, 300)}`));
  }

  _onChildClose(code) {
    this._flushBuffer();
    if (this.pending.size) {
      this._rejectPending(new Error(`MCP ${this.name}: process exited (code ${code ?? 'unknown'}).${this._stderrSuffix()}`));
    }
  }

  _rejectPending(error) {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
  }

  async _shutdown(reason) {
    const child = this.child;
    this.child = null;
    this.initialized = false;
    this._rejectPending(reason ?? new Error(`MCP ${this.name}: shutting down.`));
    if (!child) return;
    if (child.exitCode === null && !child.killed) {
      try { child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', method: 'exit' })}\n`); } catch { /* stdin already closed */ }
      child.kill();
      await new Promise((resolve) => {
        const timer = setTimeout(resolve, 500);
        child.once('close', () => { clearTimeout(timer); resolve(); });
      });
    }
    child.stdin?.destroy();
    child.stdout?.destroy();
    child.stderr?.destroy();
  }
}

export function loadMcpConfig(configPath) {
  let config;
  try {
    config = JSON.parse(readFileSync(configPath, 'utf8'));
  } catch {
    return [];
  }
  if (!Array.isArray(config)) return [];
  const servers = [];
  for (const entry of config) {
    if (servers.length >= MAX_SERVERS) break;
    if (!entry || typeof entry !== 'object') continue;
    if (entry.enabled === false) continue;
    const name = typeof entry.name === 'string' ? entry.name : '';
    if (!NAME_PATTERN.test(name)) continue;
    const command = typeof entry.command === 'string' ? entry.command.trim() : '';
    if (!command) continue;
    if (!Array.isArray(entry.args) || !entry.args.every((arg) => typeof arg === 'string')) continue;
    const server = { name, command, args: entry.args.slice() };
    if (entry.env && typeof entry.env === 'object' && !Array.isArray(entry.env)) server.env = entry.env;
    if (Number.isFinite(entry.timeoutMs) && entry.timeoutMs > 0) server.timeoutMs = entry.timeoutMs;
    servers.push(server);
  }
  return servers;
}

export async function listAllTools(clients) {
  const tools = [];
  for (const client of clients ?? []) {
    if (!client || typeof client.listTools !== 'function') continue;
    const clientTools = await client.listTools();
    for (const tool of clientTools) {
      tools.push({ ...tool, server: client.name });
    }
  }
  return tools;
}
