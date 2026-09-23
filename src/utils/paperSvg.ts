/**
 * SVG rendering of decoded Paper strokes.
 *
 * Input is the stroke JSON the private helper reads from PencilKit. Each
 * stroke becomes one round-capped polyline through its recorded points, in
 * its own ink color and mean width, with the stroke's affine transform. No
 * point is added, removed or smoothed. Colors are written as byte-scale
 * `rgba(R,G,B,A)`: R, G and B are 0..255 and A stays 0..1, which is the form
 * the SVG analyzer reads back.
 *
 * The rendering is a faithful outline of the recorded geometry, not a pixel
 * match: PencilKit inks vary width along a stroke and add texture, which SVG
 * strokes cannot express.
 *
 * @module utils/paperSvg
 */

/** The stroke fields the renderer needs. */
export interface SvgStrokeInput {
  color: [number, number, number, number] | null;
  width: number;
  transform: [number, number, number, number, number, number] | null;
  /** Point rows whose first two values are x and y. */
  points?: number[][];
}

export interface PaperSvgInput {
  bounds: [number, number, number, number] | null;
  strokes: SvgStrokeInput[];
}

export interface PaperSvgResult {
  svg: string;
  /** Strokes drawn. */
  pathCount: number;
  /** Strokes skipped because their points were not returned. */
  skippedStrokes: number;
}

/** Shortest decimal form with at most `digits` fraction digits; never "-0". */
export function formatNumber(value: number, digits = 3): string {
  const text = Number(value.toFixed(digits)).toString();
  return text === "-0" ? "0" : text;
}

function clamp01(value: number): number {
  return Math.min(1, Math.max(0, value));
}

/** `rgba(R,G,B,A)` with byte-scale channels, or black when the color is unknown. */
export function rgbaCss(color: [number, number, number, number] | null): string {
  if (!color) return "rgba(0,0,0,1)";
  const [r, g, b] = color.slice(0, 3).map((c) => Math.round(clamp01(c) * 255));
  return `rgba(${r},${g},${b},${formatNumber(clamp01(color[3]), 4)})`;
}

function isIdentity(t: [number, number, number, number, number, number]): boolean {
  return t[0] === 1 && t[1] === 0 && t[2] === 0 && t[3] === 1 && t[4] === 0 && t[5] === 0;
}

/** Path data through every point; a single point becomes a zero-length dot. */
export function strokePathData(points: number[][]): string {
  const coords = points.map((p) => `${formatNumber(p[0])} ${formatNumber(p[1])}`);
  if (coords.length === 1) coords.push(coords[0]);
  return `M ${coords.join(" L ")}`;
}

/** Render decoded strokes as a standalone SVG document. */
export function paperToSvg(input: PaperSvgInput): PaperSvgResult {
  const [x, y, w, h] = input.bounds ?? [0, 0, 1, 1];
  const width = Math.max(w, 1);
  const height = Math.max(h, 1);
  const parts = [
    `<svg xmlns="http://www.w3.org/2000/svg" width="${formatNumber(width, 2)}" ` +
      `height="${formatNumber(height, 2)}" viewBox="${formatNumber(x)} ${formatNumber(y)} ` +
      `${formatNumber(width)} ${formatNumber(height)}">`,
  ];
  let pathCount = 0;
  let skippedStrokes = 0;
  for (const stroke of input.strokes) {
    if (!stroke.points || stroke.points.length === 0) {
      skippedStrokes++;
      continue;
    }
    const attrs = [
      `d="${strokePathData(stroke.points)}"`,
      'fill="none"',
      `stroke="${rgbaCss(stroke.color)}"`,
      `stroke-width="${formatNumber(Math.max(stroke.width, 0))}"`,
      'stroke-linecap="round"',
      'stroke-linejoin="round"',
    ];
    if (stroke.transform && !isIdentity(stroke.transform))
      attrs.push(
        `transform="matrix(${stroke.transform.map((n) => formatNumber(n, 6)).join(" ")})"`
      );
    parts.push(`<path ${attrs.join(" ")}/>`);
    pathCount++;
  }
  parts.push("</svg>");
  return { svg: parts.join("\n") + "\n", pathCount, skippedStrokes };
}
