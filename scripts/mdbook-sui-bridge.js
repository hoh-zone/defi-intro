/**
 * mdBook + highlight.js: register highlightjs-sui grammar and re-highlight all code blocks.
 * Built to theme/highlight-sui-move.bundle.js (IIFE) — see package.json "build:highlight".
 * Upstream: https://github.com/hoh-zone/highlightjs-sui
 */
const suiMove = require('highlightjs-sui');

function run() {
  if (typeof hljs === 'undefined') {
    console.warn('highlightjs-sui (mdbook): global hljs not found');
    return;
  }
  hljs.registerLanguage('sui-move', suiMove);
  hljs.registerLanguage('move-sui', suiMove);
  hljs.registerLanguage('sui', suiMove);
  hljs.registerLanguage('move2024', suiMove);
  // 全书 fenced 块大量使用 ```move —— 与 sui-move 共用同一语法
  hljs.registerLanguage('move', suiMove);

  document.querySelectorAll('pre code').forEach(function (block) {
    hljs.highlightElement(block);
  });
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', run);
} else {
  run();
}
