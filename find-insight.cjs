// find-insight.cjs —— 按关键词在所有 mnemon 空间里找条目，报「落在哪个空间 / 有没有向量」。
//
// 为什么有它（2026-10-16 立）：本机有**三个同名空间**（都叫「本机环境与 DSH 经验」：
// 7b3da8e7=71 · 512dc0c3=63 · default=125），而 `mnemon_recall` **只覆盖其中一部分** ——
// 于是会出现"明明写了、却召不回"的假象，很容易被误判成"没写进去"或"写入失败"。
// 这个脚本直接下到数据库层回答三件事：**在哪、多少字节、有没有向量**。
//
// USAGE:
//   node find-insight.cjs "不插件化"        # 按关键词找
//   node find-insight.cjs --recent 10       # 各空间最近写入的 10 条
//   node find-insight.cjs --stats           # 只列各空间的条目数与向量覆盖
//
// 只读：以 readOnly 打开每个 db，不写、不改、不删。

const fs = require('fs');
const path = require('path');
const os = require('os');

let DatabaseSync;
try { ({ DatabaseSync } = require('node:sqlite')); }
catch (e) { console.log('node:sqlite 不可用：' + e.message); process.exit(1); }

const base = path.join(os.homedir(), '.mnemon', 'data');
const args = process.argv.slice(2);

function walk(d) {
  const out = [];
  for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    const p = path.join(d, e.name);
    if (e.isDirectory()) out.push(...walk(p));
    else if (e.name === 'mnemon.db') out.push(p);
  }
  return out;
}

if (!fs.existsSync(base)) { console.log('没有数据目录：' + base); process.exit(0); }

const mode = args[0] === '--recent' ? 'recent' : args[0] === '--stats' ? 'stats' : 'find';
const kw = mode === 'recent' ? null : args.join(' ').trim();
const n = mode === 'recent' ? (parseInt(args[1], 10) || 10) : 10;

for (const f of walk(base)) {
  const rel = f.replace(base, '').replace(/\\mnemon\.db$/, '') || '(root)';
  let db;
  try {
    db = new DatabaseSync(f, { readOnly: true });
    const t = db.prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name").all().map(r => r.name);
    if (!t.includes('insights')) { console.log(rel + '  (no insights table)'); db.close(); continue; }

    const total = db.prepare('SELECT COUNT(*) AS n FROM insights').get().n;
    // 向量不在这几张 sqlite 表里（2026-10-16 实测：一个库里 4 张表，无一含 embed/vec 字样）⇒ 本脚本不再猜它。
    // 「这个空间有没有向量」的**唯一权威口径**：
    //     mnemon --store <空间id> embed --status      （给出 coverage / embedded / total_insights）

    let rows = [];
    if (mode === 'find' && kw) {
      rows = db.prepare('SELECT id, category, length(content) AS len, substr(content,1,58) AS head FROM insights WHERE content LIKE ? ORDER BY created_at DESC').all('%' + kw + '%');
    } else if (mode === 'recent') {
      rows = db.prepare('SELECT id, category, length(content) AS len, substr(content,1,58) AS head FROM insights ORDER BY created_at DESC LIMIT ?').all(n);
    }

    console.log(rel + '   insights=' + total + '   hits=' + rows.length);
    for (const r of rows) console.log('    ' + r.id + ' | ' + r.category + ' | ' + r.len + 'B | ' + String(r.head).replace(/\s+/g, ' '));
    db.close();
  } catch (e) {
    console.log(rel + '  ERR ' + e.message);
    try { db && db.close(); } catch (_) {}
  }
}
