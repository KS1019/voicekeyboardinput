const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const html = fs.readFileSync('VoiceKeyboardExtension/DictationCapture.html', 'utf8');
const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];

function setup(getUserMedia, sampleRate = 44100) {
    const messages = [];
    const processors = [];
    const contexts = [];
    const context = vm.createContext({
        navigator: { mediaDevices: { getUserMedia } },
        webkit: { messageHandlers: { dictation: { postMessage: message => messages.push(message) } } },
        btoa: value => Buffer.from(value, 'binary').toString('base64'),
        AudioContext: class {
            constructor() {
                this.sampleRate = sampleRate;
                contexts.push(this);
            }
            resume() { return Promise.resolve(); }
            close() { this.closed = true; return Promise.resolve(); }
            createMediaStreamSource() { return { connect() {}, disconnect() {} }; }
            createScriptProcessor() {
                const processor = { connect() {}, disconnect() {} };
                processors.push(processor);
                return processor;
            }
        }
    });
    vm.runInContext(script, context);
    return { context, messages, processors, contexts };
}

function microphone() {
    const track = { stop() { this.stopped = true; } };
    return { track, stream: { getTracks: () => [track], getAudioTracks: () => [track] } };
}

async function record(blockLengths, sampleRate) {
    const mic = microphone();
    let permissionCalls = 0;
    const { context, messages, processors, contexts } = setup(async () => {
        permissionCalls++;
        return mic.stream;
    }, sampleRate);
    assert.equal(permissionCalls, 0, 'preloading cannot start capture');
    await context.startDictation('first');
    let inputIndex = 0;
    for (const length of blockLengths) {
        const samples = Float32Array.from({ length }, () => Math.sin(inputIndex++ * 0.1));
        processors[0].onaudioprocess({
            inputBuffer: { getChannelData: () => samples },
            outputBuffer: { getChannelData: () => new Float32Array(length) }
        });
    }
    await context.stopDictation('stale');
    assert.equal(mic.track.stopped, undefined);
    await context.stopDictation('first');
    assert.equal(messages.at(-1).type, 'stopped');
    assert.ok(messages.every(message => message.id === 'first'));
    assert.equal(mic.track.stopped, true);
    assert.equal(contexts[0].closed, true);
    return Buffer.concat(messages.filter(message => message.type === 'pcm')
        .map(message => Buffer.from(message.data, 'base64')));
}

(async () => {
    const whole = await record([44100]);
    const split = await record([1024, 333, 17331, 25412]);
    assert.equal(whole.length, 32000);
    assert.deepEqual(split, whole, 'resampling phase must survive callback boundaries');
    const tail = await record([1024], 48000);
    assert.equal(tail.length, 682, 'stop must flush a short final PCM chunk');

    // Use the real start/audio callback/stop entry points. Two pauses must
    // publish boundaries while the same microphone stays open; Stop drains
    // the short tail exactly once.
    const liveMic = microphone();
    const live = setup(async () => liveMic.stream, 16000);
    await live.context.startDictation('live');
    function feed(count, value) {
        live.processors[0].onaudioprocess({
            inputBuffer: { getChannelData: () => new Float32Array(count).fill(value) },
            outputBuffer: { getChannelData: () => new Float32Array(count) }
        });
    }
    feed(8000, 0.25);
    feed(16000, 0);
    assert.equal(live.messages.filter(m => m.type === 'segment').length, 1);
    assert.equal(liveMic.track.stopped, undefined, 'pause must not stop recording');
    feed(8000, -0.25);
    feed(16000, 0);
    assert.equal(live.messages.filter(m => m.type === 'segment').length, 2);
    feed(1234, 0.5);
    live.context.stopDictation('live');
    live.context.stopDictation('live');
    assert.equal(live.messages.filter(m => m.type === 'stopped').length, 1);
    const livePCM = Buffer.concat(live.messages.filter(m => m.type === 'pcm')
        .map(m => Buffer.from(m.data, 'base64')));
    assert.equal(livePCM.length, (48000 + 1234) * 2, 'no duplicated or lost PCM across boundaries');
    assert.equal(livePCM.readInt16LE(livePCM.length - 2), 16384);

    const continuous = setup(async () => microphone().stream, 16000);
    await continuous.context.startDictation('continuous');
    continuous.processors[0].onaudioprocess({
        inputBuffer: { getChannelData: () => new Float32Array(16000 * 17).fill(0.1) },
        outputBuffer: { getChannelData: () => new Float32Array(16000 * 17) }
    });
    assert.equal(continuous.messages.filter(m => m.type === 'segment').length, 2,
        'uninterrupted speech must commit without waiting for Stop');
    continuous.context.stopDictation('continuous');
    assert.equal(continuous.messages.filter(m => m.type === 'pcm')
        .reduce((sum, m) => sum + Buffer.from(m.data, 'base64').length, 0), 16000 * 17 * 2);

    const failure = setup(async () => { throw new Error('permission denied'); });
    await failure.context.startDictation('denied');
    assert.deepEqual(failure.messages.map(message => message.type), ['failed']);

    const mic = microphone();
    let permission;
    const { context, messages, processors } = setup(() => new Promise(resolve => { permission = resolve; }));
    const start = context.startDictation('pending');
    await context.stopDictation('pending');
    permission(mic.stream);
    await start;
    assert.equal(mic.track.stopped, true);
    assert.equal(processors.length, 0);
    assert.deepEqual(messages.map(message => message.type), ['stopped']);

    const cancelledMic = microphone();
    let latePermission;
    const cancelled = setup(() => new Promise(resolve => { latePermission = resolve; }));
    const cancelledStart = cancelled.context.startDictation('cancelled');
    cancelled.context.cancelDictation('cancelled');
    latePermission(cancelledMic.stream);
    await cancelledStart;
    assert.equal(cancelledMic.track.stopped, true);
    assert.equal(cancelled.processors.length, 0);
    assert.deepEqual(cancelled.messages, []);
})().catch(error => { console.error(error); process.exitCode = 1; });
