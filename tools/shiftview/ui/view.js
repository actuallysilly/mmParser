/*
  Fan Viewer (was Shift Viewer) — the host. Turns what the shift recorder saved into the Infloww
  clone's model (tools/inflowwclone/clone.js draws it). Data comes from
  shiftview.pyw (window.pywebview.api):
    fans()      one summary per recorded fan
    chat(id)    that fan's whole file (turns, islands, panel, panel_log)
    rebuild()   shiftlog.rebuild(): replay raw reads, fold name spellings
    media(path) one kept picture (a PPV's first image) as a data: URL
  It polls, so a shift being recorded right now shows up as it happens.
*/
var API = null;
var FANS = [], RAW = 0, CHAT = null, SRC = "fans", PENDING = 0;
var TEMP = false;              // a one-time view of a converted video: no Source switch
var ACC = null, SEL = null, FILTER = "all", SORT = 0, SEARCH = null, PTAB = "insights";
var STATUS = "", SIG = "";
var SORTS = ["Newest first", "Top spenders", "Most messages", "Name"];
var POLL_MS = 4000;
var PICS = {};                 // media path -> data URL, or "" while it loads

function clock(sec) {
  if (!sec) return "";
  var d = new Date(sec * 1000), now = new Date();
  var hm = d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }).toLowerCase();
  if (d.toDateString() === now.toDateString()) return hm;
  return d.toLocaleDateString([], { month: "short", day: "numeric" }) + ", " + hm;
}

function warnings(f) {
  var out = [];
  if (f.islands) out.push("⚠ " + f.islands + (f.islands === 1 ? " fragment" : " fragments"));
  // A fan file is keyed on his @handle, so several names is normal there.
  if (f.kind !== "fan" && f.names.length > 1) out.push("⚠ " + f.names.length + " spellings");
  if (f.messages && f.timed / f.messages < 0.5) out.push("⚠ few times");
  if (!f.has_panel) out.push("⚠ no panel");
  return out;
}

function accounts() {
  var by = {};
  FANS.forEach(function (f) {
    var a = by[f.account] || (by[f.account] = { id: f.account, name: f.account, badge: 0, last: 0 });
    a.badge += 1; a.last = Math.max(a.last, f.last_seen);
  });
  return Object.keys(by).map(function (k) { return by[k]; }).sort(function (a, b) { return b.last - a.last; });
}

function visible() {
  var q = (SEARCH || "").trim().toLowerCase();
  var rows = FANS.filter(function (f) {
    if (f.account !== ACC) return false;
    if (q && (f.fan + " " + f.names.join(" ")).toLowerCase().indexOf(q) < 0) return false;
    if (FILTER === "warn") return warnings(f).length > 0;
    if (FILTER === "ppv") return f.ppv > 0;
    if (FILTER === "paid") return f.paid > 0;
    return true;
  });
  rows.sort(function (a, b) {
    if (SORT === 1) return b.spend_value - a.spend_value;
    if (SORT === 2) return b.messages - a.messages;
    if (SORT === 3) return a.fan.localeCompare(b.fan);
    return b.last_seen - a.last_seen;
  });
  return rows;
}

function toMsg(t) {
  var tip = [];
  if (t.footer) tip.push("footer read: " + t.footer);
  if (t.at) tip.push("first seen " + clock(t.at));
  return {
    who: t.who === "fan" ? "fan" : "her", text: t.text, time: t.time, date: t.date, sender: t.sender,
    price: t.price, paid: t.paid, liked: t.liked, media: !t.text, border: t.ppv_border,
    image: t.media_img ? picture(t.media_img) : "",
    reply_to: t.reply_to, tip: tip.join("\n")
  };
}

// Pictures load once each, then the chat redraws with them.
function picture(path) {
  if (PICS[path] === undefined) {
    PICS[path] = "";
    API.media(path).then(function (url) { PICS[path] = url; if (url) draw(); });
  }
  return PICS[path];
}

function chatModel(d) {
  var turns = d.turns || [], islands = (d.islands || []).slice().sort(function (a, b) { return a.first - b.first; });
  var every = turns.concat.apply(turns, islands.map(function (i) { return i.turns; }));
  var timed = every.filter(function (t) { return t.time; }).length;
  var sections = islands.map(function (isl, n) {
    return { fragment: true, messages: isl.turns.map(toMsg),
      label: "Fragment " + (n + 1) + " · read " + clock(isl.first) + " · scrolled back past a gap, not joined to the chat yet" };
  });
  // gap_before: you came back to this chat and more had happened than one
  // screen shows, so whatever came in between was never on screen.
  var part = [], head = islands.length ? "Recorded chat" : "";
  turns.forEach(function (t) {
    if (t.gap_before && part.length) {
      sections.push({ label: head, messages: part });
      head = "";
      part = [];
      sections.push({ gap: true, label: "··· not seen: messages came in while you were away · back at " + clock(t.at) + " ···", messages: [] });
    }
    part.push(toMsg(t));
  });
  sections.push({ label: head, messages: part });
  return {
    fan: { name: d.fan, status: "Recorded " + clock(d.first_seen) + " – " + clock(d.last_seen) },
    sub: "read " + d.reads + "× · " + (every.length ? Math.round(100 * timed / every.length) : 0) + "% timed" +
      ((d.names || []).length > 1 ? " · " + d.names.length + " spellings" : ""),
    sections: sections, readonly: true, placeholder: "Recorded chat · read only"
  };
}

function panelModel(d) {
  var panel = d.panel || {}, ins = panel.insights;
  var extra = [];
  if (SRC === "fans") {
    // Fan files: identity from the name modal; the panel is ignored live (decision 32).
    if (d.card) extra.push({ title: "Lore card" + (d.tier ? " · " + d.tier : ""), lines: [d.card.replace(/^# .*/, "").trim()],
      note: "From the last __lore run. Run it again to refresh." });
    else extra.push({ title: "Lore card", lines: ["None yet: open him in a spare window and type __lore."] });
    extra.push({ title: "@" + (d.handle || "?"), lines: (d.names || []), note: "Names this handle was read under." });
    extra.push({ title: "Tags", lines: d.tags && d.tags.length ? d.tags : ["(none read yet: open his name modal once)"] });
    if (d.notes) extra.push({ title: "Notes", lines: [d.notes] });
    return { tab: PTAB, fields: d.fields || {}, empty: "Spend is read by __lore (the live recorder ignores the panel).",
      at: d.insights && d.insights.at ? "Panel as read by __lore at " + clock(d.insights.at) : "", raw: { sales: [], notes: [] }, extra: extra };
  }
  var log = (d.panel_log || []).filter(function (e) { return e.tab === "insights"; });
  var tl = [], last = null;
  log.forEach(function (e) {
    var fs = e.fields || {}, key = (fs["Total spend"] || "") + "|" + (fs["Last spend"] || "");
    if (key === last) return;
    var up = last !== null && last.split("|")[0] !== (fs["Total spend"] || "");
    tl.push([clock(e.at), (fs["Total spend"] || "?") + " · last " + (fs["Last spend"] || "?"), up]);
    last = key;
  });
  extra.push({ title: "Spend during the shift", timeline: tl,
    note: !tl.length ? "No panel reads." : tl.length === 1 ? "No change while he was worked." : "Green = his total went up." });
  if ((d.names || []).length > 1) extra.push({ title: "Read as", lines: d.names, note: "Spellings folded into this fan by Rebuild." });
  function lines(tab) {
    var p = panel[tab]; if (!p) return [];
    return (p.rows || []).map(function (r) { return r[1].map(function (q) { return q[2]; }).join("   "); });
  }
  return {
    tab: PTAB, fields: ins ? ins.fields : {}, empty: "The fan panel was never read for this fan.",
    at: ins ? "Panel as read at " + clock(ins.at) + " — OCR, check it against Infloww." : "",
    raw: { sales: lines("sales"), notes: lines("notes").concat(lines("?")) }, extra: extra
  };
}

function model() {
  var accs = accounts();
  if (!ACC || !accs.some(function (a) { return a.id === ACC; })) ACC = accs.length ? accs[0].id : null;
  var mine = FANS.filter(function (f) { return f.account === ACC; });
  var rows = visible();
  var msgs = 0, ppv = 0, paid = 0;
  mine.forEach(function (f) { msgs += f.messages; ppv += f.ppv; paid += f.paid; });
  var sel = CHAT && CHAT.account === ACC ? CHAT : null;
  return {
    accounts: accs, account: ACC, mark: TEMP ? "ONE-TIME VIEW" : SRC === "fans" ? "FAN FILES" : "SHIFT VIEWER",
    tabs: [{ id: "home", name: "Home", home: true }].concat(sel ? [{ id: "fan", name: sel.fan }] : []),
    tab: "home", title: ACC || "Shift log", herName: ACC || "S",
    banner: { text: "Recorded " + mine.length + " fans · " + msgs.toLocaleString() + " messages · " + ppv + " PPVs (" + paid + " paid)",
      sub: STATUS || (RAW.toLocaleString() + " raw reads" +
        (PENDING ? " · " + PENDING + " fan(s) waiting for their @handle (click his name in Infloww)" : "") +
        " · live, refreshes every " + POLL_MS / 1000 + "s"),
      actions: (TEMP ? [] : [{ id: "source", label: SRC === "fans" ? "Source: fan files" : "Source: shift log",
                  title: "Switch between the new fan files (by @handle) and the old shift log." }]).concat([
                { id: "reload", label: "Reload" },
                { id: "rebuild", label: "Rebuild", title: "Replay every raw read and fold name spellings into one fan. After a shift, not during one." }]) },
    filters: [
      { id: "all", label: "All" },
      { id: "warn", label: "Warnings", count: mine.filter(function (f) { return warnings(f).length; }).length },
      { id: "ppv", label: "PPVs", count: mine.filter(function (f) { return f.ppv; }).length },
      { id: "paid", label: "Paid", count: mine.filter(function (f) { return f.paid; }).length }
    ],
    filter: FILTER, sort: SORTS[SORT], searching: SEARCH !== null, search: SEARCH || "",
    listEmpty: SEARCH ? "No fans match." : "Nothing recorded for this account yet.",
    list: rows.map(function (f) {
      var w = warnings(f);
      return { id: f.id, name: f.fan, spend: f.spend, time: clock(f.last_seen),
        preview: f.preview, unread: false, expired: /^expired/i.test(f.status || ""),
        marks: (f.tier ? [f.tier] : []).concat(w).slice(0, 2), title: (f.tier ? f.tier + " " : "") + w.join("\n") };
    }),
    sel: sel ? SEL : null,
    chat: sel ? chatModel(sel) : null,
    panel: sel ? panelModel(sel) : null
  };
}

function draw() { IC.render(document.getElementById("root"), model(), HOOKS); }

var HOOKS = {
  account: function (id) { ACC = id; SEL = null; CHAT = null; draw(); },
  tab: function (id) { if (id === "home") draw(); },
  filter: function (id) { FILTER = id; draw(); },
  sort: function () { SORT = (SORT + 1) % SORTS.length; draw(); },
  search: function (q) { SEARCH = q; draw(); },
  select: function (id) { openFan(id); },
  panelTab: function (t) { PTAB = t; draw(); },
  banner: function (id) {
    if (id === "reload") { SIG = ""; poll(); return; }
    if (id === "source") {
      API.source(SRC === "fans" ? "shift" : "fans").then(function (s) {
        SRC = s; SEL = null; CHAT = null; ACC = null; SIG = ""; poll();
      });
      return;
    }
    if (id === "rebuild") {
      if (!window.confirm("Rebuild every fan file from the raw reads?\n\nRun it after a shift, not while the chat reader is recording.")) return;
      STATUS = "Rebuilding… about a minute"; draw();
      API.rebuild().then(function (r) {
        STATUS = r.ok ? "" : "Rebuild failed: " + r.error;
        SIG = ""; poll();
      });
    }
  }
};

function openFan(id) {
  SEL = id;
  API.chat(id).then(function (d) { CHAT = d.error ? null : d; draw(); });
}

// Poll: redraw only when something was recorded since the last look.
function poll() {
  API.fans().then(function (res) {
    var sig = res.source + ":" + res.raw_reads + ":" + res.fans.length + ":" + (res.pending || 0);
    if (sig === SIG) return;
    SIG = sig; FANS = res.fans; RAW = res.raw_reads; PENDING = res.pending || 0; SRC = res.source || SRC;
    TEMP = !!res.temp;
    if (SEL) {
      API.chat(SEL).then(function (d) { CHAT = d.error ? null : d; draw(); });
    } else draw();
  });
}

function boot() {
  if (API) return;
  API = window.pywebview.api;
  poll();
  setInterval(poll, POLL_MS);
}

window.addEventListener("pywebviewready", boot);
if (window.pywebview && window.pywebview.api) boot();
