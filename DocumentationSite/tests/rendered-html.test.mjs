import assert from "node:assert/strict";
import test from "node:test";

async function render(pathname = "/") {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);
  return worker.fetch(
    new Request(`http://localhost${pathname}`, { headers: { accept: "text/html" } }),
    { ASSETS: { fetch: async () => new Response("Not found", { status: 404 }) } },
    { waitUntil() {}, passThroughOnException() {} },
  );
}

test("server-renders the product home", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  const html = await response.text();
  assert.match(html, /<title>NovaNetworkClient — Production networking for Swift<\/title>/i);
  assert.match(html, /Stop rebuilding your network layer/);
  assert.match(html, /A production stack, not another thin URLSession wrapper/);
  assert.match(html, /Add Nova to your app/);
  assert.doesNotMatch(html, /codex-preview|SkeletonPreview|react-loading-skeleton/);
});

test("renders core static documentation routes", async () => {
  for (const [path, expected] of [
    ["/getting-started", "Getting Started"],
    ["/tutorials", "Share concurrent requests"],
    ["/tutorials/offline-writes", "Queue writes offline"],
    ["/tutorials/declarative-endpoints", "Declare endpoints with a macro"],
    ["/concepts", "Request identity"],
  ]) {
    const response = await render(path);
    assert.equal(response.status, 200, path);
    assert.match(await response.text(), new RegExp(expected), path);
  }
});
