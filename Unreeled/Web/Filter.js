// Unreeled filter engine.
//
// FilterScript (Rules.swift) injects this file at document start into every page a
// service loads, inside its own JavaScript world: the site's scripts can't see it or
// undo it. It then calls unreeled(rules) with the switched-on groups from Rules.json:
//
//   rules.hide      CSS selectors. Matching elements get display: none.
//   rules.redirect  [{ from, to }]. When a page's path + query matches the regular
//                   expression `from`, the tab goes to the path `to` instead.
//
// Debugging: run a Debug build, then on the Mac open Safari > Develop > (device) > the
// page. In the console, switch the JavaScript context to "Unreeled" to reach this world.

function unreeled(rules) {
  'use strict';

  // Hiding ------------------------------------------------------------------------
  // A stylesheet also covers content that arrives later (infinite scroll, client-side
  // page changes) with no extra work. One CSS rule per selector, so a selector WebKit
  // can't parse switches off only itself, not the whole list.
  const style = document.createElement('style');
  style.textContent = rules.hide
    .map((selector) => `${selector} { display: none !important; }`)
    .join('\n');
  const attachStyle = () => {
    if (!style.isConnected) (document.head || document.documentElement).append(style);
  };

  // Redirects ---------------------------------------------------------------------
  const redirects = rules.redirect.map((r) => ({ pattern: new RegExp(r.from), to: r.to }));

  // Where `href` should go instead, or null to leave it alone.
  const rewrite = (href) => {
    let url;
    try {
      url = new URL(href, document.baseURI);
    } catch {
      return null;
    }
    if (url.origin !== location.origin) return null;
    const path = url.pathname + url.search;
    const redirect = redirects.find((r) => r.pattern.test(path));
    if (!redirect) return null;
    const target = new URL(path.replace(redirect.pattern, redirect.to), location.origin).href;
    return target === url.href ? null : target;
  };

  // True when we already sent this tab to `target` a few times in the last 30 seconds:
  // two rules, or a rule and the site's own redirect, are bouncing a page back and
  // forth. Stopping keeps a bad rule from hammering the site with reloads.
  const isLooping = (target) => {
    try {
      const key = 'unreeled-redirects';
      const now = Date.now();
      const recent = JSON.parse(sessionStorage.getItem(key) ?? '[]')
        .filter((r) => now - r.time < 30000);
      const looping = recent.filter((r) => r.target === target).length >= 3;
      if (!looping) recent.push({ target, time: now });
      sessionStorage.setItem(key, JSON.stringify(recent));
      return looping;
    } catch {
      return false;
    }
  };

  // Taps on links: redirected before the site's own router sees them, so a blocked
  // page never starts rendering.
  addEventListener('click', (event) => {
    const link = event.target instanceof Element ? event.target.closest('a[href]') : null;
    const target = link && rewrite(link.getAttribute('href'));
    if (!target) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    location.assign(target);
  }, true);

  // Everything else (pages opened directly, client-side navigation with
  // history.pushState, back and forward): check the address whenever the page changes.
  let lastHref = null;
  const check = () => {
    attachStyle();
    if (location.href === lastHref) return;
    lastHref = location.href;
    const target = rewrite(location.href);
    if (!target) return;
    if (isLooping(target)) {
      console.warn('[Unreeled] Redirect loop, staying on', location.href);
      return;
    }
    location.replace(target);
  };

  new MutationObserver(check).observe(document.documentElement, { childList: true, subtree: true });
  addEventListener('popstate', check);
  check();
}
