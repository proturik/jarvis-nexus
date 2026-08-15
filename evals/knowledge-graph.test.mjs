import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  extractFallback, extractWithLlm, loadGraph, merge, renderGraphJson, retrieve, saveGraph, summarizeTopics,
} from '../knowledge-graph.mjs';

test('loadGraph returns empty for missing file and round-trips through saveGraph', async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'jarvis-kg-test-'));
  const filename = path.join(directory, 'graph.json');
  try {
    const missing = await loadGraph(filename);
    assert.equal(missing.entities.size, 0);
    assert.equal(missing.relations.length, 0);

    const graph = { entities: new Map(), relations: [] };
    await merge(graph, {
      entities: [{ name: '  JARVIS  ', type: 'assistant', observations: ['голосовой ассистент', 'голосовой ассистент', 'д'.repeat(1200)] }],
      relations: [{ from: 'JARVIS', to: 'Windows', type: 'runs on' }],
    });
    assert.equal(graph.relations.length, 0); // dangling endpoint is dropped
    await merge(graph, { entities: [{ name: 'Windows', type: 'os' }], relations: [{ from: 'JARVIS', to: 'Windows', type: 'runs on' }] });
    await saveGraph(filename, graph);

    const loaded = await loadGraph(filename);
    assert.equal(loaded.entities.size, 2);
    assert.equal(loaded.entities.get('JARVIS').type, 'assistant');
    assert.deepEqual(loaded.entities.get('JARVIS').observations, ['голосовой ассистент', 'д'.repeat(800)]);
    assert.equal(loaded.relations.length, 1);

    const stored = JSON.parse(await readFile(filename, 'utf8'));
    assert.equal(stored.entities.JARVIS.observations[1].length, 800);
    assert.equal(stored.relations.length, 1);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test('extractFallback returns at most six topic entities and no relations', async () => {
  const result = await extractFallback('My name is John. JARVIS works on Windows and Steam. Мой город Москва. Я пользуюсь Discord.');
  assert.ok(Array.isArray(result.entities));
  assert.ok(result.entities.length <= 6);
  assert.ok(result.entities.every((item) => item.type === 'topic'));
  assert.deepEqual(result.relations, []);
});

test('merge dedupes observations and relations and enforces caps', async () => {
  const graph = { entities: new Map(), relations: [] };
  await merge(graph, { entities: [{ name: 'A', type: 'topic', observations: ['один', 'два'] }], relations: [] });
  await merge(graph, { entities: [{ name: 'A', type: 'topic', observations: ['два', 'три'] }], relations: [] });
  assert.deepEqual(graph.entities.get('A').observations, ['один', 'два', 'три']);

  await merge(graph, { entities: [{ name: 'B', type: 'topic' }], relations: [{ from: 'A', to: 'B', type: 'links' }] });
  await merge(graph, { entities: [], relations: [{ from: 'A', to: 'B', type: 'links' }] });
  assert.equal(graph.relations.length, 1);

  await merge(graph, { entities: Array.from({ length: 410 }, (_, index) => ({ name: `E${index}`, type: 'topic' })), relations: [] });
  assert.ok(graph.entities.size <= 400);

  await merge(graph, { entities: [{ name: 'X', type: 'topic' }, { name: 'Y', type: 'topic' }], relations: [] });
  await merge(graph, { entities: [], relations: Array.from({ length: 1300 }, (_, index) => ({ from: 'X', to: 'Y', type: `r${index}` })) });
  assert.ok(graph.relations.length <= 1200);
});

test('extractWithLlm parses valid JSON and rejects garbage', async () => {
  const parsed = await extractWithLlm('JARVIS runs on Windows', {
    chat: async () => '```json\n{"entities":[{"name":"JARVIS","type":"assistant"}],"relations":[{"from":"JARVIS","to":"Windows","type":"runs on"}]}\n```',
  });
  assert.equal(parsed.entities.length, 1);
  assert.equal(parsed.entities[0].name, 'JARVIS');
  assert.equal(parsed.entities[0].type, 'assistant');
  assert.deepEqual(parsed.relations, [{ from: 'JARVIS', to: 'Windows', type: 'runs on' }]);

  const garbage = await extractWithLlm('whatever', { chat: async () => 'not json at all' });
  assert.deepEqual(garbage, { entities: [], relations: [] });
});

test('extractWithLlm without chat uses the deterministic fallback', async () => {
  const result = await extractWithLlm('My name is John and JARVIS is my assistant');
  assert.ok(Array.isArray(result.entities));
  assert.ok(result.entities.length <= 6);
  assert.ok(result.entities.every((item) => item.type === 'topic'));
  assert.deepEqual(result.relations, []);
});

test('retrieve ranks exact-name matches above word-overlap matches', async () => {
  const graph = { entities: new Map(), relations: [] };
  await merge(graph, {
    entities: [
      { name: 'Steam Deck', type: 'device', observations: ['портативная консоль Valve'] },
      { name: 'Steam Link', type: 'device', observations: ['стриминг на телевизор'] },
      { name: 'Discord', type: 'app', observations: ['мессенджер'] },
    ],
    relations: [],
  });
  const results = await retrieve(graph, 'steam deck', 8);
  assert.equal(results[0].name, 'Steam Deck');
  assert.ok(results[0].score > results[1].score);
});

test('summarizeTopics and renderGraphJson expose stable shapes', async () => {
  const graph = { entities: new Map(), relations: [] };
  await merge(graph, {
    entities: [
      { name: 'JARVIS', type: 'assistant', observations: ['голос'] },
      { name: 'Steam', type: 'app', observations: [] },
      { name: 'Windows', type: 'os', observations: ['операционная система'] },
    ],
    relations: [{ from: 'JARVIS', to: 'Steam', type: 'controls' }],
  });
  const summary = await summarizeTopics(graph);
  assert.equal(summary.totalEntities, 3);
  assert.equal(summary.totalRelations, 1);
  assert.deepEqual(summary.byType, { assistant: 1, app: 1, os: 1 });

  const rendered = await renderGraphJson(graph);
  assert.equal(rendered.nodes.length, 3);
  assert.deepEqual(rendered.nodes.map((node) => node.name), ['JARVIS', 'Steam', 'Windows']);
  assert.equal(rendered.nodes[0].observationCount, 1);
  assert.deepEqual(rendered.links, [{ source: 'JARVIS', target: 'Steam', type: 'controls' }]);
});

test('renderGraphJson caps at 200 nodes deterministically', async () => {
  const graph = { entities: new Map(), relations: [] };
  await merge(graph, {
    entities: Array.from({ length: 205 }, (_, index) => ({ name: `N${String(index).padStart(3, '0')}`, type: 'topic' })),
    relations: [],
  });
  const rendered = await renderGraphJson(graph);
  assert.equal(rendered.nodes.length, 200);
  assert.equal(rendered.nodes[0].name, 'N000');
  assert.equal(rendered.nodes[199].name, 'N199');
});
