/*
  Infloww clone — the renderer. One function, IC.render(root, model, hooks),
  draws the whole Messages window from plain data. Hosts own the data and the
  behaviour; this file owns only how Infloww LOOKS. Every text that came from a
  chat goes in as textContent, never as HTML.

  model = {
    accounts: [{id, name, badge}],  account: id,            // account strip
    tabs:     [{id, name, home}],   tab: id,                // fan tab strip
    title:    "SOF",                                        // left column heading
    banner:   {text, sub, actions: [{id, label}]} | null,   // the mass-send banner slot
    filters:  [{id, label, count}], filter: id,             // the pills
    sort:     "Newest first",                               // the sort label (click cycles)
    search:   "",                                           // shown when the search icon is used
    list:     [{id, name, handle, spend, preview, time, unread, expired, online, marks: [..], warn}],
    sel:      id,
    chat: {
      fan: {name, handle, status},  sub: "",                // header; sub = small right-hand note
      sections: [{label, fragment, messages: [msg]}],
      readonly: true, placeholder: "",
    } | null,
    panel: { tab: "insights"|"sales"|"notes", fields: {...}, at: "", raw: {sales: [], notes: []},
             extra: [{title, timeline: [[time, text, up]], lines: [], note}] } | null,
  }
  msg = {who: "fan"|"her", text, time, date, sender, price, paid, liked, media, border,
         reply_to, tip}            // media: true for a photo/video; border: unopened|opened
  hooks = {account(id), tab(id), filter(id), select(id), sort(), search(text), banner(id), panelTab(tab),
           message(ids), send(), panelAction(id), win("minimize"|"maximize"|"close")}
  Also: model.framed (1px window border), model.windowControls, row.unread (dot),
  msg.ids (clickable), msg.ai / msg.ann (footer marks), msg.mediaLabel, msg.image (picture URL),
  chat.typingHer (plain text, never a bubble), chat.fan.typing, chat.readonly=false
  (a live composer; IC.input(root) gives the textarea, which survives redraws),
  panel.action {id, label} (a button in the panel title).
*/
var IC = (function () {
  "use strict";

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined && text !== null && text !== "") e.textContent = text;
    return e;
  }

  function svg(path, size, stroke) {
    var ns = "http://www.w3.org/2000/svg";
    var s = document.createElementNS(ns, "svg");
    s.setAttribute("width", size || 18); s.setAttribute("height", size || 18);
    s.setAttribute("viewBox", "0 0 20 20"); s.setAttribute("fill", "none");
    s.setAttribute("stroke", "currentColor"); s.setAttribute("stroke-width", stroke || "1.6");
    s.setAttribute("stroke-linecap", "round"); s.setAttribute("stroke-linejoin", "round");
    path.split("|").forEach(function (d) {
      var p = document.createElementNS(ns, "path"); p.setAttribute("d", d); s.appendChild(p);
    });
    return s;
  }

  var ICON = {
    compose: "M4 15l1-4 7-7 3 3-7 7z|M3 18h14", search: "M9 15a6 6 0 1 0 0-12 6 6 0 0 0 0 12z|M14 14l4 4",
    plus: "M10 3v14|M3 10h14", back: "M17 10H4|M9 4l-6 6 6 6", pencil: "M3 17l1-4 9-9 3 3-9 9z",
    star: "M10 2.5l2.3 4.7 5.2.8-3.8 3.6.9 5.1L10 14.3l-4.6 2.4.9-5.1L2.5 8l5.2-.8z",
    bell: "M5 14V9a5 5 0 0 1 10 0v5l1.5 1.5h-13z|M8 17.5a2 2 0 0 0 4 0",
    note: "M4 3h12v14H4z|M7 7h6|M7 10h6|M7 13h4", pin: "M12 2l6 6-3 1-3 3 1 4-1 1-4-4-4 4|M8 9l3 3",
    gallery: "M3 4h14v12H3z|M3 13l4-4 4 4 2-2 4 4", find: "M9 15a6 6 0 1 0 0-12 6 6 0 0 0 0 12z|M14 14l4 4",
    newtab: "M11 3h6v6|M17 3l-8 8|M15 12v5H3V5h5", refresh: "M16 10a6 6 0 1 1-2-4.5|M16 3v4h-4",
    kebab: "M10 4h.01|M10 10h.01|M10 16h.01", inbox: "M3 5h14v10H3z|M3 11h4l1 2h4l1-2h4",
    sort: "M4 6h12|M4 10h9|M4 14h6", user: "M10 10a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7z|M3 18c1-4 4-5 7-5s6 1 7 5",
    notif: "M5 14V9a5 5 0 0 1 10 0v5l1.5 1.5h-13z", grid: "M3 3h6v6H3z|M11 3h6v6h-6z|M3 11h6v6H3z|M11 11h6v6h-6z",
    smile: "M10 18a8 8 0 1 0 0-16 8 8 0 0 0 0 16z|M7 12c1.5 2 4.5 2 6 0|M7.5 8h.01|M12.5 8h.01",
    gear: "M10 13a3 3 0 1 0 0-6 3 3 0 0 0 0 6z|M10 2v2|M10 16v2|M2 10h2|M16 10h2|M4.3 4.3l1.4 1.4|M14.3 14.3l1.4 1.4",
    alarm: "M10 17a6 6 0 1 0 0-12 6 6 0 0 0 0 12z|M10 8v3l2 1|M4 3L2 5|M16 3l2 2",
    comment: "M3 4h14v9H8l-4 3v-3H3z", heart: "M10 16l-6-6a3.5 3.5 0 0 1 6-4 3.5 3.5 0 0 1 6 4z",
    translate: "M3 5h8|M7 3v2|M5 5c1 3 3 5 6 6|M9 5c-1 3-3 5-6 6|M11 17l3-8 3 8|M12 14h4",
    chev: "M5 12l5-5 5 5", info: "M10 18a8 8 0 1 0 0-16 8 8 0 0 0 0 16z|M10 9v5|M10 6h.01",
    cal: "M3 5h14v12H3z|M3 9h14|M7 3v4|M13 3v4", loc: "M10 18s6-5.5 6-10a6 6 0 0 0-12 0c0 4.5 6 10 6 10z|M10 10a2 2 0 1 0 0-4 2 2 0 0 0 0 4z",
    down: "M6 8l4 4 4-4", eye: "M2 10s3-6 8-6 8 6 8 6-3 6-8 6-8-6-8-6z|M10 12a2 2 0 1 0 0-4 2 2 0 0 0 0 4z",
    tag: "M3 3h7l7 7-7 7-7-7z|M7 7h.01", doc: "M5 2h7l4 4v12H5z|M8 9h5|M8 12h5|M8 15h3"
  };

  function initials(name) {
    var w = String(name || "?").replace(/[^\p{L}\p{N} ]/gu, " ").trim().split(/\s+/);
    var s = (w[0] || "?").charAt(0) + (w.length > 1 ? (w[1] || "").charAt(0) : (w[0] || "").charAt(1));
    return s.charAt(0).toUpperCase() + s.charAt(1).toLowerCase();
  }

  function call(hooks, name) {
    var args = Array.prototype.slice.call(arguments, 2);
    if (hooks && typeof hooks[name] === "function") hooks[name].apply(null, args);
  }

  /* ── strips ─────────────────────────────────────────────────────────── */
  function accountStrip(m, hooks) {
    var s = el("div", "ic-mstrip pywebview-drag-region");
    (m.accounts || []).forEach(function (a) {
      var t = el("div", "ic-acct" + (a.id === m.account ? " on" : ""));
      t.appendChild(el("div", "ico"));
      var c = el("div");
      c.appendChild(el("div", "nm", a.name));
      if (a.badge) c.appendChild(el("span", "badge num", String(a.badge)));
      t.appendChild(c);
      t.appendChild(el("div", "x", "×"));
      t.addEventListener("click", function () { call(hooks, "account", a.id); });
      s.appendChild(t);
    });
    s.appendChild(el("div", "ic-plus", "+"));
    if (m.mark) s.appendChild(el("div", "ic-mark", m.mark));
    if (m.windowControls) {                      // a frameless host's own buttons
      var wc = el("div", "ic-wctl");
      [["minimize", "M4 10h12", ""], ["maximize", "M4 4h12v12H4z", ""], ["close", "M5 5l10 10|M15 5L5 15", "close"]].forEach(function (b) {
        var x = el("button", b[2]); x.setAttribute("aria-label", b[0]); x.appendChild(svg(b[1], 11, "1.2"));
        x.addEventListener("click", function () { call(hooks, "win", b[0]); });
        wc.appendChild(x);
      });
      s.appendChild(wc);
    }
    return s;
  }

  function tabStrip(m, hooks) {
    var s = el("div", "ic-fstrip pywebview-drag-region");
    (m.tabs || [{ id: "home", name: "Home", home: true }]).forEach(function (t) {
      var b = el("div", "ic-ftab" + ((t.id === (m.tab || "home")) ? " on" : ""));
      if (t.home) b.appendChild(svg(ICON.grid, 13));
      b.appendChild(el("span", null, t.name));
      if (!t.home) b.appendChild(el("span", "x", "×"));
      b.addEventListener("click", function () { call(hooks, "tab", t.id); });
      s.appendChild(b);
    });
    return s;
  }

  /* ── left column ────────────────────────────────────────────────────── */
  function leftColumn(m, hooks) {
    var L = el("div", "ic-left");
    var head = el("div", "ic-lhead");
    if (m.searching) {
      var q = el("input", "ic-search"); q.type = "search"; q.placeholder = "Search fans"; q.value = m.search || "";
      q.addEventListener("input", function () { call(hooks, "search", q.value); });
      q.addEventListener("keydown", function (e) { if (e.key === "Escape") call(hooks, "search", null); });
      head.appendChild(q);
      setTimeout(function () { q.focus(); q.setSelectionRange(q.value.length, q.value.length); }, 0);
    } else {
      head.appendChild(el("div", "acc", m.title || ""));
    }
    var icons = el("div", "icons");
    var bc = el("button"); bc.appendChild(svg(ICON.compose, 20)); icons.appendChild(bc);
    var bs = el("button"); bs.title = "Search"; bs.appendChild(svg(ICON.search, 20));
    bs.addEventListener("click", function () { call(hooks, "search", m.searching ? null : (m.search || "")); });
    icons.appendChild(bs);
    var bp = el("button"); bp.appendChild(svg(ICON.plus, 20)); icons.appendChild(bp);
    head.appendChild(icons);
    L.appendChild(head);

    if (m.banner) {
      var b = el("div", "ic-banner");
      b.appendChild(el("div", "t", m.banner.text));
      var acts = el("div", "acts");
      (m.banner.actions || []).forEach(function (a) {
        var x = el("button", null, a.label); if (a.title) x.title = a.title;
        x.addEventListener("click", function () { call(hooks, "banner", a.id); });
        acts.appendChild(x);
      });
      b.appendChild(acts);
      if (m.banner.sub) b.appendChild(el("div", "s", m.banner.sub));
      L.appendChild(b);
    }
    var lb = el("div", "ic-lbtns");
    var on = el("div", "ic-lbtn online"); on.appendChild(svg(ICON.user, 15)); on.appendChild(el("span", null, "Online Fans"));
    var nt = el("div", "ic-lbtn notif"); nt.appendChild(svg(ICON.notif, 15)); nt.appendChild(el("span", null, "Notifications"));
    lb.appendChild(on); lb.appendChild(nt); L.appendChild(lb);

    var so = el("div", "ic-lsort");
    var ib = el("div", "ic-inbox"); ib.appendChild(svg(ICON.inbox, 16)); ib.appendChild(el("span", null, "All inboxes"));
    so.appendChild(ib);
    var nw = el("button", "ic-newest", m.sort || "Newest first"); nw.title = "Change the order";
    nw.addEventListener("click", function () { call(hooks, "sort"); });
    so.appendChild(nw);
    var i2 = el("div", "ico2"); i2.appendChild(svg(ICON.sort, 18)); i2.appendChild(svg(ICON.refresh, 16));
    so.appendChild(i2);
    L.appendChild(so);

    var pills = el("div", "ic-pills");
    (m.filters || []).forEach(function (f) {
      var p = el("button", "ic-pill" + (f.id === m.filter ? " on" : ""), f.label);
      if (f.count) p.appendChild(el("span", "cnt num", f.count > 99 ? "99+" : String(f.count)));
      if (f.title) p.title = f.title;
      p.addEventListener("click", function () { call(hooks, "filter", f.id); });
      pills.appendChild(p);
    });
    L.appendChild(pills);

    var rows = el("div", "ic-rows");
    if (!(m.list || []).length) rows.appendChild(el("div", "ic-empty", m.listEmpty || "No chats"));
    (m.list || []).forEach(function (r) {
      var row = el("div", "ic-row" + (r.id === m.sel ? " sel" : "") + (r.unread ? " unread" : ""));
      var av = el("div", "av" + (r.expired ? " expired" : ""), r.expired ? "✕" : initials(r.name));
      row.appendChild(av);
      if (r.online) row.appendChild(el("div", "dotOn"));
      if (r.spend) row.appendChild(el("div", "spend num", r.spend));
      var nm = el("div", "nm", r.name + " ");
      if (r.handle) nm.appendChild(el("span", null, r.handle));
      row.appendChild(nm);
      var mk = el("div", "marks");
      if (r.expired) mk.appendChild(el("span", null, "✕"));
      (r.marks || []).forEach(function (x) { mk.appendChild(el("span", "w", x)); });
      row.appendChild(mk);
      row.appendChild(el("div", "pv", r.preview || ""));
      row.appendChild(el("div", "tm", r.time || ""));
      if (r.unread) row.appendChild(el("div", "dot"));
      row.appendChild(el("div", "sep"));
      if (r.title) row.title = r.title;
      row.addEventListener("click", function () { call(hooks, "select", r.id); });
      rows.appendChild(row);
    });
    L.appendChild(rows);
    return L;
  }

  /* ── centre column ──────────────────────────────────────────────────── */
  function header(c) {
    var h = el("div", "ic-chead");
    var bk = el("div", "back"); bk.appendChild(svg(ICON.back, 18, "1.8")); h.appendChild(bk);
    var fn = el("div", "fname"); fn.appendChild(el("b", null, c ? c.fan.name : "—"));
    var pc = el("span"); pc.style.color = "#9a9a9a"; pc.appendChild(svg(ICON.pencil, 14)); fn.appendChild(pc);
    h.appendChild(fn);
    var st = el("div", "stat");
    if (c && c.fan.typing) st.classList.add("typing");
    st.appendChild(el("i")); st.appendChild(el("span", null, (c && c.fan.status) || "Available now"));
    [ICON.star, ICON.bell, ICON.note, ICON.pin].forEach(function (p) {
      st.appendChild(el("span", "sp")); var t = el("span", "ti"); t.appendChild(svg(p, 13)); st.appendChild(t);
    });
    [["Gallery", ICON.gallery], ["Find", ICON.find]].forEach(function (g) {
      st.appendChild(el("span", "sp")); var t = el("span", "ti"); t.appendChild(svg(g[1], 12)); t.appendChild(el("span", null, g[0])); st.appendChild(t);
    });
    h.appendChild(st);
    var nt = el("div", "newtab"); nt.appendChild(svg(ICON.newtab, 13)); nt.appendChild(el("span", null, "Open in new tab"));
    h.appendChild(nt);
    var ri = el("div", "ricons"); ri.appendChild(svg(ICON.refresh, 17)); ri.appendChild(svg(ICON.kebab, 17, "2.6"));
    h.appendChild(ri);
    if (c && c.sub) h.appendChild(el("div", "sub2", c.sub));
    return h;
  }

  function footer(msg) {
    var f = el("div", "ic-meta");
    if (msg.price) {
      var st = msg.paid === true ? "paid" : msg.paid === false ? "" : "unk";
      f.appendChild(el("span", "pill num " + st, "$" + msg.price + (msg.paid === true ? " paid" : msg.paid === false ? " not paid" : "")));
    }
    if (msg.liked) f.appendChild(el("span", "heart"));
    if (msg.time) f.appendChild(el("span", "num", (msg.date ? msg.date + " " : "") + msg.time));
    else if (msg.showNoTime) f.appendChild(el("span", "no", "no time"));
    if (msg.who === "fan" && msg.ai) f.appendChild(el("span", "ai", "AI"));
    if (msg.who !== "fan" && (msg.time || msg.sender)) {
      // An icon, as in Infloww (text "✓✓" OCRs as "W/" and lands in the sender).
      var tk = el("span", "tick"); tk.appendChild(svg("M2 10.5l3.5 3.5 6-7|M8.5 13l1 1 6-7", 15, "1.5")); f.appendChild(tk);
      if (msg.sender) f.appendChild(el("span", "by", msg.sender));
    }
    if (msg.ann) f.appendChild(el("span", "ann", "· " + msg.ann));
    return f;
  }

  function messageEl(msg, fanName, herInitial, first, last, hooks) {
    var fan = msg.who === "fan";
    var m = el("div", "ic-msg " + (fan ? "fan" : "her") + (first ? " first" : "") + (last ? " end" : ""));
    if (msg.tip) m.title = msg.tip;
    if (msg.ids) {
      m.setAttribute("data-ids", msg.ids);
      m.addEventListener("click", function () {
        if (!String(window.getSelection())) call(hooks, "message", msg.ids);   // selecting text is not a click
      });
    }
    if (fan) m.appendChild(el("div", "ic-fav", initials(fanName)));
    var col = el("div", "col");
    var line = el("div", "ic-line");
    var body;
    if (msg.media && !msg.text) {
      body = el("div", "ic-media" + (msg.border ? " " + msg.border : ""));
      if (msg.image) {                         // a real picture (msg.image = a URL)
        body.classList.add("pic");
        var im = document.createElement("img");
        im.className = "img"; im.src = msg.image; im.alt = msg.mediaLabel || "sent media";
        body.appendChild(im);
      } else {
        body.appendChild(el("div", "img", msg.mediaLabel || (msg.border ? "PPV · " + (msg.border === "opened" ? "opened" : "not opened") : "photo / video")));
      }
    } else {
      body = el("div", "ic-bub");
      if (msg.reply_to) body.appendChild(el("div", "ic-quote", msg.reply_to));
      body.appendChild(document.createTextNode(msg.text || "[media]"));
    }
    var ico = el("div", "ic-hico");
    if (fan) {
      [ICON.pin, ICON.comment, ICON.heart, ICON.translate].forEach(function (p) { ico.appendChild(svg(p, 13)); });
      line.appendChild(body); line.appendChild(ico);
    } else {
      ico.appendChild(svg(ICON.translate, 13));
      line.appendChild(ico); line.appendChild(body);
      // Contract: (x0 - 12, y1 - 19). A media message with a caption below has
      // none of its own (the caption owns it); standalone media does.
      if (!(msg.media && !msg.text && msg.captioned)) body.appendChild(el("span", "ic-kebab"));
    }
    col.appendChild(line);
    if (last || msg.price || msg.liked) col.appendChild(footer(msg));
    m.appendChild(col);
    if (!fan) m.appendChild(el("div", "ic-hav", herInitial));
    return m;
  }

  function pane(c, herInitial, hooks) {
    var p = el("div", "ic-pane");
    if (!c) { p.appendChild(el("div", "ic-empty", "Pick a chat on the left.")); return p; }
    var any = false;
    (c.sections || []).forEach(function (s) {
      if (s.label) {
        var lab = el("div", "ic-sec" + (s.fragment ? " frag" : s.gap ? " gap" : ""));
        lab.appendChild(el("span", null, s.label)); p.appendChild(lab);
      }
      var box = s.fragment ? el("div", "ic-frag") : p;
      var ms = s.messages || [];
      ms.forEach(function (msg, i) {
        var prev = ms[i - 1], next = ms[i + 1];
        var first = !prev || prev.who !== msg.who;
        // A footer closes a run: Infloww shows it under the last message the
        // same side sent in that minute. A message with its own time ends one.
        var last = !next || next.who !== msg.who || !!msg.time;
        if (msg.media && !msg.text && next && next.ids && next.ids === msg.ids && next.who === msg.who) { msg.captioned = true; last = false; }
        box.appendChild(messageEl(msg, c.fan.name, herInitial, first, last, hooks));
        any = true;
      });
      if (s.fragment) p.appendChild(box);
    });
    if (!any) p.appendChild(el("div", "ic-empty", c.empty || "No messages."));
    if (c.typingHer) p.appendChild(el("div", "ic-typing", c.typingHer));
    return p;
  }

  var EMOJI = ["❤️", "🥰", "😍", "😘", "😈", "🥵", "💦", "😏", "🙈", "😜", "😇", "🍑", "🍒", "💋", "🔥", "👀", "💕", "😋", "🤭", "😳", "🫦", "💖", "😚", "👅", "⭐"];

  function composer(c, hooks) {
    var w = el("div", "ic-composer");
    var row = el("div", "ic-crow");
    var list = el("div", "elist");
    list.appendChild(svg(ICON.smile, 16)); list.appendChild(svg(ICON.gear, 16));
    EMOJI.forEach(function (e) { list.appendChild(el("span", "e", e)); });
    row.appendChild(list);
    var sc = el("div", "scripts"); sc.appendChild(svg(ICON.comment, 15)); sc.appendChild(el("span", null, "Scripts"));
    row.appendChild(sc);
    var al = el("div", "alarm"); al.appendChild(svg(ICON.alarm, 18)); row.appendChild(al);
    w.appendChild(row);
    w.appendChild(el("div", "ic-cline"));
    var box = el("div", "ic-cbox");
    var t = el("textarea", "ic-input");
    t.placeholder = (c && c.placeholder) || 'Press "/" + keyword to quickly search scripts';
    t.disabled = !c || c.readonly !== false;
    box.appendChild(t);
    var tools = el("div", "ic-ctools");
    [ICON.gallery, ICON.doc, ICON.cal, ICON.tag, ICON.user, ICON.note, ICON.translate].forEach(function (p) { tools.appendChild(svg(p, 17)); });
    box.appendChild(tools);
    var btns = el("div", "ic-cbtns");
    var cl = el("button", "ic-clear", "Clear"); var sd = el("button", "ic-send", "Send");
    cl.disabled = sd.disabled = t.disabled;
    cl.addEventListener("click", function () { var i = cl.closest(".ic").querySelector(".ic-input"); i.value = ""; i.focus(); });
    sd.addEventListener("click", function () { call(hooks, "send"); });
    btns.appendChild(cl); btns.appendChild(sd); box.appendChild(btns);
    w.appendChild(box);
    return w;
  }

  /* ── right column ───────────────────────────────────────────────────── */
  function card(title) {
    var c = el("div", "ic-card");
    var h = el("h4");
    h.appendChild(el("span", "grip", "⠿")); h.appendChild(el("span", null, title));
    var ch = el("span", "chev"); ch.appendChild(svg(ICON.chev, 14)); h.appendChild(ch);
    c.appendChild(h);
    return c;
  }

  function kv(c, k, v, sub, info) {
    var r = el("div", "kv");
    var kk = el("span", null, k);
    if (info) { kk.style.display = "inline-flex"; kk.style.gap = "4px"; kk.appendChild(svg(ICON.info, 13)); }
    r.appendChild(kk);
    if (v instanceof Node) { r.appendChild(v); }
    else {
      var b = el("b", "num", v || "—");
      if (sub) b.appendChild(el("span", "sub", sub));
      r.appendChild(b);
    }
    c.appendChild(r);
  }

  // "$15 Total - Avg" -> ["$15 Total", "- Avg"]; "1y ago PPV | $15" -> ["1y ago", "PPV | $15"]
  function split2(v, re) {
    var m = String(v || "").match(re);
    return m ? [m[1].trim(), m[2].trim()] : [v || "—", ""];
  }

  function insights(p) {
    var f = p.fields || {};
    var out = [];
    var sb = card("Spending behavior");
    var two = el("div", "two");
    var a = el("div"); a.appendChild(el("div", "k", "Total spend")); a.appendChild(el("div", "v num", f["Total spend"] || "—"));
    var ls = split2(f["Last spend"], /^(.*?\bago)\s*(.*)$/i);
    var lsm = String(ls[0]).match(/^(\S+)\s*(ago)$/i);
    var b = el("div"); b.appendChild(el("div", "k", "Last spend"));
    var bv = el("div", "v num", lsm ? lsm[1] + " " : ls[0]);
    if (lsm) bv.appendChild(el("small", null, "ago"));
    b.appendChild(bv); if (ls[1]) b.appendChild(el("div", "s num", ls[1]));
    two.appendChild(a); two.appendChild(b); sb.appendChild(two);
    var pv = split2(f["PPV"], /^(.*?Total)\s*(.*)$/i); kv(sb, "PPV", pv[0], pv[1]);
    var tp = split2(f["Tip"], /^(.*?Total)\s*(.*)$/i); kv(sb, "Tip", tp[0], tp[1]);
    var hs = split2(f["Highest spend"], /^(\$[\d.,]+k?)\s*(.*)$/i); kv(sb, "Highest spend", hs[0], hs[1]);
    out.push(sb);

    var om = card("Organization metrics");
    kv(om, "Spending power", f["Spending power"], "", true);
    var cr = f["Chargeback risk"];
    if (cr) {
      var cls = /high/i.test(cr) ? " bad" : /med/i.test(cr) ? " warn" : /low/i.test(cr) ? "" : " warn";
      var bd = el("span", "ic-badge" + cls, "⚠ " + cr); kv(om, "Chargeback risk", bd);
    } else kv(om, "Chargeback risk", "—");
    out.push(om);

    var su = card("Subscription");
    ["Status", "Cost", "Duration", "Auto-renewal"].forEach(function (k) { kv(su, k, f[k]); });
    out.push(su);

    var pr = card("Profile");
    kv(pr, "Nickname", f["Nickname"], "", true);
    var bd2 = el("span", "ic-field"); bd2.appendChild(el("span", null, f["Birthday"] || "Select date")); bd2.appendChild(svg(ICON.cal, 12));
    kv(pr, "Birthday", bd2);
    kv(pr, "Local time", f["Local time"]);
    var so = el("span", "ic-field"); so.appendChild(el("span", null, f["Source"] || "Unknown")); so.appendChild(svg(ICON.down, 12));
    kv(pr, "Source", so);
    if (f["Salary"]) kv(pr, "Salary", f["Salary"]);
    out.push(pr);
    return out;
  }

  function extraCard(x) {
    var c = el("div", "ic-card extra");
    var h = el("h4"); h.appendChild(el("span", null, x.title)); c.appendChild(h);
    if (x.timeline) {
      var tl = el("div", "tl");
      x.timeline.forEach(function (r) {
        var d = el("div"); d.appendChild(el("span", "t", r[0])); d.appendChild(el("span", r[2] ? "up num" : "num", r[1])); tl.appendChild(d);
      });
      c.appendChild(tl);
    }
    if (x.lines) c.appendChild(el("div", "raw", x.lines.join("\n")));
    if (x.note) c.appendChild(el("div", "note", x.note));
    return c;
  }

  function rightColumn(p, hooks) {
    var R = el("div", "ic-right");
    var t = el("div", "ic-rtitle");
    t.appendChild(el("span", null, p && p.tab === "sales" ? "Sales" : p && p.tab === "notes" ? "Notes" : "Fan insights"));
    if (p && p.action) {
      var ab = el("button", null, p.action.label);
      ab.addEventListener("click", function () { call(hooks, "panelAction", p.action.id); });
      t.appendChild(ab);
    }
    R.appendChild(t);
    var body = el("div", "ic-rbody");
    if (!p) body.appendChild(el("div", "ic-empty", "No fan picked."));
    else if ((p.tab || "insights") === "insights") {
      if (p.fields && Object.keys(p.fields).length) insights(p).forEach(function (c) { body.appendChild(c); });
      else body.appendChild(el("div", "ic-empty", p.empty || "The fan panel was not read."));
    } else {
      var lines = (p.raw || {})[p.tab] || [];
      var c = card(p.tab === "sales" ? "Sales" : "Notes");
      c.appendChild(el("div", "raw", lines.length ? lines.join("\n") : "Not read yet."));
      body.appendChild(c);
    }
    if (p && p.at) body.appendChild(el("div", "ic-card extra")).appendChild(el("div", "note", p.at));
    (p && p.extra || []).forEach(function (x) { body.appendChild(extraCard(x)); });
    R.appendChild(body);
    var nav = el("div", "ic-rnav");
    [["insights", "Insights", ICON.eye], ["sales", "Sales", ICON.tag], ["notes", "Notes", ICON.doc]].forEach(function (n) {
      var b = el("button", (p && (p.tab || "insights") === n[0]) ? "on" : null);
      b.appendChild(svg(n[2], 19)); b.appendChild(el("span", null, n[1]));
      b.addEventListener("click", function () { call(hooks, "panelTab", n[0]); });
      nav.appendChild(b);
    });
    R.appendChild(nav);
    return R;
  }

  /* ── the window ─────────────────────────────────────────────────────── */
  var state = { chatKey: null, scroll: {} };

  function render(root, m, hooks) {
    var oldPane = root.querySelector(".ic-pane");
    var key = m.chat ? m.sel : null;
    if (oldPane && state.chatKey) {
      state.scroll[state.chatKey] = {
        top: oldPane.scrollTop,
        atBottom: oldPane.scrollHeight - oldPane.scrollTop - oldPane.clientHeight < 40
      };
    }
    var oldRows = root.querySelector(".ic-rows");
    var rowsTop = oldRows ? oldRows.scrollTop : 0;

    // The typing box survives redraws: same node, so what you typed, the
    // cursor and focus all stay put while the host re-renders on every change.
    var oldInput = root.querySelector(".ic-input");
    var hadFocus = oldInput && document.activeElement === oldInput;
    var w = el("div", "ic" + (m.framed ? " framed" : ""));
    w.appendChild(accountStrip(m, hooks));
    w.appendChild(tabStrip(m, hooks));
    var ct = el("div", "ic-content");
    ct.appendChild(leftColumn(m, hooks));
    ct.appendChild(el("div", "ic-vdiv"));
    var cen = el("div", "ic-centre");
    cen.appendChild(header(m.chat));
    cen.appendChild(el("div", "ic-hdiv"));
    var herIni = initials(m.herName || m.title || "S").charAt(0);
    var pn = pane(m.chat, herIni, hooks);
    cen.appendChild(pn);
    cen.appendChild(el("div", "ic-hdiv"));
    cen.appendChild(composer(m.chat, hooks));
    ct.appendChild(cen);
    ct.appendChild(el("div", "ic-vdiv"));
    ct.appendChild(rightColumn(m.panel, hooks));
    w.appendChild(ct);
    var newInput = w.querySelector(".ic-input");
    if (oldInput && newInput) {
      oldInput.disabled = newInput.disabled;
      oldInput.placeholder = newInput.placeholder;
      newInput.parentNode.replaceChild(oldInput, newInput);
    }
    root.textContent = "";
    root.appendChild(w);
    if (hadFocus) oldInput.focus();

    var rows = root.querySelector(".ic-rows");
    if (rows) rows.scrollTop = rowsTop;
    // Same chat: keep where you were (or stay pinned to the bottom as new
    // messages arrive). Another chat: open at the newest, like Infloww.
    var prev = key && state.scroll[key];
    if (prev && key === state.chatKey && !prev.atBottom) pn.scrollTop = prev.top;
    else pn.scrollTop = pn.scrollHeight;
    state.chatKey = key;
  }

  function input(root) { return root.querySelector(".ic-input"); }

  return { render: render, initials: initials, input: input };
})();
