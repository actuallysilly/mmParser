/* Shared sidebar + theme toggle for the MMA dev guide.
   One file so a new chapter is one line, not eleven edits. */

const MMA_CHAPTERS = [
  ["index.html",        "Start here",              "What this is, and the reading order"],
  ["01-ahk-primer.html","The AutoHotkey primer",   "The language, as this repo uses it"],
  ["02-shape.html",     "The shape of MMA",        "Eight processes, no shared memory"],
  ["03-spine.html",     "The spine: paths + log",  "One anchor, one timeline"],
  ["04-registries.html","The four registries",     "Features, hotkeys, messages, services"],
  ["05-what-a-mass-is.html", "What a mass IS",     "store.ahk and masses.json"],
  ["06-parser.html",    "The parser",              "Turning pasted text into fields"],
  ["07-send-path.html", "The send path",           "Keypress to message, end to end"],
  ["08-detection.html", "Detection",               "Which model is on screen"],
  ["09-gui.html",       "The GUI",                 "main_core, the shells, load/save"],
  ["10-import.html",    "Auto import",             "Discord Ctrl+click to filled tab"],
  ["11-recipes.html",   "Recipes and debugging",   "How to change things without breaking them"],
  ["12-traps.html",     "The trap museum",         "Every AHK landmine this repo has stepped on"]
];

(function () {
  // ── theme ───────────────────────────────────────────────────────────────
  try {
    const saved = localStorage.getItem("mma-guide-theme");
    if (saved) document.documentElement.setAttribute("data-theme", saved);
  } catch (e) { /* private window, blocked storage — the OS theme still applies */ }

  function buildTheme() {
    const b = document.createElement("button");
    b.className = "themebtn";
    b.textContent = "theme";
    b.onclick = () => {
      const el = document.documentElement;
      const now = el.getAttribute("data-theme");
      const dark = now ? now === "dark"
                       : matchMedia("(prefers-color-scheme: dark)").matches;
      const next = dark ? "light" : "dark";
      el.setAttribute("data-theme", next);
      try { localStorage.setItem("mma-guide-theme", next); } catch (e) {}
    };
    document.body.appendChild(b);
  }

  // ── sidebar ─────────────────────────────────────────────────────────────
  function buildNav() {
    const host = document.querySelector("nav.side");
    if (!host) return;
    const here = location.pathname.split("/").pop() || "index.html";

    const brand = document.createElement("div");
    brand.className = "brand";
    brand.innerHTML = "<b>MMA</b> dev guide";
    host.appendChild(brand);

    const h = document.createElement("h4");
    h.textContent = "Chapters";
    host.appendChild(h);

    const ol = document.createElement("ol");
    MMA_CHAPTERS.forEach(([href, title]) => {
      const li = document.createElement("li");
      const a = document.createElement("a");
      a.href = href;
      a.textContent = title;
      if (href === here) a.className = "here";
      li.appendChild(a);
      ol.appendChild(li);
    });
    host.appendChild(ol);

    const h2 = document.createElement("h4");
    h2.textContent = "Alongside";
    host.appendChild(h2);
    const plain = document.createElement("div");
    plain.className = "plain";
    plain.innerHTML =
      '<ol>' +
      '<li><a href="../../ARCHITECTURE.md">ARCHITECTURE.md</a></li>' +
      '<li><a href="../decisions.md">docs/decisions.md</a></li>' +
      '<li><a href="../mass-format.md">docs/mass-format.md</a></li>' +
      '<li><a href="../guide.html">The user guide</a></li>' +
      '</ol>';
    host.appendChild(plain);
  }

  // ── prev / next ─────────────────────────────────────────────────────────
  function buildPager() {
    const host = document.querySelector(".pager");
    if (!host) return;
    const here = location.pathname.split("/").pop() || "index.html";
    const i = MMA_CHAPTERS.findIndex(c => c[0] === here);
    if (i < 0) return;
    let html = "";
    if (i > 0)
      html += '<a class="prev" href="' + MMA_CHAPTERS[i - 1][0] + '">' +
              '<span>previous</span><b>' + MMA_CHAPTERS[i - 1][1] + '</b></a>';
    if (i < MMA_CHAPTERS.length - 1)
      html += '<a class="next" href="' + MMA_CHAPTERS[i + 1][0] + '">' +
              '<span>next</span><b>' + MMA_CHAPTERS[i + 1][1] + '</b></a>';
    host.innerHTML = html;
  }

  addEventListener("DOMContentLoaded", () => { buildTheme(); buildNav(); buildPager(); });
})();
