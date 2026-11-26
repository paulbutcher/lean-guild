// Copyright (c) 2026 Paul Butcher. All rights reserved.
// Released under Apache 2.0 license as described in the file LICENSE.

// Draws the colour given as the argument with WebGL in each browser named in GUILD_BROWSERS
// (Chromium and WebKit if unset), reads it back, and says which renderer drew it. On macOS the
// renderer must be the GPU, not a software one. Safari is driven through safaridriver, the rest
// through Playwright, which the test package pins.
import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';

const want = (process.argv[2] ?? '255,0,0,255').split(',').map(Number);
const browsers = (process.env.GUILD_BROWSERS ?? 'chromium webkit').split(/\s+/).filter(Boolean);
const required = process.env.GUILD_REQUIRE_LASM === '1';

// Runs in the page: draws, reads one pixel back, and names the renderer.
function probe(rgba) {
  const gl = document.createElement('canvas').getContext('webgl');
  if (!gl) return { renderer: 'no WebGL', pixel: [] };
  gl.clearColor(rgba[0] / 255, rgba[1] / 255, rgba[2] / 255, rgba[3] / 255);
  gl.clear(gl.COLOR_BUFFER_BIT);
  const pixel = new Uint8Array(4);
  gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, pixel);
  const ext = gl.getExtension('WEBGL_debug_renderer_info');
  const renderer = ext ? gl.getParameter(ext.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER);
  return { renderer: String(renderer), pixel: Array.from(pixel) };
}

async function viaPlaywright(name) {
  let playwright;
  try {
    playwright = createRequire(import.meta.url)('playwright');
  } catch {
    if (required) throw new Error('Playwright is pinned but not installed');
    console.log(`${name}: skipped, Playwright isn't installed`);
    return null;
  }
  // Playwright's default Chromium on macOS is its headless shell, which renders in software; full
  // Chromium in new headless mode reaches Metal, given a GPU Chrome doesn't know, the VM's.
  const options = process.platform === 'darwin' && name === 'chromium'
    ? { channel: 'chromium', args: ['--use-angle=metal', '--ignore-gpu-blocklist'] }
    : {};
  const browser = await playwright[name].launch(options);
  try {
    const page = await browser.newPage();
    return await page.evaluate(probe, want);
  } finally {
    await browser.close();
  }
}

async function viaSafari() {
  const port = 4445;
  const driver = spawn('safaridriver', ['-p', String(port)], { stdio: 'ignore' });
  await new Promise((ok, no) => { driver.on('spawn', ok); driver.on('error', no); });
  const base = `http://127.0.0.1:${port}`;
  const call = async (method, path, body) => {
    const r = await fetch(base + path, {
      method, headers: { 'Content-Type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const j = await r.json();
    if (!r.ok) throw new Error(`safaridriver ${path}: ${JSON.stringify(j.value)}`);
    return j.value;
  };
  try {
    for (let i = 0; ; i++) {
      try { await call('GET', '/status'); break; } catch (e) {
        if (i > 50) throw e;
        await new Promise((ok) => setTimeout(ok, 200));
      }
    }
    const session = await call('POST', '/session', { capabilities: { alwaysMatch: { browserName: 'safari' } } });
    try {
      return await call('POST', `/session/${session.sessionId}/execute/sync`,
        { script: `return (${probe})(arguments[0]);`, args: [want] });
    } finally {
      await call('DELETE', `/session/${session.sessionId}`);
    }
  } finally {
    driver.kill();
  }
}

let failed = 0;
for (const name of browsers) {
  try {
    const got = name === 'safari' ? await viaSafari() : await viaPlaywright(name);
    if (got === null) continue;
    const drew = got.pixel.join(',') === want.join(',');
    const software = /swiftshader|llvmpipe|software|mesa/i.test(got.renderer);
    const onGpu = process.platform !== 'darwin' || !software;
    console.log(`${name}: drew ${drew ? 'the colour' : `[${got.pixel}]`} with ${got.renderer}${process.platform === 'darwin' && onGpu ? ', on the GPU' : ''}`);
    if (!drew || !onGpu) failed++;
  } catch (e) {
    console.log(`${name}: ${e.message}`);
    failed++;
  }
}
process.exit(failed ? 1 : 0);
