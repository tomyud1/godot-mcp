#!/usr/bin/env node
/**
 * Build script for the Godot Project Map Visualizer
 * Bundles CSS and JS modules into a single HTML file
 */

import { readFileSync, writeFileSync, mkdirSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import { build } from 'esbuild';

const __dirname = dirname(fileURLToPath(import.meta.url));
const srcDir = join(__dirname, '..', 'src', 'visualizer');
const distDir = join(__dirname, '..', 'dist');

async function buildVisualizer() {
  console.log('Building visualizer...');

  // Ensure dist directory exists
  mkdirSync(distDir, { recursive: true });

  // 1. Read the HTML template
  const template = readFileSync(join(srcDir, 'template.html'), 'utf-8');

  // 2. Read the CSS
  const css = readFileSync(join(srcDir, 'visualizer.css'), 'utf-8');

  // 3. Bundle JavaScript using esbuild
  const jsResult = await build({
    entryPoints: [join(srcDir, 'main.js')],
    bundle: true,
    format: 'iife',
    minify: false, // Keep readable for debugging
    write: false,
    target: ['es2020'],
    sourcemap: false,
  });

  const bundledJs = jsResult.outputFiles[0].text;

  // 4. Combine everything into the final HTML
  let html = template
    .replace('%%CSS%%', css)
    .replace('%%SCRIPT%%', bundledJs);

  // 5. Write the output file
  const outputPath = join(distDir, 'visualizer.html');
  writeFileSync(outputPath, html, 'utf-8');

  console.log(`Visualizer built successfully: ${outputPath}`);

  // Print some stats
  const lines = html.split('\n').length;
  const size = Buffer.byteLength(html, 'utf-8');
  console.log(`  Lines: ${lines}`);
  console.log(`  Size: ${(size / 1024).toFixed(1)} KB`);
}

buildVisualizer().catch(err => {
  console.error('Build failed:', err);
  process.exit(1);
});
