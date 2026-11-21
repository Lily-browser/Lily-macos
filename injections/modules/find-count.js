// How many times the Find bar's text appears in the page (Find in page, FindInPage.swift), and which
// of them WebKit has selected ("3 of 12"). WebKit's own search selects the matches; this only counts
// them, case-insensitively, in the page's visible text, up to MAX. The position is known when the
// selected match is in this frame's text; otherwise `index` is null and only the count shows.
(() => {
  "use strict";
  const lily = window.__lily;
  if (!lily || !lily.isMainFrame || window.__lilyFindCount) return;
  window.__lilyFindCount = true;

  const MAX = 1000;
  const MAX_QUERY = 500;

  lily.register("find.count", ({ query } = {}) => {
    if (typeof query !== "string" || !query || query.length > MAX_QUERY || !document.body) return { count: 0 };
    const needle = query.toLocaleLowerCase();
    const text = document.body.innerText.toLocaleLowerCase();
    let count = 0;
    for (let at = text.indexOf(needle); at !== -1 && count < MAX; at = text.indexOf(needle, at + needle.length)) count += 1;
    return { count, index: selectedIndex(needle, count) };
  });

  // The 1-based position of the current selection among the matches, or null.
  function selectedIndex(needle, count) {
    try {
      const selection = window.getSelection();
      if (!selection || !selection.rangeCount || selection.isCollapsed || selection.toString().toLocaleLowerCase() !== needle) return null;
      const range = selection.getRangeAt(0);
      const before = document.createRange();
      before.selectNodeContents(document.body);
      before.setEnd(range.startContainer, range.startOffset);
      const text = before.toString().toLocaleLowerCase();
      let seen = 0;
      for (let at = text.indexOf(needle); at !== -1 && seen < MAX; at = text.indexOf(needle, at + needle.length)) seen += 1;
      return Math.min(seen + 1, count);
    } catch (_) {
      return null;
    }
  }
})();
