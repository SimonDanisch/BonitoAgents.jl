import assert from 'node:assert/strict';
import test from 'node:test';
import { editSteps, changedRanges } from '../../assets/code_diff.mjs';

function lcs(a, b) {
    const rows = Array.from({ length: a.length + 1 }, () => new Int32Array(b.length + 1));
    for (let i = 0; i < a.length; i++) for (let j = 0; j < b.length; j++) {
        rows[i + 1][j + 1] = a[i] === b[j] ? rows[i][j] + 1 : Math.max(rows[i][j + 1], rows[i + 1][j]);
    }
    return rows[a.length][b.length];
}

function checkScript(a, b, steps) {
    let i = 0, j = 0;
    for (const step of steps) {
        if (step === '=') { assert.equal(a[i++], b[j++]); }
        else if (step === '-') i++;
        else { assert.equal(step, '+'); j++; }
    }
    assert.equal(i, a.length);
    assert.equal(j, b.length);
}

test('the bounded frontier preserves shortest edit scripts and budget limits', () => {
    const sequences = [[]];
    for (let n = 1; n <= 5; n++) for (let bits = 0; bits < 2 ** n; bits++) {
        sequences.push(Array.from({ length: n }, (_, i) => (bits >> i) & 1));
    }
    for (const a of sequences) for (const b of sequences) {
        const changes = a.length + b.length - 2 * lcs(a, b);
        const steps = editSteps(a, b, changes);
        assert.notEqual(steps, null);
        checkScript(a, b, steps);
        assert.equal(steps.filter(s => s !== '=').length, changes);
        if (changes > 0) assert.equal(editSteps(a, b, changes - 1), null);
    }
});

test('changed word ranges retain their original character offsets', () => {
    assert.deepEqual(changedRanges('cat jump', 'cat walk'), [[[4, 8]], [[4, 8]]]);
    assert.deepEqual(changedRanges('same\ttext', 'same\ttext'), [[], []]);
    assert.equal(changedRanges('one', 'different'), null);
});

test('a long changed line does not copy its entire frontier every round', () => {
    const original = Int32Array.prototype.slice;
    let copied = 0;
    Int32Array.prototype.slice = function (...args) {
        const result = original.apply(this, args);
        copied += result.byteLength;
        return result;
    };
    try {
        for (const length of [20_000, 40_000]) {
            copied = 0;
            const a = Array.from({ length }, (_, i) => `old${i}`);
            const b = a.map(x => `new${x}`);
            assert.equal(editSteps(a, b, 200), null);
            assert.ok(copied < 200_000, `${copied} bytes copied`);
        }
    } finally {
        Int32Array.prototype.slice = original;
    }
});

test('a small change in a long line still gets an exact edit script', () => {
    const a = Array.from({ length: 30_000 }, (_, i) => `token${i}`);
    const b = a.slice();
    b[15_000] = 'changed';
    const steps = editSteps(a, b, 2);
    checkScript(a, b, steps);
    assert.equal(steps.filter(s => s !== '=').length, 2);
});
