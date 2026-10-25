import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

// Load the browser module without constructing a chat or a browser DOM.
const source = await readFile(new URL('../../assets/bonitoagents.js', import.meta.url), 'utf8');
const diff = new URL('../../assets/code_diff.mjs', import.meta.url).href;
const { BonitoChat } = await import('data:text/javascript;base64,' +
    Buffer.from(source.replace('"./code_diff.mjs"', JSON.stringify(diff))).toString('base64'));

test('unmeasured tool placeholders never require a layout measurement', () => {
    const chat = Object.create(BonitoChat.prototype);
    chat.bodyWidth = () => { throw new Error('unexpected layout read'); };
    for (const sizes of [undefined, {}]) {
        assert.equal(chat.bodyReserve({ collapsable: {}, __btBodyH: sizes }), null);
        assert.deepEqual(chat.bodyReserve({
            collapsable: {}, __btBodyH: sizes, __btMedia: [1200, 600], __btMediaExtra: 24,
        }), {
            boxSizing: 'content-box', padding: '24px 0 0', width: '1200px',
            maxWidth: '100%', aspectRatio: '1200 / 600', overflow: 'hidden',
        });
    }
});

test('saved body sizes still match the current transcript width', () => {
    const chat = Object.create(BonitoChat.prototype);
    let reads = 0;
    chat.bodyWidth = () => { reads++; return 800; };
    assert.deepEqual(chat.bodyReserve({ collapsable: {}, __btBodyH: { 799: 350 } }), { height: '350px' });
    assert.equal(chat.bodyReserve({ collapsable: {}, __btBodyH: { 700: 350 } }), null);
    assert.equal(reads, 2);
});
