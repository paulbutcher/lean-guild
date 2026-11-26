// Copyright (c) 2026 Paul Butcher. All rights reserved.
// Released under Apache 2.0 license as described in the file LICENSE.

// Shows each new notice as a browser notification while a page of the UI is open. The page
// carries the newest notice in #latest-notice, and HTMX redraws it every few seconds.
(function () {
  const key = "guild-latest-notice";
  function check() {
    const el = document.getElementById("latest-notice");
    if (!el) return;
    const latest = Number(el.dataset.id || 0);
    const before = Number(localStorage.getItem(key) || 0);
    localStorage.setItem(key, String(latest));
    // The first page seen sets the mark rather than announcing everything already there.
    if (before > 0 && latest > before && "Notification" in window && Notification.permission === "granted") {
      new Notification("The guild: a notice", { body: el.dataset.text || "" });
    }
  }
  document.addEventListener("htmx:afterSettle", check);
  document.addEventListener("DOMContentLoaded", function () {
    check();
    const button = document.getElementById("notify-on");
    if (button && "Notification" in window && Notification.permission === "default") {
      button.hidden = false;
      button.addEventListener("click", function () {
        Notification.requestPermission().then(function () { button.hidden = true; });
      });
    }
  });
})();
