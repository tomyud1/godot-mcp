/**
 * Final shaping of a Godot tool result before it goes on the wire.
 *
 * Every tool returns a JSON object that the server stringifies into a text
 * content block. Three problems follow from that, all fixed here in one place
 * so every tool benefits:
 *
 *  1. **Images were invisible.** Base64 PNGs sat inside the JSON string, so
 *     they reached the model as *text*. A vision model cannot read that, and a
 *     1080p frame is 1-3 MB of it. `imageMode: 'emit'` lifts them into a real
 *     MCP image content block.
 *  2. **Images were sent twice.** The payload appeared in the text block and
 *     again in `structuredContent`, doubling the most expensive thing the
 *     server can produce. Binary fields are now stripped from the JSON body.
 *  3. **Results grew without bound.** A scene tree or console dump scales with
 *     the project, and an oversized result silently evicts the conversation.
 *     Oversized results are replaced with an explicit truncation notice.
 */

import type { ToolCallResult, ContentBlock } from './types.js';

/** Fields that carry encoded binary rather than information. */
const BINARY_FIELDS: ReadonlyArray<{ field: string; mimeType: string }> = [
  { field: 'base64_png', mimeType: 'image/png' },
  { field: 'base64', mimeType: 'image/png' },
  { field: 'image_base64', mimeType: 'image/png' },
  { field: 'data', mimeType: 'image/png' },
];

/**
 * Ceiling on a single tool result, in bytes of JSON.
 *
 * A field shorter than this is far more likely to be an identifier than an
 * image, so small base64-looking values are left alone.
 */
const BINARY_MIN_LENGTH = 64 * 1024;

const MAX_RESULT_BYTES = parseInt(process.env.GODOT_MCP_MAX_RESULT_BYTES || String(4 * 1024 * 1024), 10);

/**
 * What to do with an encoded image found in the result.
 *   'emit' -> return an image content block, so the model can see it
 *   'drop' -> omit the bytes and keep the metadata (the default: the agent can
 *             read the saved file, and a non-multimodal agent never wanted a
 *             megabyte of base64 it could not interpret anyway)
 */
export type ImageMode = 'emit' | 'drop';

export function normalizeResult(
  result: ToolCallResult,
  imageMode: ImageMode = 'drop'
): ToolCallResult {
  const textBlock = result.content.find(
    (c): c is { type: 'text'; text: string } =>
      c.type === 'text' && typeof (c as { text?: unknown }).text === 'string'
  );
  if (!textBlock) return result;

  let parsed: unknown;
  try {
    parsed = JSON.parse(textBlock.text);
  } catch {
    return result; // Not JSON — the text block is the only representation.
  }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return result;

  const obj = parsed as Record<string, unknown>;
  const images: ContentBlock[] = [];
  let lifted = false;

  for (const { field, mimeType } of BINARY_FIELDS) {
    const value = obj[field];
    if (typeof value !== 'string' || value.length < BINARY_MIN_LENGTH) continue;
    lifted = true;
    if (imageMode === 'emit') {
      images.push({ type: 'image', data: value, mimeType });
    }
    delete obj[field];
  }

  // Text first, so a client that only reads text still sees the metadata.
  const out: ToolCallResult = {
    ...result,
    content: [
      { type: 'text', text: JSON.stringify(obj, null, 2) },
      ...images,
      ...result.content.filter((c) => c !== textBlock),
    ],
  };

  // Never re-add the base64: that duplication is the bug this replaces.
  if (!out.structuredContent) {
    out.structuredContent = obj;
  }

  return capResultSize(out, lifted);
}

/**
 * Replace an oversized result with a truncation notice.
 *
 * Image blocks are exempt: they are delivered for their visual value and are
 * already bounded by the addon's own byte cap, so trimming them would corrupt
 * them silently.
 */
function capResultSize(result: ToolCallResult, hadImage: boolean): ToolCallResult {
  const size = Buffer.byteLength(JSON.stringify(result.content), 'utf8');
  if (size <= MAX_RESULT_BYTES) return result;

  return {
    ...result,
    structuredContent: undefined,
    content: [
      {
        type: 'text',
        text: JSON.stringify(
          {
            ok: true,
            truncated: true,
            reason: `Result was ${size} bytes, over the ${MAX_RESULT_BYTES} byte limit.`,
            hint: hadImage
              ? 'Narrow the query, or lower max_dimension / max_bytes. The image block was not trimmed.'
              : 'Narrow the query — most large results accept a limit, max_results, or start_line/end_line argument.',
          },
          null,
          2
        ),
      },
    ],
  };
}
