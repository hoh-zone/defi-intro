/**
 * Wraps highlightjs-sui with extra rules so type annotations read clearly:
 *   tick_lower : u32
 *   ^property  ^punctuation  ^type (Move 仅有 u8…u256；highlightjs-sui 自带的 i* 词从 keywords.type 中剔除以免误导)
 *
 * Loaded by scripts/mdbook-sui-bridge.js and bundled for mdBook.
 */
const upstream = require('highlightjs-sui');

/** Sui Move 无原生有符号整数；上游 grammar 的 i8…i256 易误导，从 keyword.type 列表移除。 */
function stripFakeSignedPrimitives(keywords) {
  if (!keywords || keywords.type === undefined) return;
  const t = keywords.type;
  const drop = (x) => !/^(i8|i16|i32|i64|i128|i256)$/.test(x);
  if (Array.isArray(t)) {
    keywords.type = t.filter(drop);
  } else if (typeof t === 'string') {
    keywords.type = t.split(/\s+/).filter(drop).join(' ');
  }
}

function extraContainsV10(hljs) {
  return [
    {
      className: 'property',
      relevance: 10,
      begin: /\b[a-zA-Z_][a-zA-Z0-9_]*(?=\s*:[^:])/,
    },
    {
      className: 'punctuation',
      relevance: 9,
      begin: /:\s*(?!:)/,
    },
  ];
}

function extraContainsV11() {
  return [
    {
      scope: 'property',
      match: /\b[a-zA-Z_][a-zA-Z0-9_]*(?=\s*:[^:])/,
      relevance: 10,
    },
    {
      scope: 'punctuation',
      match: /:\s*(?!:)/,
      relevance: 9,
    },
  ];
}

/** Insert after ADDRESS_LITERAL so strings/comments/numbers match first (highlightjs-sui order). */
const INSERT_EXTRA_AFTER_INDEX = 8;

module.exports = function suiMoveWithTypeAnnotations(hljs) {
  const base = upstream(hljs);
  stripFakeSignedPrimitives(base.keywords);
  const v11 = hljs.regex != null;
  const extra = v11 ? extraContainsV11() : extraContainsV10(hljs);
  const c = base.contains;
  base.contains = c
    .slice(0, INSERT_EXTRA_AFTER_INDEX)
    .concat(extra)
    .concat(c.slice(INSERT_EXTRA_AFTER_INDEX));
  return base;
};
