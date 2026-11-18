// Streams a WAV (16 kHz mono) into the desktop host exactly like the browser
// extension does (capture.v1 frames over ws://localhost:9099/ingest), then prints
// the transcript the host produced. Run from the desktop package so imports resolve:
//   cd vexa/core/meetings/services/desktop && ./node_modules/.bin/tsx <this file> <pcm.f32> [platform]
import { readFileSync } from 'node:fs';
import { WebSocket } from 'ws';
import { encodeAudioFrame } from '@vexa/capture-codec';

const [pcmPath, platform = 'google_meet'] = process.argv.slice(2);
const native = `selftest-${Date.now()}`;
const raw = readFileSync(pcmPath);
const samples = new Float32Array(raw.buffer, raw.byteOffset, Math.floor(raw.byteLength / 4));
const FRAME = 1600; // 100 ms at 16 kHz

const ws = new WebSocket(`ws://localhost:9099/ingest?platform=${platform}&native_meeting_id=${native}&language=en`);
await new Promise((ok, err) => { ws.once('open', ok); ws.once('error', err); });
const t0 = Date.now();
// Speech, then 3 s of silence so the pipeline sees the turn end.
const all = new Float32Array(samples.length + 16000 * 3);
all.set(samples);
for (let i = 0; i < all.length; i += FRAME) {
  const chunk = all.slice(i, i + FRAME);
  ws.send(encodeAudioFrame(0, Date.now() - t0, chunk, 'Test Speaker'));
  await new Promise((r) => setTimeout(r, 100)); // real time, like a live meeting
}
await new Promise((r) => setTimeout(r, 4000));
ws.close();
await new Promise((r) => setTimeout(r, 2000));

const res = await fetch(`http://localhost:8056/transcripts/${platform}/${native}`);
const body: any = await res.json();
console.log(`HTTP ${res.status} · ${platform}/${native} · status=${body.status} · segments=${body.segments?.length ?? 0}`);
for (const s of body.segments ?? []) console.log(`  [${s.speaker ?? '?'}] ${s.text}`);
