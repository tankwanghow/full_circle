import { test } from "node:test";
import assert from "node:assert/strict";
import { renderIndex } from "../build-index.mjs";

const manifest = {
  series: "Full Circle — Daily Tasks",
  lessons: [
    { id: "01", slug: "key-a-sales-invoice", title: "Key a Sales Invoice", description: "Add two lines & save." },
    { id: "02", slug: "record-a-receipt", title: "Record a Receipt", description: "Match against invoices." },
  ],
};

test("renders one video element per lesson with a relative source", () => {
  const html = renderIndex(manifest);
  assert.match(html, /src="01-key-a-sales-invoice\.mp4"/);
  assert.match(html, /src="02-record-a-receipt\.mp4"/);
  assert.equal((html.match(/<video/g) ?? []).length, 2);
});

test("includes the series name, titles and descriptions", () => {
  const html = renderIndex(manifest);
  assert.match(html, /Full Circle — Daily Tasks/);
  assert.match(html, /Key a Sales Invoice/);
  assert.match(html, /Match against invoices\./);
});

test("is self-contained — no external asset references", () => {
  const html = renderIndex(manifest);
  assert.doesNotMatch(html, /https?:\/\//);
});

test("supports light and dark themes", () => {
  const html = renderIndex(manifest);
  assert.match(html, /prefers-color-scheme:\s*dark/);
});

test("escapes HTML in lesson text", () => {
  const html = renderIndex({ series: "S", lessons: [{ id: "9", slug: "x", title: "A & B", description: "<script>bad</script>" }] });
  assert.match(html, /A &amp; B/);
  assert.doesNotMatch(html, /<script>bad/);
});
