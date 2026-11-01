'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const T = require('../../src/main/tags');

test('parses POINT with label and screen', () => {
  const r = T.parseResponseTags('that is over there. [POINT:400,300:terminal:screen2]');
  assert.deepEqual(r.coordinate, { x: 400, y: 300 });
  assert.equal(r.elementLabel, 'terminal');
  assert.equal(r.screenNumber, 2);
  assert.equal(r.spokenText, 'that is over there.');
});

test('POINT:none gives no coordinate', () => {
  const r = T.parseResponseTags('html is a markup language. [POINT:none]');
  assert.equal(r.coordinate, null);
  assert.equal(r.spokenText, 'html is a markup language.');
});

test('parses DRAW kinds and rejects bad ones', () => {
  const r = T.parseResponseTags('look [DRAW:circle:100,200,40:here] [DRAW:rect:1,2,3:bad] [DRAW:nope:1,2:x] [DRAW:step:5,5:1:screen2]');
  assert.equal(r.draws.length, 2);
  assert.equal(r.draws[0].kind, 'circle');
  assert.equal(r.draws[1].kind, 'step');
  assert.equal(r.draws[1].screen, 2);
});

test('parses CARD, MODEL3D, DRIVE, AGENT, REMEMBER, ROUTINE', () => {
  const r = T.parseResponseTags(
    'ok [CARD:Title|Body text|cat photo] [MODEL3D:water molecule] [DRIVE:open youtube] [AGENT:research x] [REMEMBER:likes tea] [ROUTINE:tue,thu@17:00|check mail]'
  );
  assert.equal(r.cards[0].title, 'Title');
  assert.equal(r.cards[0].photoQuery, 'cat photo');
  assert.equal(r.modelTopic, 'water molecule');
  assert.equal(r.driveTask, 'open youtube');
  assert.equal(r.agentTask, 'research x');
  assert.deepEqual(r.memories, ['likes tea']);
  assert.deepEqual(r.routines[0].schedule, { days: [2, 4], hour: 17, minute: 0 });
  assert.equal(r.spokenText, 'ok');
});

test('routine schedule words', () => {
  assert.deepEqual(T.parseRoutineSchedule('weekdays@09:30').days, [1, 2, 3, 4, 5]);
  assert.equal(T.parseRoutineSchedule('daily@25:00'), null);
  assert.equal(T.parseRoutineSchedule('garbage'), null);
});

test('stripThinking removes think blocks', () => {
  assert.equal(T.stripThinking('<think>hmm</think>hello'), 'hello');
});

function streamAll(text, size) {
  const s = new T.SpokenSentenceStream();
  const out = [];
  for (let i = 0; i < text.length; i += size) out.push(...s.push(text.slice(i, i + size)));
  out.push(...s.finish());
  return out;
}

test('stream yields sentence chunks and never leaks tags', () => {
  const text = 'you will want to open the color page, it is the droplet icon along the bottom. then click the wheels tab and drag them around. [POINT:540,962:color page]';
  for (const size of [1, 2, 3, 7, 13, 50, 500]) {
    const chunks = streamAll(text, size);
    const joined = chunks.join(' ');
    assert.ok(!joined.includes('['), 'leaked at size ' + size + ': ' + joined);
    assert.ok(!joined.includes('POINT'));
    assert.equal(joined.replace(/\s+/g, ' '), 'you will want to open the color page, it is the droplet icon along the bottom. then click the wheels tab and drag them around.');
    assert.ok(chunks.length >= 2);
  }
});

test('stream keeps ordinary brackets', () => {
  const chunks = streamAll('use the array [0] syntax here for the first item okay. next sentence is here and long enough to go.', 5);
  assert.ok(chunks.join(' ').includes('[0]'));
});

test('stream hides think text', () => {
  const chunks = streamAll('<think>secret plan</think>hello there my friend, welcome back to the show.', 4);
  assert.ok(!chunks.join(' ').includes('secret'));
  assert.ok(chunks.join(' ').includes('hello there'));
});

test('splitForSpeech respects max length', () => {
  const long = 'word '.repeat(120);
  const parts = T.splitForSpeech(long, 190);
  assert.ok(parts.every((p) => p.length <= 190));
  assert.equal(parts.join(' ').replace(/\s+/g, ' ').trim(), long.trim());
});
