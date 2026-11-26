// TestFlow clone — the host. The Infloww window itself is drawn by the shared
// clone (tools/inflowwclone/clone.js, served at /ic/); this file turns TestFlow's
// state into its model and keeps TestFlow's own parts: the composer that types
// as whoever you play (Lab ▸ You are), the rate card and the end-of-chat review.
// As her, autoword, grammar, hotstrings and masses all work the way they do in
// Infloww, because the window title matches.
const $ = id => document.getElementById(id);
const root = $("root");
let S = null;

const BY = { ai: "AI", user: "Silly", auto: "Auto", mass: "Mass", "human-edit": "Edited" };

function spend(chat) {
  return chat.messages.filter(m => m.kind === "ppv" && m.ppv.paid)
    .reduce((a, m) => a + (parseFloat(m.ppv.price) || 0), 0);
}

// A message and the lines it was sent with (an AI reply split into texts
// shares a `reply` id). Annotations are per run, not per line.
function runOf(chat, id) {
  const ms = chat.messages;
  const i = ms.findIndex(m => m.id === id);
  if (i < 0) return [];
  const key = ms[i].reply;
  if (!key) return [ms[i]];
  return ms.filter(m => m.reply === key && m.who === ms[i].who);
}

function annText(m) {
  const a = m.ann;
  if (!a) return "";
  const bits = [];
  if (a.score) bits.push(`${a.score}/10`);
  if (a.rewrite || a.rationale || a.note) bits.push("✎");
  return bits.join(" ");
}

// TestFlow message -> clone message(s). A PPV is two: the media, then its caption.
function toMsgs(chat, m) {
  const ids = runOf(chat, m.id).map(x => x.id).join(",");
  const time = TF.time(m.ts), ann = annText(m);
  if (m.who === "fan") return [{ who: "fan", text: m.text, time, ids, ai: m.by === "ai", ann }];
  const sender = BY[m.by || "user"] || "Silly";
  if (m.kind === "ppv") {
    const p = m.ppv;
    const media = { who: "her", media: true, ids, border: p.paid ? "opened" : "unopened",
                    mediaLabel: (p.paid ? "🔓 " : "🔒 ") + (p.content || "PPV") };
    const tail = { price: p.price, paid: !!p.paid, time, sender, ann };
    return m.text ? [media, Object.assign({ who: "her", text: m.text, ids }, tail)]
                  : [Object.assign(media, tail)];
  }
  return [{ who: "her", text: m.text, time, sender, ids, ann }];
}

function model(s) {
  const chat = TF.activeChat(s);
  const chats = Object.values(s.chats).sort((a, b) => {
    const la = a.messages.length ? a.messages[a.messages.length - 1].ts : a.created;
    const lb = b.messages.length ? b.messages[b.messages.length - 1].ts : b.created;
    return lb - la;
  });
  const unread = chats.filter(c => c.unread > 0 && c.id !== s.active).length;
  const acct = s.account || "TestFlow";
  let panel = null, cm = null;
  if (chat) {
    const total = spend(chat);
    const paid = chat.messages.filter(m => m.kind === "ppv" && m.ppv.paid);
    panel = {
      tab: "insights",
      fields: {
        "Total spend": "$" + total.toFixed(2),
        "Last spend": paid.length ? TF.time(paid[paid.length - 1].ts) + " ago" : "",
        "Spending power": total > 100 ? "Top 1%" : total > 30 ? "Top 10%" : "Insufficient data",
        "Status": "Active", "Nickname": chat.fan.name,
      },
      action: !chat.ended && chat.messages.length ? { id: "end", label: "End & review" } : null,
      extra: [{ title: "TestFlow", lines: [
        "Persona: " + (chat.fan.persona || "—"),
        "Highest tier bought: " + ((s.tiers || [])[chat.tier || 0] || "nothing"),
        "Messages: " + chat.messages.length] }],
    };
    const hisTyping = s.typing === chat.id && s.role === "her";      // HIS typing; hers is in the pane
    cm = {
      fan: { name: chat.fan.name, status: hisTyping ? "typing…" : "Available now", typing: hisTyping },
      sections: [{ messages: chat.messages.flatMap(m => toMsgs(chat, m)) }],
      empty: "No messages yet.",
      readonly: !!chat.ended,
      placeholder: chat.ended ? "This chat is reviewed and closed. Start a new one in the Lab."
        : s.role === "fan" ? "Type as the fan — she replies"
        : 'You are her. Press "/" + keyword to quickly search scripts',
      // Her "typing…" is plain text, never a bubble: a #353535 fill would be
      // read by MMA's chat reader as a message from her.
      typingHer: s.typing === chat.id && s.role === "fan" ? "typing…" : "",
    };
  }
  return {
    framed: true, windowControls: true, mark: "TESTFLOW",
    accounts: [{ id: "tf", name: acct, badge: unread }], account: "tf",
    tabs: [{ id: "home", name: "Home", home: true }], tab: "home",
    title: acct.slice(0, 4), herName: acct,
    filters: [{ id: "all", label: "All" }, { id: "pinned", label: "Pinned" }, { id: "priority", label: "Priority" },
              { id: "unread", label: "Unread", count: unread }, { id: "tips", label: "With Tips" }],
    filter: "unread",
    list: chats.map(c => {
      const last = c.messages[c.messages.length - 1];
      return { id: c.id, name: c.fan.name, handle: c.fan.handle, spend: "$" + Math.round(spend(c)),
               preview: last ? (last.kind === "ppv" ? "📎 PPV" : last.text) : "New chat",
               time: last ? TF.time(last.ts) : "", unread: c.unread > 0 && c.id !== s.active, online: true };
    }),
    listEmpty: "No chats yet. Start one in the Lab.",
    sel: chat ? chat.id : null, chat: cm, panel,
  };
}

const HOOKS = {
  select: id => { pinned = ""; TF.post("/api/chat/select", { id }); },
  message: ids => { pinned = ids; rateKey = ""; render(S); },     // click any message to annotate it
  send: () => send(),
  panelAction: id => { if (id === "end") TF.post("/api/review/open", { id: S.active }); },
  // Frameless window controls (pywebview). In a plain browser these do nothing.
  win: a => {
    const w = window.pywebview && window.pywebview.api;
    if (!w) return;
    if (a === "minimize") w.minimize(); else if (a === "maximize") w.toggle_maximize(); else w.close();
  },
};

let wired = false;
function render(s) {
  S = s;
  IC.render(root, model(s), HOOKS);
  if (!wired) wireInput();
  const chat = TF.activeChat(s);
  if (!chat) { $("rate").hidden = true; $("review").hidden = true; return; }
  renderRate(s, chat);
  renderReview(s, chat);
}

// ── annotate a message ────────────────────────────────────────────────────
// Opens by itself for the newest AI message from the other side (her, when you
// play the fan; him, when you play her). Click any message to annotate that
// one instead: your own messages ask WHY you sent them.
let pinned = "";            // ids of a message you clicked, overriding the auto one
let rateKey = "", rateScore = 0, rateTags = new Set(), rateRun = [];

function pending(s, chat) {
  if (chat.ended) return null;
  const other = s.role === "fan" ? "her" : "fan";
  const ms = chat.messages;
  let i = ms.length - 1;
  while (i >= 0 && !(ms[i].who === other && ms[i].by === "ai")) i--;
  if (i < 0) return null;
  const run = runOf(chat, ms[i].id);
  return run.some(m => m.rated) ? null : run;
}

function renderRate(s, chat) {
  let run = pinned ? chat.messages.filter(m => pinned.split(",").includes(m.id)) : null;
  if (pinned && !run.length) { pinned = ""; run = null; }
  run = run || pending(s, chat);
  const box = $("rate");
  if (!run || !run.length) { box.hidden = true; rateKey = ""; return; }
  const key = run.map(m => m.id).join(",");
  if (key === rateKey && !box.hidden) return;   // same message: keep what you've typed
  rateKey = key; rateRun = run; rateScore = 0; rateTags = new Set();
  const m = run[0];
  const ai = m.by === "ai";
  const human = !ai && ["user", "human-edit", undefined].includes(m.by);
  const speaker = m.who === "fan" ? "fan" : "her";
  const a = m.ann || {};
  $("rateTitle").textContent = ai ? (speaker === "her" ? "Rate her reply" : "How real is he?")
    : human ? "Your message: why this?" : `${BY[m.by] || "This"} message`;
  $("rateModel").textContent = m.model ? "· " + m.model : "";
  $("rateQuote").textContent = run.map(x => x.text).join(" ");
  $("rateScoreWrap").hidden = !ai;
  $("rateRewriteWrap").hidden = !ai;
  $("rateNote").placeholder = ai ? "What was wrong, or right?"
    : "Why did you send this? What were you going for? (teaches the AI your reasoning)";
  $("rateNote").value = (ai ? a.note : a.rationale) || "";
  $("rateRewrite").value = a.rewrite || "";
  $("rateScores").innerHTML = Array.from({ length: 10 }, (_, i) =>
    `<button data-n="${i + 1}" title="${TF.esc(TF.SCALE[speaker][i + 1])}">${i + 1}</button>`).join("");
  $("rateTags").innerHTML = TF.TAGS[speaker].map(t =>
    `<button data-t="${TF.esc(t)}" class="${t === "good" ? "good" : ""}">${TF.esc(t)}</button>`).join("");
  const steps = s.steps || {};
  $("rateStep").innerHTML = `<option value="">The move it should have made…</option>` +
    Object.keys(steps).map(k => `<option value="${k}">${TF.esc(k.replace("_", " "))}: ${TF.esc(steps[k])}</option>`).join("");
  if (a.score) pickScore(a.score);
  (a.tags || []).forEach(t => toggleTag(t, true));
  $("rateStep").value = a.should_step || "";
  $("rateStep").hidden = !(speaker === "her" && rateTags.has("wrong move"));
  $("rateAnchor").textContent = rateScore ? TF.SCALE[speaker][rateScore] : "Pick a score";
  updateSave();
  box.hidden = false;
}

function speakerOf() { return rateRun[0] && rateRun[0].who === "fan" ? "fan" : "her"; }
function isAI() { return rateRun[0] && rateRun[0].by === "ai"; }
function pickScore(n) {
  rateScore = n;
  [...$("rateScores").children].forEach(b => b.classList.toggle("on", +b.dataset.n === n));
  $("rateAnchor").textContent = TF.SCALE[speakerOf()][n];
  updateSave();
}
function toggleTag(t, on) {
  if (on ?? !rateTags.has(t)) rateTags.add(t); else rateTags.delete(t);
  [...$("rateTags").children].forEach(b => b.classList.toggle("on", rateTags.has(b.dataset.t)));
  $("rateStep").hidden = !(speakerOf() === "her" && rateTags.has("wrong move"));
}
function updateSave() {
  $("rateSave").disabled = isAI() ? !rateScore : !$("rateNote").value.trim();
}

$("rateScores").addEventListener("click", e => {
  const b = e.target.closest("button"); if (b) pickScore(+b.dataset.n);
});
$("rateScores").addEventListener("mouseover", e => {
  const b = e.target.closest("button");
  if (b) $("rateAnchor").textContent = TF.SCALE[speakerOf()][+b.dataset.n];
});
$("rateScores").addEventListener("mouseleave", () => {
  $("rateAnchor").textContent = rateScore ? TF.SCALE[speakerOf()][rateScore] : "Pick a score";
});
$("rateTags").addEventListener("click", e => {
  const b = e.target.closest("button"); if (b) toggleTag(b.dataset.t);
});
$("rateNote").addEventListener("input", updateSave);

async function rateSend(skip) {
  if (!rateKey) return;
  if (!skip && $("rateSave").disabled) return;
  const ai = isAI();
  const body = { chat: S.active, ids: rateKey.split(","), skip };
  if (!skip) {
    if (ai) Object.assign(body, {
      score: rateScore, tags: [...rateTags], note: $("rateNote").value,
      rewrite: $("rateRewrite").value, replace: $("rateReplace").checked,
      should_step: $("rateStep").hidden ? "" : $("rateStep").value });
    else body.rationale = $("rateNote").value;
  }
  $("rate").hidden = true; pinned = ""; rateKey = "";
  await TF.post("/api/annotate", body);
  const i = IC.input(root); if (i) i.focus();
}
$("rateSave").onclick = () => rateSend(false);
$("rateSkip").onclick = () => rateSend(true);
// Enter in a text box saves (once it can); Shift+Enter is a new line.
for (const id of ["rateNote", "rateRewrite"]) {
  $(id).addEventListener("keydown", e => {
    if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); rateSend(false); }
  });
}

// ── end-of-chat review ────────────────────────────────────────────────────
let rv = { overall: 0, fan: 0 }, rvOpenFor = "";
function scoreRow(id, scale, key) {
  $(id).innerHTML = Array.from({ length: 10 }, (_, i) =>
    `<button data-n="${i + 1}" title="${TF.esc(scale[i + 1])}">${i + 1}</button>`).join("");
  $(id).onclick = e => {
    const b = e.target.closest("button"); if (!b) return;
    rv[key] = +b.dataset.n;
    [...$(id).children].forEach(x => x.classList.toggle("on", x === b));
    $(id + "A").textContent = scale[rv[key]];
    $("rvSave").disabled = $("rvKeep").disabled = !rv.overall;
  };
}
function renderReview(s, chat) {
  const open = s.review === chat.id;
  $("review").hidden = !open;
  if (!open) { rvOpenFor = ""; return; }
  if (rvOpenFor === chat.id) return;              // keep what you've typed
  rvOpenFor = chat.id; rv = { overall: 0, fan: 0 };
  scoreRow("rvOverall", TF.SCALE.convo, "overall");
  scoreRow("rvFan", TF.SCALE.fan, "fan");
  $("rvOverallA").textContent = $("rvFanA").textContent = "Pick a score";
  $("rvOverallK").textContent = s.role === "fan" ? "Her (the AI), overall" : "You, overall";
  $("rvFanRow").hidden = !chat.messages.some(m => m.who === "fan" && m.by === "ai");
  $("rvOutcome").innerHTML = `<option value="">—</option>` + TF.OUTCOMES.map(o => `<option>${TF.esc(o)}</option>`).join("");
  const opts = `<option value="">—</option>` + chat.messages.map((m, i) =>
    `<option value="${m.id}">${i + 1}. ${m.who === "fan" ? "him" : "her"}: ${TF.esc(m.text.slice(0, 60))}</option>`).join("");
  $("rvBest").innerHTML = opts; $("rvWorst").innerHTML = opts;
  for (const id of ["rvWell", "rvWrong", "rvLesson"]) $(id).value = "";
  $("rvSave").disabled = $("rvKeep").disabled = true;
}
async function reviewSend(keepOpen) {
  const chat = TF.activeChat(S);
  const pick = id => { const m = chat.messages.find(x => x.id === $(id).value); return m ? `${m.who}: ${m.text}` : ""; };
  await TF.post("/api/review", {
    id: chat.id, keep_open: keepOpen, overall: rv.overall, fan_realism: rv.fan,
    outcome: $("rvOutcome").value, best: pick("rvBest"), worst: pick("rvWorst"),
    went_well: $("rvWell").value, went_wrong: $("rvWrong").value, lesson: $("rvLesson").value });
}
$("rvCancel").onclick = () => TF.post("/api/review", { cancel: true });
$("rvSave").onclick = () => reviewSend(false);
$("rvKeep").onclick = () => reviewSend(true);

// ── the composer ──────────────────────────────────────────────────────────
// Enter sends, Shift+Enter is a new line — the way Infloww's box behaves, and
// what MMA's mass engine (Ctrl+V, Enter) and typelog expect. The textarea is
// the clone's, and survives every redraw, so it is wired once.
async function send() {
  const input = IC.input(root);
  if (!input) return;
  const text = input.value.replace(/\s+$/, "");
  if (!text.trim()) return;
  input.value = "";
  const r = await TF.post("/api/send", { who: S && S.role === "fan" ? "fan" : "her", text });
  if (r && r.error) { input.value = text; }
}
function wireInput() {
  const input = IC.input(root);
  if (!input) return;
  wired = true;
  input.addEventListener("keydown", e => {
    if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send(); }
  });
  input.focus();
}

TF.watch(render);
