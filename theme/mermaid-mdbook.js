/**
 * Render ```mermaid fenced blocks as Mermaid diagrams (mdBook has no built-in Mermaid).
 * Loads after theme/mermaid.min.js. Theme follows mdBook light/dark (ayu, navy, coal = dark).
 */
(function () {
  function mermaidTheme() {
    var html = document.documentElement;
    var dark = ['ayu', 'navy', 'coal'];
    for (var i = 0; i < dark.length; i++) {
      if (html.classList.contains(dark[i])) return 'dark';
    }
    return 'default';
  }

  /** After theme switch, reload so Mermaid picks up default vs dark (same idea as mdbook-mermaid). */
  function wireThemeReload() {
    var darkThemes = ['ayu', 'navy', 'coal'];
    var lightThemes = ['light', 'rust'];
    var classList = document.getElementsByTagName('html')[0].classList;
    var lastThemeWasLight = true;
    var i;
    for (i = 0; i < classList.length; i++) {
      if (darkThemes.indexOf(classList[i]) !== -1) {
        lastThemeWasLight = false;
        break;
      }
    }
    darkThemes.forEach(function (darkTheme) {
      var el = document.getElementById('mdbook-theme-' + darkTheme);
      if (!el) return;
      el.addEventListener('click', function () {
        if (lastThemeWasLight) window.location.reload();
      });
    });
    lightThemes.forEach(function (lightTheme) {
      var el = document.getElementById('mdbook-theme-' + lightTheme);
      if (!el) return;
      el.addEventListener('click', function () {
        if (!lastThemeWasLight) window.location.reload();
      });
    });
  }

  function blocksToDiagrams() {
    document.querySelectorAll('pre code.language-mermaid').forEach(function (code) {
      var pre = code.parentNode;
      if (!pre || pre.tagName !== 'PRE') return;
      var div = document.createElement('div');
      div.className = 'mermaid';
      div.textContent = code.textContent;
      pre.parentNode.replaceChild(div, pre);
    });
  }

  function run() {
    if (typeof mermaid === 'undefined') {
      console.warn('mermaid-mdbook: mermaid global not found');
      return;
    }
    mermaid.initialize({
      startOnLoad: false,
      theme: mermaidTheme(),
      securityLevel: 'loose',
    });
    blocksToDiagrams();
    var p = mermaid.run();
    if (p && typeof p.then === 'function') {
      p.catch(function (e) {
        console.warn('mermaid.run:', e);
      });
    }
    wireThemeReload();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', run);
  } else {
    run();
  }
})();
