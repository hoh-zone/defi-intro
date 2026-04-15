(() => {
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __commonJS = (cb, mod) => function __require() {
    return mod || (0, cb[__getOwnPropNames(cb)[0]])((mod = { exports: {} }).exports, mod), mod.exports;
  };

  // node_modules/highlightjs-sui/src/languages/sui-move.js
  var require_sui_move = __commonJS({
    "node_modules/highlightjs-sui/src/languages/sui-move.js"(exports, module) {
      var KEYWORDS = [
        "module",
        "struct",
        "enum",
        "fun",
        "const",
        "use",
        "type",
        "macro",
        "public",
        "entry",
        "native",
        "inline",
        "package",
        "if",
        "else",
        "while",
        "loop",
        "for",
        "in",
        "match",
        "break",
        "continue",
        "return",
        "abort",
        "let",
        "mut",
        "move",
        "copy",
        "has",
        "as",
        "Self",
        "phantom",
        "is"
      ];
      var LITERALS = ["true", "false"];
      var TYPES = [
        "u8",
        "u16",
        "u32",
        "u64",
        "u128",
        "u256",
        "i8",
        "i16",
        "i32",
        "i64",
        "i128",
        "i256",
        "bool",
        "address",
        "signer",
        "vector",
        "UID",
        "ID",
        "TxContext",
        "Receiving",
        // Common Move std / Sui examples (module `std::string` / `std::option`)
        "String",
        "Option"
      ];
      var LAMBDA_TYPE_PATTERN = new RegExp(`\\b(?:${TYPES.join("|")})\\b`);
      var BUILTINS = [
        "assert!",
        // sui::transfer
        "public_transfer",
        "public_share_object",
        "public_freeze_object",
        "public_receive",
        "share_object",
        "freeze_object",
        "receive",
        // sui::object
        "new",
        "delete",
        "id",
        "uid_to_inner",
        "to_id",
        "from_id",
        "id_to_address",
        "bytes_to_address",
        // sui::tx_context
        "sender",
        "epoch",
        "epoch_timestamp_ms",
        "digest",
        "fresh_object_address",
        "ids_created",
        // std::vector
        "length",
        "push_back",
        "pop_back",
        "borrow",
        "borrow_mut",
        "swap_remove",
        "destroy_empty",
        "empty",
        "singleton",
        "append",
        "reverse",
        // std::option
        "contains",
        "destroy_none",
        "get_with_default",
        "is_some",
        "is_none",
        "some",
        "none",
        // sui::address / sui::bcs (and similar helpers)
        "to_bytes",
        "from_bytes",
        // sui::coin / balance (common in examples)
        "value",
        "zero",
        "split",
        "join",
        "take",
        "into_balance",
        // sui::event
        "emit"
      ];
      function buildGrammarV11(hljs) {
        const regex = hljs.regex;
        const BLOCK_COMMENT = hljs.COMMENT(/\/\*/, /\*\//, { contains: ["self"] });
        const DOC_COMMENT = hljs.COMMENT(/\/\/\//, /$/, {
          contains: [
            {
              scope: "doctag",
              match: /@\w+/
            }
          ]
        });
        const LINE_COMMENT = hljs.COMMENT(/\/\//, /$/, {});
        const BYTE_STRING = {
          scope: "string",
          begin: /b"/,
          end: /"/,
          contains: [{ match: /\\./ }],
          relevance: 10
        };
        const HEX_STRING = {
          scope: "string",
          begin: /x"/,
          end: /"/,
          relevance: 10
        };
        const NUMBER = {
          scope: "number",
          relevance: 0,
          variants: [
            { match: /\b0x[0-9a-fA-F][0-9a-fA-F_]*(?:[ui](?:8|16|32|64|128|256))?\b/ },
            { match: /\b[0-9][0-9_]*(?:[ui](?:8|16|32|64|128|256))?\b/ },
            {
              match: /-(?:0x[0-9a-fA-F][0-9a-fA-F_]*|[0-9][0-9_]*)(?:[ui](?:8|16|32|64|128|256))?\b/
            }
          ]
        };
        const ADDRESS_LITERAL = {
          scope: "symbol",
          match: /@(?:0x[0-9a-fA-F][0-9a-fA-F_]*|[a-zA-Z_]\w*)/,
          relevance: 10
        };
        const BACKTICK_IDENTIFIER = {
          scope: "variable",
          begin: /`/,
          end: /`/,
          excludeBegin: false,
          excludeEnd: false
        };
        const MACRO_INVOCATION = {
          scope: "title.function.invoke",
          match: /\b[a-zA-Z_][a-zA-Z0-9_]*!/,
          relevance: 3
        };
        const LOOP_LABEL = {
          scope: "symbol",
          match: /'[a-zA-Z_][a-zA-Z0-9_]*:?/,
          relevance: 0
        };
        const ATTRIBUTE = {
          scope: "meta",
          begin: /#\[/,
          end: /\]/,
          contains: [
            {
              scope: "keyword",
              match: /[a-zA-Z_]\w*/
            },
            {
              begin: /\(/,
              end: /\)/,
              contains: [
                { scope: "string", begin: /"/, end: /"/ },
                { scope: "number", match: /\b\d+\b/ },
                { match: /[a-zA-Z_]\w*(?:::[a-zA-Z_]\w*)*/ },
                { match: /=/ }
              ]
            }
          ],
          relevance: 5
        };
        const MODULE_DECLARATION = {
          begin: [/\b(?:module)\b/, /\s+/, /(?:0x[0-9a-fA-F_]+|[a-zA-Z_]\w*)(?:::[a-zA-Z_]\w*)*/],
          beginScope: {
            1: "keyword",
            3: "title.class"
          },
          relevance: 10
        };
        const FUNCTION_DECLARATION = {
          begin: [/(?<!\buse\s)\bfun\b/, /\s+/, /[a-zA-Z_]\w*/],
          beginScope: {
            1: "keyword",
            3: "title.function"
          },
          relevance: 10
        };
        const MACRO_FUN_DECLARATION = {
          begin: [/\bmacro\b/, /\s+/, /\bfun\b/, /\s+/, /[a-zA-Z_]\w*/],
          beginScope: {
            1: "keyword",
            3: "keyword",
            5: "title.function"
          },
          relevance: 10
        };
        const STRUCT_DECLARATION = {
          begin: [/\bstruct\b/, /\s+/, /[A-Z]\w*/],
          beginScope: {
            1: "keyword",
            3: "title.class"
          },
          relevance: 10
        };
        const ENUM_DECLARATION = {
          begin: [/\benum\b/, /\s+/, /[A-Z]\w*/],
          beginScope: {
            1: "keyword",
            3: "title.class"
          },
          relevance: 10
        };
        const TYPE_ALIAS_DECLARATION = {
          begin: [/\btype\b/, /\s+/, /[a-zA-Z_][a-zA-Z0-9_]*/],
          beginScope: {
            1: "keyword",
            3: "title.class"
          },
          relevance: 10
        };
        const ABILITIES = {
          begin: /\bhas\b/,
          beginScope: "keyword",
          end: /[{;,)]/,
          returnEnd: true,
          contains: [
            {
              scope: "built_in",
              match: /\b(?:copy|drop|key|store)\b/
            },
            { match: /[+,]/ }
          ],
          relevance: 5
        };
        const MODULE_PATH = {
          scope: "title.class",
          match: /\b(?:0x[0-9a-fA-F_]+|[a-zA-Z_]\w*)(?:::[a-zA-Z_]\w*)+/,
          relevance: 0
        };
        const FUNCTION_INVOKE = {
          scope: "title.function.invoke",
          relevance: 0,
          begin: regex.concat(
            /\b/,
            /(?!let\b|for\b|while\b|if\b|else\b|match\b|loop\b|return\b|abort\b|break\b|continue\b|use\b|module\b|struct\b|enum\b|fun\b|const\b|type\b|macro\b)/,
            hljs.IDENT_RE,
            regex.lookahead(/\s*(?:<[^>]*>)?\s*\(/)
          )
        };
        const SELF_VARIABLE = {
          scope: "variable.language",
          match: /\bself\b/,
          relevance: 0
        };
        const VECTOR_LITERAL = {
          match: /\bvector\s*(?:<[^>]*>)?\s*\[/,
          scope: "built_in",
          returnEnd: true,
          relevance: 5
        };
        const LAMBDA_PARAMS = {
          begin: /\|/,
          end: /\|/,
          scope: "params",
          relevance: 0,
          contains: [
            {
              scope: "type",
              match: LAMBDA_TYPE_PATTERN
            },
            { match: /&\s*mut\b/, scope: "keyword" },
            { match: /&/, scope: "keyword" },
            NUMBER
          ]
        };
        return {
          name: "Sui Move",
          aliases: ["sui-move", "move-sui", "sui", "move2024"],
          unicodeRegex: true,
          keywords: {
            $pattern: `${hljs.IDENT_RE}!?`,
            keyword: KEYWORDS,
            literal: LITERALS,
            type: TYPES,
            built_in: BUILTINS
          },
          contains: [
            DOC_COMMENT,
            LINE_COMMENT,
            BLOCK_COMMENT,
            BYTE_STRING,
            HEX_STRING,
            BACKTICK_IDENTIFIER,
            NUMBER,
            ADDRESS_LITERAL,
            ATTRIBUTE,
            MODULE_DECLARATION,
            MACRO_FUN_DECLARATION,
            FUNCTION_DECLARATION,
            TYPE_ALIAS_DECLARATION,
            STRUCT_DECLARATION,
            ENUM_DECLARATION,
            ABILITIES,
            MODULE_PATH,
            VECTOR_LITERAL,
            LAMBDA_PARAMS,
            LOOP_LABEL,
            MACRO_INVOCATION,
            SELF_VARIABLE,
            FUNCTION_INVOKE
          ]
        };
      }
      function buildGrammarV10(hljs) {
        const BLOCK_COMMENT = hljs.COMMENT(/\/\*/, /\*\//, { contains: ["self"] });
        const DOC_COMMENT = hljs.COMMENT(/\/\/\//, /$/, {
          contains: [
            {
              className: "doctag",
              begin: /@\w+/
            }
          ]
        });
        const LINE_COMMENT = hljs.COMMENT(/\/\//, /$/, {});
        const BYTE_STRING = {
          className: "string",
          begin: /b"/,
          end: /"/,
          contains: [{ begin: /\\./ }],
          relevance: 10
        };
        const HEX_STRING = {
          className: "string",
          begin: /x"/,
          end: /"/,
          relevance: 10
        };
        const NUMBER = {
          className: "number",
          relevance: 0,
          variants: [
            { begin: /\b0x[0-9a-fA-F][0-9a-fA-F_]*(?:[ui](?:8|16|32|64|128|256))?\b/ },
            { begin: /\b[0-9][0-9_]*(?:[ui](?:8|16|32|64|128|256))?\b/ },
            {
              begin: /-(?:0x[0-9a-fA-F][0-9a-fA-F_]*|[0-9][0-9_]*)(?:[ui](?:8|16|32|64|128|256))?\b/
            }
          ]
        };
        const ADDRESS_LITERAL = {
          className: "symbol",
          begin: /@(?:0x[0-9a-fA-F][0-9a-fA-F_]*|[a-zA-Z_]\w*)/,
          relevance: 10
        };
        const BACKTICK_IDENTIFIER = {
          className: "variable",
          begin: /`/,
          end: /`/
        };
        const MACRO_INVOCATION = {
          className: "title function_",
          begin: /\b[a-zA-Z_][a-zA-Z0-9_]*!/,
          relevance: 3
        };
        const LOOP_LABEL = {
          className: "symbol",
          begin: /'[a-zA-Z_][a-zA-Z0-9_]*:?/,
          relevance: 0
        };
        const ATTRIBUTE = {
          className: "meta",
          begin: /#\[/,
          end: /\]/,
          contains: [
            {
              className: "keyword",
              begin: /[a-zA-Z_]\w*/
            },
            {
              begin: /\(/,
              end: /\)/,
              contains: [
                { className: "string", begin: /"/, end: /"/ },
                { className: "number", begin: /\b\d+\b/ },
                { begin: /[a-zA-Z_]\w*(?:::[a-zA-Z_]\w*)*/ },
                { begin: /=/ }
              ]
            }
          ],
          relevance: 5
        };
        const MODULE_DECLARATION = {
          beginKeywords: "module",
          end: /[{;]/,
          returnEnd: true,
          contains: [
            {
              className: "title",
              begin: /(?:0x[0-9a-fA-F_]+|[a-zA-Z_]\w*)(?:::[a-zA-Z_]\w*)*/,
              relevance: 0
            }
          ],
          relevance: 10
        };
        const MACRO_FUN_DECLARATION = {
          begin: /\bmacro\s+fun\b/,
          end: /[({;]/,
          returnEnd: true,
          contains: [
            {
              className: "title",
              begin: /[a-zA-Z_]\w*/,
              relevance: 0
            }
          ],
          relevance: 10
        };
        const FUNCTION_DECLARATION = {
          begin: /(?<!\buse\s)\bfun\b/,
          end: /[({;]/,
          returnEnd: true,
          contains: [
            {
              className: "title",
              begin: /[a-zA-Z_]\w*/,
              relevance: 0
            }
          ],
          relevance: 10
        };
        const STRUCT_DECLARATION = {
          beginKeywords: "struct",
          end: /[{(;]|\bhas\b/,
          returnEnd: true,
          contains: [
            {
              className: "title",
              begin: /[A-Z]\w*/,
              relevance: 0
            }
          ],
          relevance: 10
        };
        const ENUM_DECLARATION = {
          beginKeywords: "enum",
          end: /[{]|\bhas\b/,
          returnEnd: true,
          contains: [
            {
              className: "title",
              begin: /[A-Z]\w*/,
              relevance: 0
            }
          ],
          relevance: 10
        };
        const TYPE_ALIAS_DECLARATION = {
          beginKeywords: "type",
          end: /[=;({]/,
          returnEnd: true,
          contains: [
            {
              className: "title",
              begin: /[a-zA-Z_][a-zA-Z0-9_]*/,
              relevance: 0
            }
          ],
          relevance: 10
        };
        const ABILITIES = {
          begin: /\bhas\b/,
          end: /[{;,)]/,
          returnEnd: true,
          keywords: "has",
          contains: [
            {
              className: "built_in",
              begin: /\b(?:copy|drop|key|store)\b/
            },
            { begin: /[+,]/ }
          ],
          relevance: 5
        };
        const MODULE_PATH = {
          className: "title",
          begin: /\b(?:0x[0-9a-fA-F_]+|[a-zA-Z_]\w*)(?:::[a-zA-Z_]\w*)+/,
          relevance: 0
        };
        const FUNCTION_INVOKE = {
          className: "title function_",
          relevance: 0,
          begin: /\b(?!let\b|for\b|while\b|if\b|else\b|match\b|loop\b|return\b|abort\b|break\b|continue\b|use\b|module\b|struct\b|enum\b|fun\b|const\b|type\b|macro\b)[a-zA-Z_]\w*(?=\s*(?:<[^>]*>)?\s*\()/
        };
        const SELF_VARIABLE = {
          className: "variable language_",
          begin: /\bself\b/,
          relevance: 0
        };
        const VECTOR_LITERAL = {
          begin: /\bvector\s*(?:<[^>]*>)?\s*\[/,
          className: "built_in",
          returnEnd: true,
          relevance: 5
        };
        const LAMBDA_PARAMS = {
          begin: /\|/,
          end: /\|/,
          className: "params",
          relevance: 0,
          contains: [
            {
              className: "type",
              begin: LAMBDA_TYPE_PATTERN
            },
            { begin: /&\s*mut\b/, className: "keyword" },
            { begin: /&/, className: "keyword" },
            NUMBER
          ]
        };
        return {
          name: "Sui Move",
          aliases: ["sui-move", "move-sui", "sui", "move2024"],
          keywords: {
            $pattern: `${hljs.IDENT_RE}!?`,
            keyword: KEYWORDS.join(" "),
            literal: LITERALS.join(" "),
            type: TYPES.join(" "),
            built_in: BUILTINS.join(" ")
          },
          contains: [
            DOC_COMMENT,
            LINE_COMMENT,
            BLOCK_COMMENT,
            BYTE_STRING,
            HEX_STRING,
            BACKTICK_IDENTIFIER,
            NUMBER,
            ADDRESS_LITERAL,
            ATTRIBUTE,
            MODULE_DECLARATION,
            MACRO_FUN_DECLARATION,
            FUNCTION_DECLARATION,
            TYPE_ALIAS_DECLARATION,
            STRUCT_DECLARATION,
            ENUM_DECLARATION,
            ABILITIES,
            MODULE_PATH,
            VECTOR_LITERAL,
            LAMBDA_PARAMS,
            LOOP_LABEL,
            MACRO_INVOCATION,
            SELF_VARIABLE,
            FUNCTION_INVOKE
          ]
        };
      }
      module.exports = function suiMove(hljs) {
        return hljs.regex != null ? buildGrammarV11(hljs) : buildGrammarV10(hljs);
      };
    }
  });

  // scripts/sui-move-grammar.js
  var require_sui_move_grammar = __commonJS({
    "scripts/sui-move-grammar.js"(exports, module) {
      var upstream = require_sui_move();
      function stripFakeSignedPrimitives(keywords) {
        if (!keywords || keywords.type === void 0) return;
        const t = keywords.type;
        const drop = (x) => !/^(i8|i16|i32|i64|i128|i256)$/.test(x);
        if (Array.isArray(t)) {
          keywords.type = t.filter(drop);
        } else if (typeof t === "string") {
          keywords.type = t.split(/\s+/).filter(drop).join(" ");
        }
      }
      function extraContainsV10(hljs) {
        return [
          {
            className: "property",
            relevance: 10,
            begin: /\b[a-zA-Z_][a-zA-Z0-9_]*(?=\s*:[^:])/
          },
          {
            className: "punctuation",
            relevance: 9,
            begin: /:\s*(?!:)/
          }
        ];
      }
      function extraContainsV11() {
        return [
          {
            scope: "property",
            match: /\b[a-zA-Z_][a-zA-Z0-9_]*(?=\s*:[^:])/,
            relevance: 10
          },
          {
            scope: "punctuation",
            match: /:\s*(?!:)/,
            relevance: 9
          }
        ];
      }
      var INSERT_EXTRA_AFTER_INDEX = 8;
      module.exports = function suiMoveWithTypeAnnotations(hljs) {
        const base = upstream(hljs);
        stripFakeSignedPrimitives(base.keywords);
        const v11 = hljs.regex != null;
        const extra = v11 ? extraContainsV11() : extraContainsV10(hljs);
        const c = base.contains;
        base.contains = c.slice(0, INSERT_EXTRA_AFTER_INDEX).concat(extra).concat(c.slice(INSERT_EXTRA_AFTER_INDEX));
        return base;
      };
    }
  });

  // scripts/mdbook-sui-bridge.js
  var require_mdbook_sui_bridge = __commonJS({
    "scripts/mdbook-sui-bridge.js"() {
      var suiMove = require_sui_move_grammar();
      var PRIMARY = "sui-move";
      var ALIASES = ["move-sui", "sui", "move2024", "move"];
      var TARGET_LANG = { "sui-move": true, "move-sui": true, sui: true, move2024: true, move: true };
      function hljsRef() {
        return typeof globalThis !== "undefined" && globalThis.hljs ? globalThis.hljs : typeof window !== "undefined" && window.hljs ? window.hljs : void 0;
      }
      function highlightWithVersion(hljs, lang, text) {
        var v = String(hljs.versionString || "10");
        var major = parseInt(v.split(".")[0], 10);
        if (Number.isNaN(major)) major = 10;
        if (major >= 11) {
          return hljs.highlight(text, { language: lang });
        }
        return hljs.highlight(lang, text);
      }
      function run() {
        var hljs = hljsRef();
        if (!hljs) {
          console.warn("highlightjs-sui (mdbook): global hljs not found");
          return;
        }
        try {
          hljs.registerLanguage(PRIMARY, suiMove);
          if (typeof hljs.registerAliases === "function") {
            hljs.registerAliases(ALIASES, { languageName: PRIMARY });
          } else {
            ALIASES.forEach(function(name) {
              hljs.registerLanguage(name, suiMove);
            });
          }
        } catch (e) {
          console.error("highlightjs-sui (mdbook): registerLanguage failed", e);
          return;
        }
        document.querySelectorAll("pre code").forEach(function(block) {
          var m = block.className.match(/language-([\w-]+)\b/);
          if (!m) return;
          var lang = m[1];
          if (!TARGET_LANG[lang]) return;
          if (!hljs.getLanguage(lang)) return;
          var text = block.textContent;
          if (text === "") return;
          try {
            var result = highlightWithVersion(hljs, lang, text);
            block.innerHTML = result.value;
            block.className = "hljs language-" + lang;
          } catch (e) {
            console.warn("highlightjs-sui (mdbook): highlight failed for language " + lang, e);
          }
        });
      }
      function schedule() {
        run();
        setTimeout(run, 0);
      }
      if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", schedule);
      } else {
        schedule();
      }
    }
  });
  require_mdbook_sui_bridge();
})();
