#!/usr/bin/env node
// Render brand/svg/app-icon.svg into the AppIcon.appiconset PNGs using a headless
// Chromium — no native rasterizer (rsvg/cairo/ImageMagick) needs to be installed.
//
// Usage:   node brand/scripts/render-appicon.js
// Chromium: set $CHROME to a Chromium/Chrome binary, or the script probes the
//           Playwright cache and the common macOS install path.

const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const repoRoot = path.resolve(__dirname, '..', '..');
const svgPath = path.join(repoRoot, 'brand', 'svg', 'app-icon.svg');
const outDir = path.join(
  repoRoot, 'Sources', 'SpeechLogger', 'Resources',
  'Assets.xcassets', 'AppIcon.appiconset',
);
const sizes = [16, 32, 64, 128, 256, 512, 1024];

function findChrome() {
  if (process.env.CHROME && fs.existsSync(process.env.CHROME)) return process.env.CHROME;
  // headless_shell renders small window sizes correctly; the full chrome binary
  // paints tiny sizes blank here, so prefer the shell everywhere first.
  const shells = [];
  const fulls = [];
  const pw = process.env.PLAYWRIGHT_BROWSERS_PATH || '/opt/pw-browsers';
  if (fs.existsSync(pw)) {
    for (const dir of fs.readdirSync(pw)) {
      shells.push(path.join(pw, dir, 'chrome-linux', 'headless_shell'));
      fulls.push(
        path.join(pw, dir, 'chrome-linux', 'chrome'),
        path.join(pw, dir, 'chrome-mac', 'Chromium.app', 'Contents', 'MacOS', 'Chromium'),
      );
    }
  }
  const candidates = [...shells, ...fulls];
  candidates.push(
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
  );
  const hit = candidates.find((c) => fs.existsSync(c));
  if (!hit) {
    throw new Error('No Chromium found. Set $CHROME to a Chromium/Chrome binary.');
  }
  return hit;
}

const chrome = findChrome();
const svg = fs.readFileSync(svgPath, 'utf8');
const wrap = path.join(require('os').tmpdir(), 'speech-logger-appicon-wrap.html');
fs.writeFileSync(
  wrap,
  `<!doctype html><meta charset="utf8"><style>html,body{margin:0;padding:0;` +
  `background:transparent}svg{display:block;width:100vw;height:100vh}</style>${svg}`,
);

fs.mkdirSync(outDir, { recursive: true });
for (const s of sizes) {
  const out = path.join(outDir, `icon_${s}.png`);
  execFileSync(chrome, [
    '--headless', '--no-sandbox', '--hide-scrollbars', '--force-color-profile=srgb',
    '--default-background-color=00000000', `--window-size=${s},${s}`,
    `--screenshot=${out}`, `file://${wrap}`,
  ], { stdio: 'ignore' });
  console.log(`icon_${s}.png  ${s}x${s}`);
}
console.log(`\nRendered ${sizes.length} icons with ${path.basename(chrome)}.`);
