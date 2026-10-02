// 在**真浏览器**里看一眼 Web 导出产物，而不是靠猜。
//
// 为什么需要：Godot 的 headless 模式根本不渲染 —— "场景脚本报错""相机朝向错了"
// "扩展没加载"在 CI 里全都看不见，只会表现为用户那边"加载完了但是一片黑"。
// 这个脚本用 Chrome（软件 WebGL2：SwiftShader）打开导出的页面，抓三样东西：
//   1. 控制台（Godot 的 print/push_error 都会到这里）
//   2. 一张 canvas 截图（肉眼判断的唯一依据）
//   3. 失败的请求（wasm 没传到 / 404 一眼看出来）
//
// 用法（CI 里由 .github/workflows/web-smoke.yml 调；本地也可以用）：
//   python3 -m http.server 8080 --directory dist &
//   npm i puppeteer && node tools/web_smoke.mjs
//
// 不看"有没有报错"就完事：判据是**控制台里必须有 [tacord] 这一行**（说明 sim 接上了）
// 且**截图不能小得离谱**（纯黑 PNG 只有几 KB）。
import fs from 'node:fs';
import puppeteer from 'puppeteer';
import { PNG } from 'pngjs';

const URL = process.env.WEB_URL || 'http://127.0.0.1:8080/index.html';
const WAIT_MS = Number(process.env.WAIT_MS || 90_000);
const SETTLE_MS = Number(process.env.SETTLE_MS || 8_000);

const logs = [];
const note = (s) => {
  logs.push(s);
  console.log(s);
};

const browser = await puppeteer.launch({
  headless: true,
  args: [
    '--no-sandbox',
    '--disable-dev-shm-usage',
    // CI 的 runner 没有 GPU：没有这几条连 WebGL2 上下文都建不起来，
    // 表现和"游戏黑屏"一模一样 —— 所以必须显式开软件渲染。
    '--use-gl=angle',
    '--use-angle=swiftshader',
    '--enable-unsafe-swiftshader',
    '--window-size=1280,720',
  ],
});

let failed = 0;
let changedPct = 0;
let movingColor = null;
try {
  const page = await browser.newPage();
  await page.setViewport({ width: 1280, height: 720 });
  page.on('console', (m) => note(`[${m.type()}] ${m.text()}`));
  page.on('pageerror', (e) => note(`[pageerror] ${e.message}`));
  page.on('requestfailed', (r) =>
    note(`[requestfailed] ${r.url()} :: ${r.failure()?.errorText ?? '?'}`),
  );

  note(`[smoke] 打开 ${URL}`);
  await page.goto(URL, { waitUntil: 'domcontentloaded', timeout: 180_000 });

  // 引擎起来之后 main.gd 会 print("[tacord] units=400 …")；等这一行，最多 WAIT_MS
  const t0 = Date.now();
  let booted = false;
  while (Date.now() - t0 < WAIT_MS) {
    if (logs.some((l) => l.includes('[tacord]'))) {
      booted = true;
      break;
    }
    await new Promise((r) => setTimeout(r, 1_000));
  }
  note(`[smoke] sim 起来=${booted}（等了 ${((Date.now() - t0) / 1000).toFixed(1)}s）`);
  // SwiftShader 很慢，再多给几秒把第一帧真正画出来
  await new Promise((r) => setTimeout(r, SETTLE_MS));

  const canvas = (await page.$('#canvas')) ?? (await page.$('canvas'));
  if (canvas) {
    await canvas.screenshot({ path: '/tmp/web-shot.png' });
    // 隔 6 秒再来一张：**动的东西才是士兵**。
    // 两帧做差，变化像素的占比 = 画面里有多少东西在动，
    // 变化像素的平均颜色 = 士兵到底是什么颜色（MultiMesh 的 instance color
    // 有没有生效，光看单张截图分不出"没画"和"画成了白色"）。
    // 软件渲染下帧率是个位数，6 秒只够走几个 tick —— 看着像"画面是死的"。
    // 给 30 秒：既让士兵真的走出一段距离，也让 main.gd 那行 2 秒一次的实况
    // （tick / fps / pos0）有时间打进控制台。
    await new Promise((r) => setTimeout(r, 30_000));
    await canvas.screenshot({ path: '/tmp/web-shot2.png' });
  } else {
    note('[smoke] 页面上没有 canvas！');
    await page.screenshot({ path: '/tmp/web-shot.png' });
  }

  const size = fs.existsSync('/tmp/web-shot.png') ? fs.statSync('/tmp/web-shot.png').size : 0;
  note(`[smoke] 截图 ${size} 字节`);

  // 光看字节数不够：纯黑画面的 PNG 也能压出几 KB。直接数像素 ——
  // "画面里有多少比例不是黑的"才是"Web 展示正确"的硬指标。
  let lit = 0;
  let sum = 0;
  let total = 0;
  if (fs.existsSync('/tmp/web-shot.png')) {
    const png = PNG.sync.read(fs.readFileSync('/tmp/web-shot.png'));
    for (let i = 0; i < png.data.length; i += 4 * 7) {
      const b = (png.data[i] + png.data[i + 1] + png.data[i + 2]) / 3;
      if (b > 24) lit++;
      sum += b;
      total++;
    }
  }
  const litPct = total ? (lit * 100) / total : 0;
  const mean = total ? sum / total : 0;
  note(`[smoke] 非黑像素 ${litPct.toFixed(1)}%  平均亮度 ${mean.toFixed(1)}/255`);

  if (fs.existsSync('/tmp/web-shot2.png')) {
    const a = PNG.sync.read(fs.readFileSync('/tmp/web-shot.png'));
    const b = PNG.sync.read(fs.readFileSync('/tmp/web-shot2.png'));
    let changed = 0;
    let tot = 0;
    let sr = 0;
    let sg = 0;
    let sb = 0;
    for (let i = 0; i < a.data.length; i += 4 * 3) {
      const dr = Math.abs(a.data[i] - b.data[i]);
      const dg = Math.abs(a.data[i + 1] - b.data[i + 1]);
      const db = Math.abs(a.data[i + 2] - b.data[i + 2]);
      tot++;
      if (dr + dg + db > 40) {
        changed++;
        sr += b.data[i];
        sg += b.data[i + 1];
        sb += b.data[i + 2];
      }
    }
    const mv = (changed * 100) / tot;
    note(
      `[smoke] 30 秒内变化的像素 ${mv.toFixed(2)}%` +
        (changed ? `（变化处平均色 rgb(${Math.round(sr / changed)},${Math.round(sg / changed)},${Math.round(sb / changed)})）` : ''),
    );
    changedPct = mv;
    movingColor = changed ? [sr / changed, sg / changed, sb / changed] : null;

    // 变化像素落在画面的哪个位置：只看总数分不清"士兵在动"和"HUD 的数字在跳"。
    // HUD 在左上角 1/8 见方；士兵散布在整个城上。
    const G = 8;
    const grid = Array.from({ length: G }, () => new Array(G).fill(0));
    const gridTot = Array.from({ length: G }, () => new Array(G).fill(0));
    const white = Array.from({ length: G }, () => new Array(G).fill(0));
    for (let y = 0; y < a.height; y += 2) {
      for (let x = 0; x < a.width; x += 2) {
        const i = (y * a.width + x) * 4;
        const gy = Math.floor((y / a.height) * G);
        const gx = Math.floor((x / a.width) * G);
        gridTot[gy][gx]++;
        const dr = Math.abs(a.data[i] - b.data[i]);
        const dg = Math.abs(a.data[i + 1] - b.data[i + 1]);
        const db = Math.abs(a.data[i + 2] - b.data[i + 2]);
        if (dr + dg + db > 40) grid[gy][gx]++;
        const r = b.data[i];
        const g2 = b.data[i + 1];
        const b2 = b.data[i + 2];
        if (r > 200 && g2 > 200 && b2 > 200) white[gy][gx]++;
      }
    }
    const pct = (m) => m.map((row, y) => row.map((v, x) => ((v * 100) / gridTot[y][x]).toFixed(0).padStart(3)));
    note('[smoke] 变化像素分布（%，8×8 网格；左上角是 HUD）：');
    for (const row of pct(grid)) note('   ' + row.join(' '));
    note('[smoke] 接近纯白的像素分布（%，士兵方块是 unlit 白 + instance color）：');
    for (const row of pct(white)) note('   ' + row.join(' '));
  }

  const problems = [];
  if (changedPct < 0.2) problems.push(`画面 6 秒内只有 ${changedPct.toFixed(2)}% 的像素在变（没动 = 没接上 sim）`);
  if (!booted) problems.push('控制台里没有 [tacord] —— 扩展没起来或主场景没跑');
  if (size < 20_000) problems.push(`截图只有 ${size} 字节：几乎肯定是纯黑/空白画面`);
  if (litPct < 5.0) problems.push(`画面里只有 ${litPct.toFixed(1)}% 不是黑的（相机没对上？场景空的？）`);
  if (mean < 6.0) problems.push(`平均亮度只有 ${mean.toFixed(1)}/255（整屏几乎全黑）`);
  if (logs.some((l) => l.includes('requestfailed'))) problems.push('有请求失败（wasm 没送到？）');

  if (problems.length) {
    failed = 1;
    for (const p of problems) note(`::error::${p}`);
    note('[smoke] FAIL');
  } else {
    note('[smoke] PASS');
  }
} catch (e) {
  failed = 1;
  note(`[smoke] 异常：${e?.stack ?? e}`);
} finally {
  await browser.close();
  fs.writeFileSync('/tmp/web-console.log', logs.join('\n') + '\n');
}
process.exit(failed);
