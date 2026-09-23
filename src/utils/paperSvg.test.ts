import { describe, expect, it } from "vitest";
import { formatNumber, paperToSvg, rgbaCss, strokePathData } from "./paperSvg.js";

const ID: [number, number, number, number, number, number] = [1, 0, 0, 1, 0, 0];

describe("formatNumber", () => {
  it("trims trailing zeros, rounds, and never writes -0", () => {
    expect(formatNumber(1.5)).toBe("1.5");
    expect(formatNumber(2)).toBe("2");
    expect(formatNumber(0.12345)).toBe("0.123");
    expect(formatNumber(-0.0001)).toBe("0");
    expect(formatNumber(1.23456789, 6)).toBe("1.234568");
  });
});

describe("rgbaCss", () => {
  it("writes byte-scale RGB with 0..1 alpha", () => {
    expect(rgbaCss([1, 0.5, 0, 0.25])).toBe("rgba(255,128,0,0.25)");
    expect(rgbaCss([0.0039, 0, 1, 1])).toBe("rgba(1,0,255,1)");
  });
  it("clamps out-of-range channels", () => {
    expect(rgbaCss([1.2, -0.1, 0.5, 2])).toBe("rgba(255,0,128,1)");
  });
  it("falls back to opaque black for an unknown color", () => {
    expect(rgbaCss(null)).toBe("rgba(0,0,0,1)");
  });
});

describe("strokePathData", () => {
  it("draws a polyline through every recorded point in order", () => {
    expect(
      strokePathData([
        [0, 0, 9],
        [10.25, 5],
        [20, 0.0004],
      ])
    ).toBe("M 0 0 L 10.25 5 L 20 0");
  });
  it("turns a single point into a zero-length dot", () => {
    expect(strokePathData([[3, 4]])).toBe("M 3 4 L 3 4");
  });
});

describe("paperToSvg", () => {
  it("renders one round-capped path per stroke with viewBox from the bounds", () => {
    const r = paperToSvg({
      bounds: [10, 20, 300, 150.5],
      strokes: [
        {
          color: [0, 0, 0, 1],
          width: 2.5,
          transform: ID,
          points: [
            [10, 20],
            [30, 40],
          ],
        },
        {
          color: [1, 0, 0, 0.5],
          width: 4,
          transform: [2, 0, 0, 2, 5, -5],
          points: [
            [1, 1],
            [2, 2],
          ],
        },
      ],
    });
    expect(r.pathCount).toBe(2);
    expect(r.skippedStrokes).toBe(0);
    expect(r.svg).toContain('viewBox="10 20 300 150.5"');
    expect(r.svg).toContain('width="300" height="150.5"');
    expect(r.svg).toContain(
      '<path d="M 10 20 L 30 40" fill="none" stroke="rgba(0,0,0,1)" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/>'
    );
    expect(r.svg).toContain('stroke="rgba(255,0,0,0.5)"');
    expect(r.svg).toContain('transform="matrix(2 0 0 2 5 -5)"');
    // No separate stroke-opacity: alpha lives only in the color.
    expect(r.svg).not.toContain("stroke-opacity");
    expect(r.svg.startsWith('<svg xmlns="http://www.w3.org/2000/svg"')).toBe(true);
    expect(r.svg.trimEnd().endsWith("</svg>")).toBe(true);
  });

  it("skips strokes whose points were not returned and tolerates missing bounds", () => {
    const r = paperToSvg({
      bounds: null,
      strokes: [
        { color: null, width: -1, transform: null, points: [[0, 0]] },
        { color: [0, 0, 0, 1], width: 1, transform: ID },
        { color: [0, 0, 0, 1], width: 1, transform: ID, points: [] },
      ],
    });
    expect(r.pathCount).toBe(1);
    expect(r.skippedStrokes).toBe(2);
    expect(r.svg).toContain('viewBox="0 0 1 1"');
    expect(r.svg).toContain('stroke-width="0"');
    expect(r.svg).not.toContain("transform=");
  });
});
