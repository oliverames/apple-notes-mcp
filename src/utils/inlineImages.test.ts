import { describe, it, expect } from "vitest";
import {
  stripLargeInlineImages,
  strippedImagesWarning,
  maxInlineImageBytes,
} from "@/utils/inlineImages.js";

const img = (b64: string, quote = '"') =>
  `<img style="max-width: 100%;" src=${quote}data:image/png;base64,${b64}${quote} alt="">`;

describe("maxInlineImageBytes", () => {
  it("defaults to 256 KB", () => {
    expect(maxInlineImageBytes({})).toBe(256 * 1024);
  });

  it("honors APPLE_NOTES_MCP_MAX_INLINE_IMAGE_BYTES", () => {
    expect(maxInlineImageBytes({ APPLE_NOTES_MCP_MAX_INLINE_IMAGE_BYTES: "1024" })).toBe(1024);
  });

  it("ignores invalid values", () => {
    expect(maxInlineImageBytes({ APPLE_NOTES_MCP_MAX_INLINE_IMAGE_BYTES: "banana" })).toBe(
      256 * 1024
    );
    expect(maxInlineImageBytes({ APPLE_NOTES_MCP_MAX_INLINE_IMAGE_BYTES: "-5" })).toBe(256 * 1024);
  });
});

describe("stripLargeInlineImages", () => {
  it("keeps images at or under the cap", () => {
    const html = `<div>before</div>${img("A".repeat(100))}<div>after</div>`;
    const r = stripLargeInlineImages(html, 100);
    expect(r.html).toBe(html);
    expect(r.strippedCount).toBe(0);
    expect(r.strippedBytes).toBe(0);
  });

  it("replaces an over-cap image with a placeholder naming type and size", () => {
    const html = `<div>before</div>${img("A".repeat(4000))}<div>after</div>`;
    const r = stripLargeInlineImages(html, 100);
    expect(r.strippedCount).toBe(1);
    expect(r.strippedBytes).toBe(3000);
    expect(r.html).toContain("inline image omitted: image/png");
    expect(r.html).toContain("save-attachment");
    expect(r.html).not.toContain("base64,AAAA");
    expect(r.html).toContain("<div>before</div>");
    expect(r.html).toContain("<div>after</div>");
  });

  it("handles multiple images independently", () => {
    const html = `${img("A".repeat(4000))}${img("B".repeat(50))}${img("C".repeat(4000))}`;
    const r = stripLargeInlineImages(html, 100);
    expect(r.strippedCount).toBe(2);
    expect(r.html).toContain("base64,BBB");
    expect(r.html).not.toContain("AAAA");
    expect(r.html).not.toContain("CCCC");
  });

  it("handles single-quoted src attributes", () => {
    const html = img("A".repeat(4000), "'");
    const r = stripLargeInlineImages(html, 100);
    expect(r.strippedCount).toBe(1);
  });

  it("leaves non-data images and other content alone", () => {
    const html = '<img src="https://example.com/x.png"><div>text</div>';
    const r = stripLargeInlineImages(html, 100);
    expect(r.html).toBe(html);
    expect(r.strippedCount).toBe(0);
  });
});

describe("strippedImagesWarning", () => {
  it("returns null when nothing was stripped", () => {
    expect(strippedImagesWarning({ html: "", strippedCount: 0, strippedBytes: 0 })).toBeNull();
  });

  it("describes what was stripped and how to get it back", () => {
    const w = strippedImagesWarning({ html: "", strippedCount: 2, strippedBytes: 7 * 1024 * 1024 });
    expect(w).toContain("2 inline images");
    expect(w).toContain("7.0 MB");
    expect(w).toContain("fetch-attachment");
    expect(w).toContain("APPLE_NOTES_MCP_MAX_INLINE_IMAGE_BYTES");
  });
});
