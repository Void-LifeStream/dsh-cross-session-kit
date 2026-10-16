#!/usr/bin/env node
/**
 * peek-session.cjs — 看某个会话日志里「某个词」的上下文（谁在什么场合说的、做了什么）
 *
 * 与 find-session-by-text.cjs 的分工（两者互补，别混用）：
 *   find-session-by-text.cjs → 定位：哪个会话提过这个词（只报命中次数，无上下文，全库扫）
 *   peek-session.cjs（本工具）→ 看现场：把命中处的上下文打出来，能读「她当时在什么情境下做的」
 *
 * Usage:
 *   node peek-session.cjs <会话id> "<特征串>" [前后字符数=800] [最多几处=3]
 *
 * 会话id 可给完整 uuid（如 <session-uuid>）、也可带 session- 前缀；
 * 工具会在 ~/.dsh/sessions/ 的所有工作区目录里找它，找到就报告工作区名与日志体量。
 *
 * 为什么需要它：会话日志是**多帧 zstd** —— zlib.zstdDecompressSync 只解第一帧，
 * 一把梭解出来会只剩一行；这里按魔数 28 B5 2F FD 切帧、逐帧解（与 find-session-by-text /
 * audit-file-history 同一套办法）。
 *
 * ⚠️ 判据提示：想知道「某个对外动作是哪只鲸鱼娘做的」，本工具负责第 3 步（看上下文）；
 *    决定性的第 2 步是看**候选日志的第一行** —— 里面的 `parentSession` + `"origin":"subagent"`
 *    会把子代理归给派它的主会话（子会话日志**不带 `session-` 前缀**）。
 */
const fs = require('fs'), path = require('path'), zlib = require('zlib'), os = require('os');

const argv = process.argv.slice(2);
if (argv.length < 2) {
  console.error('usage: node peek-session.cjs <session-id> "<needle>" [spanChars=800] [maxHits=3]');
  process.exit(1);
}
const sidArg = argv[0].replace(/^session-/, '');
const needle = argv[1];
const span = parseInt(argv[2] || '800', 10);
const maxHits = parseInt(argv[3] || '3', 10);

const root = path.join(os.homedir(), '.dsh', 'sessions');
const MAGIC = Buffer.from([0x28, 0xb5, 0x2f, 0xfd]);

function decodeAll(buf) {
  const cuts = [];
  let i = 0;
  while ((i = buf.indexOf(MAGIC, i)) !== -1) { cuts.push(i); i += 4; }
  const parts = [];
  for (let k = 0; k < cuts.length; k++) {
    const a = cuts[k], b = k + 1 < cuts.length ? cuts[k + 1] : buf.length;
    try { parts.push(zlib.zstdDecompressSync(buf.subarray(a, b)).toString('utf8')); } catch (e) { /* partial frame */ }
  }
  return parts.join('');
}

let found = null;
for (const ws of fs.readdirSync(root)) {
  for (const cand of [sidArg, 'session-' + sidArg]) {
    const p = path.join(root, ws, cand, 'session.v4.jsonl.zstd');
    if (fs.existsSync(p)) { found = { ws, p }; break; }
  }
  if (found) break;
}
if (!found) { console.error('session not found: ' + sidArg); process.exit(1); }

const text = decodeAll(fs.readFileSync(found.p));
console.log('== ws: ' + found.ws + '  bytes: ' + fs.statSync(found.p).size + '  decoded chars: ' + text.length);
let idx = 0, count = 0;
while (count < maxHits) {
  idx = text.indexOf(needle, idx);
  if (idx === -1) break;
  count++;
  console.log('\n--- hit #' + count + ' at char ' + idx + ' ---');
  console.log(text.slice(Math.max(0, idx - span), idx + span));
  idx += needle.length;
}
console.log('\n== total hits for ' + JSON.stringify(needle) + ': ' + (text.split(needle).length - 1));
