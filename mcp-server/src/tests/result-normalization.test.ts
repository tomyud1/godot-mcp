/**
 * Verifies how encoded images are put on the wire.
 *
 * These matter because the failure mode is silent and expensive: a base64 PNG
 * delivered as text is invisible to a vision model and costs hundreds of
 * thousands of tokens.
 */
import { describe, it, expect } from 'vitest';
import { normalizeResult } from '../result-normalize.js';

const PNG_BASE64 = 'iVBORw0KGgoAAAANSUhEUg' + 'A'.repeat(200_000);

function screenshotResult(withBase64: boolean) {
  const body: Record<string, unknown> = {
    ok: true,
    resource_path: 'res://addons/godot_mcp/cache/screenshots/shot.png',
    absolute_path: '/project/addons/godot_mcp/cache/screenshots/shot.png',
    width: 1568,
    height: 884,
    original_width: 3840,
    original_height: 2160,
    downscaled: true,
    bytes: 150_000,
  };
  if (withBase64) body.base64_png = PNG_BASE64;
  return { content: [{ type: 'text' as const, text: JSON.stringify(body, null, 2) }] };
}

describe('normalizeResult — image handling', () => {
  it('drops base64 by default and keeps the metadata', () => {
    const out = normalizeResult(screenshotResult(true), 'drop');
    const text = out.content[0] as { type: 'text'; text: string };
    expect(text.text).not.toContain('base64_png');
    expect(text.text).not.toContain(PNG_BASE64.slice(0, 200));
    // Metadata survives.
    expect(text.text).toContain('downscaled');
    expect(text.text).toContain('1568');
  });

  it('never puts base64 in structuredContent, so it cannot be duplicated', () => {
    const out = normalizeResult(screenshotResult(true), 'drop');
    const serialised = JSON.stringify(out.structuredContent ?? {});
    expect(serialised).not.toContain('base64_png');
  });

  it('emits a real image content block when asked, so a vision model can see it', () => {
    const out = normalizeResult(screenshotResult(true), 'emit');
    const image = out.content.find((c) => c.type === 'image') as
      | { type: 'image'; data: string; mimeType: string }
      | undefined;
    expect(image).toBeDefined();
    expect(image!.mimeType).toBe('image/png');
    expect(image!.data).toBe(PNG_BASE64);
  });

  it('puts the text metadata first so text-only clients still get it', () => {
    const out = normalizeResult(screenshotResult(true), 'emit');
    expect(out.content[0].type).toBe('text');
    expect(out.content[0].type === 'text' && out.content[0].text).toContain('resource_path');
  });

  it('emits the image exactly once even in emit mode', () => {
    const out = normalizeResult(screenshotResult(true), 'emit');
    const images = out.content.filter((c) => c.type === 'image');
    expect(images).toHaveLength(1);
  });

  it('leaves a screenshot with no base64 untouched', () => {
    const out = normalizeResult(screenshotResult(false), 'emit');
    expect(out.content.filter((c) => c.type === 'image')).toHaveLength(0);
    expect(out.structuredContent).toMatchObject({ ok: true, width: 1568 });
  });

  it('ignores small base64-looking fields, which are more likely identifiers', () => {
    const out = normalizeResult(
      { content: [{ type: 'text', text: JSON.stringify({ ok: true, data: 'short-id-1234' }) }] },
      'emit'
    );
    expect(out.content.filter((c) => c.type === 'image')).toHaveLength(0);
    expect(JSON.stringify(out.structuredContent)).toContain('short-id-1234');
  });

  it('passes non-JSON text results through untouched', () => {
    const out = normalizeResult({ content: [{ type: 'text', text: 'not json' }] }, 'emit');
    expect(out.content).toHaveLength(1);
    expect(out.structuredContent).toBeUndefined();
  });

  it('leaves plain tool results working as before', () => {
    const out = normalizeResult(
      { content: [{ type: 'text', text: JSON.stringify({ ok: true, path: 'res://a.gd' }) }] },
      'drop'
    );
    expect(out.structuredContent).toEqual({ ok: true, path: 'res://a.gd' });
  });

  it('truncates an oversized result and says so, rather than silently trimming', () => {
    const huge = { ok: true, blob: 'x'.repeat(6 * 1024 * 1024) };
    const out = normalizeResult(
      { content: [{ type: 'text', text: JSON.stringify(huge) }] },
      'drop'
    );
    const text = out.content[0] as { type: 'text'; text: string };
    expect(text.text).toContain('truncated');
    expect(text.text).toContain('over the');
    // The agent must not be handed the partial payload as if it were complete.
    expect(out.structuredContent).toBeUndefined();
  });

  it('does not truncate an image block, since that would corrupt it', () => {
    const withImage = normalizeResult(screenshotResult(true), 'emit');
    expect(withImage.content.some((c) => c.type === 'image')).toBe(true);
  });
});
