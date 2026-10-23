const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const root = path.join(__dirname, "..");
const script = fs.readFileSync(path.join(root, "docs/assets/download.js"), "utf8");
const fallback = "https://github.com/thorrsson/mac-resources-bar/releases/download/v1.0.5/ResourcesBar-1.0.5.dmg";
const latest = "https://github.com/thorrsson/mac-resources-bar/releases/download/v2.0.0/ResourcesBar-2.0.0.dmg";
const assets = [
  { name: "ResourcesBar-2.0.0.dmg.sha256", browser_download_url: `${latest}.sha256` },
  { name: "appcast.xml", browser_download_url: "https://example.com/appcast.xml" },
  { name: "ResourcesBar-2.0.0.dmg", browser_download_url: latest }
];

async function run({ navigator = { platform: "MacIntel" }, fetch, releaseAssets = assets } = {}) {
  const link = { href: fallback, textContent: "Download macOS 1.0.5 (.dmg)" };
  const status = {};
  const errors = [];
  await vm.runInNewContext(script, {
    document: { getElementById: (id) => id === "download-link" ? link : status },
    navigator,
    fetch: fetch || (async (url) => {
      assert.equal(url, "https://api.github.com/repos/thorrsson/mac-resources-bar/releases/latest");
      return { ok: true, json: async () => ({ assets: releaseAssets }) };
    }),
    URL, AbortController, setTimeout, clearTimeout,
    console: { error: (...args) => errors.push(args) }
  });
  return { link, status, errors };
}

test("both pages have a working, explicitly versioned direct-download fallback", () => {
  for (const page of ["index.html", "docs.html"]) {
    const html = fs.readFileSync(path.join(root, "docs", page), "utf8");
    assert.ok(html.includes(`id="download-link" href="${fallback}"`));
    assert.ok(html.includes("Download macOS 1.0.5 (.dmg)"));
    assert.ok(html.includes('id="download-status" role="status"'));
    assert.ok(html.includes('<script src="assets/download.js" defer></script>'));
  }
});

test("Mac browsers get the exact latest universal DMG, not checksums or release pages", async () => {
  for (const navigator of [
    { platform: "MacIntel" },
    { userAgentData: { platform: "macOS" }, platform: "MacIntel" },
    { userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)" }
  ]) {
    const { link, status, errors } = await run({ navigator });
    assert.equal(link.href, latest);
    assert.equal(link.textContent, "Download for macOS (.dmg)");
    assert.match(status.textContent, /Supports Intel and Apple Silicon/);
    assert.equal(errors.length, 0);
  }
});

test("unsupported systems retain a direct DMG with a macOS-only notice", async () => {
  for (const navigator of [
    { platform: "Win32" },
    { userAgentData: { platform: "Windows" }, platform: "Win32" },
    { platform: "Linux x86_64" },
    { platform: "iPhone" },
    { platform: "MacIntel", maxTouchPoints: 5 }
  ]) {
    const { link, status } = await run({ navigator });
    assert.equal(link.href, latest);
    assert.match(status.textContent, /only for macOS/);
    assert.match(status.textContent, /not supported/);
  }
});

test("API, network and asset failures keep a direct fallback and explain the failure", async () => {
  for (const options of [
    { fetch: async () => ({ ok: false, status: 403 }) },
    { fetch: async () => { throw new TypeError("Network unavailable"); } },
    { fetch: async () => ({ ok: true, json: async () => { throw new SyntaxError("Invalid JSON"); } }) },
    { releaseAssets: [] },
    { releaseAssets: null },
    { releaseAssets: [{ name: "ResourcesBar-2.0.0.dmg", browser_download_url: "https://example.com/file.dmg" }] }
  ]) {
    const { link, status, errors } = await run(options);
    assert.equal(link.href, fallback);
    assert.equal(link.textContent, "Download macOS 1.0.5 (.dmg)");
    assert.match(status.textContent, /Could not check the latest release/);
    assert.match(status.textContent, /1\.0\.5/);
    assert.equal(errors.length, 1);
  }
});
