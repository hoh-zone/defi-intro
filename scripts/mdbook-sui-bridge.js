/**
 * mdBook + highlight.js: register highlightjs-sui grammar and apply Move highlighting.
 * Built to theme/highlight-sui-move.bundle.js (IIFE) — see package.json "build:highlight".
 * Upstream: https://github.com/hoh-zone/highlightjs-sui
 *
 * We use hljs.highlight(...) on raw text instead of highlightBlock alone: mdBook's book.js
 * runs highlightBlock before this script registers languages; relying on a second highlightBlock
 * can be fragile across hljs versions/browsers, so we re-highlight Move fences explicitly.
 */
const suiMove = require('./sui-move-grammar');

const PRIMARY = 'sui-move';
const ALIASES = ['move-sui', 'sui', 'move2024', 'move'];
/** Only these fences are re-highlighted (book.js already handled other languages). */
const TARGET_LANG = { 'sui-move': true, 'move-sui': true, sui: true, move2024: true, move: true };

function hljsRef() {
  return typeof globalThis !== 'undefined' && globalThis.hljs
    ? globalThis.hljs
    : typeof window !== 'undefined' && window.hljs
      ? window.hljs
      : undefined;
}

function highlightWithVersion(hljs, lang, text) {
  var v = String(hljs.versionString || '10');
  var major = parseInt(v.split('.')[0], 10);
  if (Number.isNaN(major)) major = 10;
  if (major >= 11) {
    return hljs.highlight(text, { language: lang });
  }
  return hljs.highlight(lang, text);
}

function run() {
  var hljs = hljsRef();
  if (!hljs) {
    console.warn('highlightjs-sui (mdbook): global hljs not found');
    return;
  }

  try {
    hljs.registerLanguage(PRIMARY, suiMove);
    if (typeof hljs.registerAliases === 'function') {
      hljs.registerAliases(ALIASES, { languageName: PRIMARY });
    } else {
      ALIASES.forEach(function (name) {
        hljs.registerLanguage(name, suiMove);
      });
    }
  } catch (e) {
    console.error('highlightjs-sui (mdbook): registerLanguage failed', e);
    return;
  }

  document.querySelectorAll('pre code').forEach(function (block) {
    var m = block.className.match(/language-([\w-]+)\b/);
    if (!m) return;
    var lang = m[1];
    if (!TARGET_LANG[lang]) return;
    if (!hljs.getLanguage(lang)) return;

    var text = block.textContent;
    if (text === '') return;

    try {
      var result = highlightWithVersion(hljs, lang, text);
      block.innerHTML = result.value;
      block.className = 'hljs language-' + lang;
    } catch (e) {
      console.warn('highlightjs-sui (mdbook): highlight failed for language ' + lang, e);
    }
  });
}

function schedule() {
  run();
  setTimeout(run, 0);
}

if (document.readyState === 'loading') {
  document.addEventListener('DOMContentLoaded', schedule);
} else {
  schedule();
}
