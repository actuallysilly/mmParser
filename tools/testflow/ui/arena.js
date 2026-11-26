// TestFlow Arena: the page over arena.py's state. Every button is one POST;
// the long-poll (TF.watch) redraws from whatever the server now holds.
const $ = id => document.getElementById(id);
let S = null;              // the last state
let opts = { models: [], personas: [], voices: [], default: "" };
let editing = null;        // { msg, text } while a message is being edited

const match = () => S && S.matches[S.active];
const post = async (path, body) => {
  const r = await TF.post(path, { id: S && S.active, ...body });
  if (r && r.error) flash(r.error);
  return r;
};
function flash(text) {
  $("status").textContent = text;
  $("status").className = "chip bad";
}

// ── options (models, personas, voices) ───────────────────────────────────────
function fillSelect(el, items, value) {
  el.innerHTML = items.map(([v, label]) =>
    `<option value="${TF.esc(v)}"${v === value ? " selected" : ""}>${TF.esc(label)}</option>`).join("");
}
function modelItems() {
  return [["", `llm.ini default (${opts.default || "?"})`], ...opts.models.map(m => [m, m])];
}
function voiceItems() {
  return [["", "Default (basic)"], ...opts.voices.map(v => [v.account, v.name.endsWith("(category)") ? v.name : `${v.name} (${v.account})`])];
}
function personaItems() {
  return [["random", "Random"], ...opts.personas.map(p => [p.id, p.name])];
}
async function loadOptions() {
  const o = await TF.get("/api/options");
  if (!o.error || o.models) opts = { ...opts, ...o };
  fillSelect($("nPersona"), personaItems(), "regular");
  fillSelect($("nAccount"), voiceItems(), opts.voices[0] ? opts.voices[0].account : "");
  fillSelect($("nHerModel"), modelItems(), "");          // llm.ini's model (artemis)
  fillSelect($("nFanModel"), modelItems(), "");
  if (o.error) flash(o.error);
}

// ── drawing ──────────────────────────────────────────────────────────────────
function render() {
  if (!S) return;
  const m = match();
  renderBar(m);
  renderMatches();
  renderHead(m);
  if (!editing) renderChat(m);
  renderSettings(m);
  renderStats(m);
  renderCuts(m);
}

function renderBar(m) {
  const playing = S.playing && S.playing === S.active;
  $("play").textContent = playing ? "⏸ Pause" : "▶ Play";
  if (document.activeElement !== $("delay")) $("delay").value = S.delay;
  if (document.activeElement !== $("maxTurns")) $("maxTurns").value = S.max_turns;
  const st = $("status");
  if (S.error) { st.textContent = S.error; st.className = "chip bad"; }
  else if (S.busy) { st.textContent = `${S.busy === "fan" ? "the fan" : "she"} is writing…`; st.className = "chip"; }
  else if (playing) { st.textContent = `playing · turn ${S.turns}/${S.max_turns}`; st.className = "chip ok"; }
  else { st.textContent = S.status || "paused"; st.className = "chip"; }
  $("typing").hidden = !S.busy;
  $("typing").textContent = S.busy ? `${S.busy === "fan" ? (m ? m.fan.name : "he") : "she"} is typing…` : "";
  for (const id of ["stepNext", "stepFan", "stepHer"]) $(id).disabled = !!S.busy || !m;
}

function renderMatches() {
  const list = Object.values(S.matches).sort((a, b) => b.created - a.created);
  $("matches").innerHTML = list.map(m => {
    const p = opts.personas.find(x => x.id === m.fan.persona);
    const n = m.messages.filter(x => x.kind !== "handoff").length;
    return `<button class="match${m.id === S.active ? " on" : ""}" data-id="${m.id}">
      <b>${TF.esc(m.fan.name)}</b>
      <small>${TF.esc(p ? p.name : m.fan.persona)} · ${m.her.engine}${m.her.account ? " · " + TF.esc(m.her.account) : ""} · ${n} msgs${m.parent ? " · fork" : ""}</small>
    </button>`;
  }).join("") || `<p class="hint">No matches yet. Start one below.</p>`;
}

function renderHead(m) {
  if (!m) { $("chatHead").innerHTML = ""; return; }
  const p = opts.personas.find(x => x.id === m.fan.persona);
  $("chatHead").innerHTML = `<b>${TF.esc(m.fan.name)}</b> (${TF.esc(p ? p.about : m.fan.persona)})
    · bought so far: <b>${TF.esc(S.tiers[m.tier])}</b>${m.next_ppv ? ` · next PPV: <b>${TF.esc(m.next_ppv)}</b>` : ""}`;
}

function metaLine(x) {
  const bits = [];
  if (x.by === "ai") bits.push(`${x.who === "her" ? (x.engine || "her") : "fan"} · ${TF.esc(x.model || "")}`);
  else if (x.by === "edit") bits.push("edited by you");
  else if (x.by === "you") bits.push("you");
  else bits.push(TF.esc(x.by));
  if (x.read && x.read.step) bits.push(`step: ${TF.esc(x.read.step)}`);
  for (const n of x.notes || []) bits.push(`<span class="note">📝 ${TF.esc(n)}</span>`);
  for (const f of x.flags || []) bits.push(`<span class="flag">⚠ ${TF.esc(f)}</span>`);
  if (x.who === "fan" && x.bought === true) bits.push(`<span class="up">bought it</span>`);
  if (x.who === "fan" && x.bought === false) bits.push(`<span class="down">passed</span>`);
  if (x.thumb) bits.push(`<span class="${x.thumb}">${x.thumb === "up" ? "👍" : "👎"}${x.note ? " " + TF.esc(x.note) : ""}</span>`);
  bits.push(TF.time(x.ts));
  return bits.join(" · ");
}

function tools(x) {
  const ai = x.by === "ai" || x.by === "edit";
  return `<div class="tools">
    <button data-act="edit" title="Edit this message">✎ Edit</button>
    ${ai ? `<button data-act="reroll" title="Write this turn again">⟲ Re-roll</button>` : ""}
    <button data-act="cut" title="Rewind: keep up to here">✂ Cut after</button>
    <button data-act="fork" title="New match from here">⑂ Fork</button>
    <button data-act="up" title="Good">👍</button>
    <button data-act="down" title="Bad (add a note)">👎</button>
    <button data-act="delete" title="Delete this one message">🗑</button>
  </div>`;
}

function renderChat(m) {
  const box = $("chat");
  const atEnd = box.scrollHeight - box.scrollTop - box.clientHeight < 60;
  if (!m) { box.innerHTML = `<p class="empty">Start a match on the left.</p>`; return; }
  if (!m.messages.length) {
    box.innerHTML = `<p class="empty">Empty chat. Press <b>Play</b> and the fan writes first,
      or type as either of them below.</p>`;
    return;
  }
  let prev = "";
  // The meta line once per burst (its last text), unless a text has its own
  // note, flag, thumb or edit to show.
  const own = x => (x.notes || []).length || (x.flags || []).length || x.thumb || x.by !== "ai" || x.kind === "ppv";
  const lastOfBurst = (x, i) => {
    const n = m.messages[i + 1];
    return !n || n.who !== x.who || (n.reply || n.id) !== (x.reply || x.id);
  };
  box.innerHTML = m.messages.map((x, i) => {
    if (x.kind === "handoff") {
      prev = "";
      return `<div class="handoff" data-msg="${x.id}">✋ Her side handed this to you: ${TF.esc(x.text)}
        <br><small>Type as her, re-roll it, or give her a Direction and press Her now.</small>
        <button class="ghost" data-act="delete" data-msg="${x.id}">dismiss</button></div>`;
    }
    const first = x.who !== prev;
    prev = x.who;
    let body;
    if (x.kind === "ppv") {
      const p = x.ppv;
      const state = p.paid ? "bought" : p.decided ? "passed" : "waiting for him";
      body = `<div class="ppv${p.paid ? " paid" : ""}">
        <div class="lock"><span>🔒 PPV · $${TF.esc(p.price)} · ${TF.esc(p.content)}</span>
          <span class="state">${state}
            <button class="ghost" data-act="paid" title="Mark as bought">✓</button>
            <button class="ghost" data-act="unpaid" title="Mark as passed">✗</button></span></div>
        ${x.text ? `<div class="cap">${TF.esc(x.text)}</div>` : ""}</div>`;
    } else {
      body = `<div class="bubble">${TF.esc(x.text)}</div>`;
    }
    const orig = x.original ? `<div class="orig" title="what the model wrote">${TF.esc(x.original)}</div>` : "";
    return `<div class="msg ${x.who} by-${x.by}${first ? " first" : ""}" data-msg="${x.id}">
      ${tools(x)}${body}${orig}${own(x) || lastOfBurst(x, i) ? `<div class="meta">${metaLine(x)}</div>` : ""}</div>`;
  }).join("");
  if (atEnd) box.scrollTop = box.scrollHeight;
}

function renderEdit(id) {
  const el = document.querySelector(`.msg[data-msg="${id}"]`);
  if (!el) return;
  el.innerHTML = `<div class="editbox">
    <textarea id="editText">${TF.esc(editing.text)}</textarea>
    <div class="btnrow">
      <button data-act="editCancel" class="ghost">Cancel</button>
      <button data-act="editSave" title="Keep what came after">Save</button>
      <button data-act="editReplay" class="primary" title="Cut what came after and carry on from here">Save &amp; replay from here</button>
    </div></div>`;
  const t = $("editText");
  t.addEventListener("input", () => { editing.text = t.value; });
  t.addEventListener("keydown", e => {
    if (e.key === "Escape") { editing = null; render(); }
    if (e.key === "Enter" && e.ctrlKey) { e.preventDefault(); saveEdit(true); }
  });
  t.focus();
  t.setSelectionRange(t.value.length, t.value.length);
}

function renderSettings(m) {
  const box = $("settings");
  if (!m) { box.innerHTML = ""; return; }
  if (box.contains(document.activeElement) && box.dataset.mid === m.id) return;   // typing in it
  box.dataset.mid = m.id;
  box.innerHTML = `
    <label>Fan persona<select data-k="fan_persona"></select></label>
    <label>Fan model<select data-k="fan_model"></select></label>
    <label>Her engine<select data-k="her_engine">
      <option value="co">Co-chatter</option><option value="agent">Agent (pitches PPVs)</option></select></label>
    <label>Her voice<select data-k="her_account"></select></label>
    <label>Her model<select data-k="her_model"></select></label>
    <label>Bought so far<select data-k="tier"></select></label>
    <label>Next PPV<input data-k="next_ppv" type="text" spellcheck="false" placeholder="what she should set up"></label>
    <div class="btnrow"><button id="forkEnd" class="ghost">⑂ Fork whole match</button>
      <button id="delMatch" class="ghost danger">Delete match</button></div>`;
  const q = k => box.querySelector(`[data-k="${k}"]`);
  fillSelect(q("fan_persona"), opts.personas.map(p => [p.id, p.name]), m.fan.persona);
  fillSelect(q("fan_model"), modelItems(), m.fan.model || "");
  q("her_engine").value = m.her.engine;
  fillSelect(q("her_account"), voiceItems(), m.her.account || "");
  fillSelect(q("her_model"), modelItems(), m.her.model || "");
  fillSelect(q("tier"), S.tiers.map((t, i) => [String(i), t]), String(m.tier));
  q("next_ppv").value = m.next_ppv || "";
  if (document.activeElement !== $("direction")) $("direction").value = m.direction || "";
}

function renderStats(m) {
  if (!m) { $("stats").innerHTML = ""; return; }
  const msgs = m.messages.filter(x => x.kind !== "handoff");
  const her = msgs.filter(x => x.who === "her" && x.kind !== "ppv");
  const fan = msgs.filter(x => x.who === "fan");
  const ppvs = msgs.filter(x => x.kind === "ppv");
  const paid = ppvs.filter(x => x.ppv.paid);
  const money = paid.reduce((s, x) => s + (parseFloat(x.ppv.price) || 0), 0);
  const words = her.reduce((s, x) => s + x.text.split(/\s+/).filter(Boolean).length, 0);
  const rows = [
    ["Her texts", her.length], ["His texts", fan.length],
    ["Words per text (her)", her.length ? (words / her.length).toFixed(1) : "–"],
    ["PPVs bought / sent", `${paid.length} / ${ppvs.length}`], ["Earned", `$${money.toFixed(2)}`],
    ["Handoffs", m.messages.filter(x => x.kind === "handoff").length],
    ["Edited by you", msgs.filter(x => x.by === "edit").length],
    ["👍 / 👎", `${msgs.filter(x => x.thumb === "up").length} / ${msgs.filter(x => x.thumb === "down").length}`],
    ["Cut branches", m.cuts.length],
  ];
  $("stats").innerHTML = rows.map(([k, v]) => `<span>${k}</span><span>${v}</span>`).join("");
}

function renderCuts(m) {
  if (!m || !m.cuts.length) { $("cuts").innerHTML = `<p class="hint">None yet.</p>`; return; }
  $("cuts").innerHTML = m.cuts.slice().reverse().map(c => {
    const lines = c.messages.filter(x => x.kind !== "handoff")
      .map(x => `${x.who === "fan" ? "him" : "her"}: ${x.kind === "ppv" ? `[PPV $${x.ppv.price}${x.ppv.paid ? " bought" : ""}] ` : ""}${x.text}`);
    return `<div class="cut"><div class="head"><span>${TF.esc(c.reason)} · after msg ${c.at} · ${TF.time(c.ts)}</span>
      <button data-cut="${c.id}">Restore</button></div><pre>${TF.esc(lines.join("\n"))}</pre></div>`;
  }).join("");
}

// ── actions ──────────────────────────────────────────────────────────────────
async function saveEdit(replay) {
  const e = editing;
  editing = null;
  await post("/api/edit", { msg: e.msg, text: e.text, replay });
  if (replay && !(S.playing === S.active)) post("/api/step", { who: "next" });
  render();
}

$("chat").addEventListener("click", async ev => {
  const b = ev.target.closest("button[data-act]");
  if (!b) return;
  const row = b.closest("[data-msg]");
  const id = b.dataset.msg || (row && row.dataset.msg);
  const m = match();
  const x = m && m.messages.find(y => y.id === id);
  switch (b.dataset.act) {
    case "edit": editing = { msg: id, text: x.text }; renderEdit(id); break;
    case "editCancel": editing = null; render(); break;
    case "editSave": saveEdit(false); break;
    case "editReplay": saveEdit(true); break;
    case "reroll": post("/api/reroll", { msg: id }); break;
    case "cut": post("/api/cut", { msg: id }); break;
    case "fork": post("/api/fork", { msg: id }); break;
    case "delete": post("/api/delete", { msg: id }); break;
    case "up": post("/api/thumb", { msg: id, value: x.thumb === "up" ? "" : "up" }); break;
    case "down": {
      if (x.thumb === "down") { post("/api/thumb", { msg: id, value: "" }); break; }
      const note = prompt("What was wrong with it? (optional)", x.note || "");
      if (note !== null) post("/api/thumb", { msg: id, value: "down", note });
      break;
    }
    case "paid": post("/api/ppv/paid", { msg: id, paid: true }); break;
    case "unpaid": post("/api/ppv/paid", { msg: id, paid: false }); break;
  }
});

$("matches").addEventListener("click", ev => {
  const b = ev.target.closest(".match");
  if (b) { editing = null; TF.post("/api/select", { id: b.dataset.id }); }
});

$("settings").addEventListener("change", ev => {
  const k = ev.target.dataset.k;
  if (k) post("/api/update", { [k]: ev.target.value });
});
$("settings").addEventListener("click", ev => {
  if (ev.target.id === "forkEnd") post("/api/fork", {});
  if (ev.target.id === "delMatch" && confirm("Delete this match? Its log lines in arena.jsonl stay.")) {
    post("/api/match/delete", {});
  }
});
$("cuts").addEventListener("click", ev => {
  const b = ev.target.closest("button[data-cut]");
  if (b) post("/api/restore", { cut: b.dataset.cut });
});

$("create").onclick = async () => {
  const r = await TF.post("/api/new", {
    persona: $("nPersona").value, name: $("nName").value, engine: $("nEngine").value,
    account: $("nAccount").value, her_model: $("nHerModel").value, fan_model: $("nFanModel").value,
    opener: $("nOpener").value, next_ppv: $("nNext").value });
  if (r.error) flash(r.error);
  $("nName").value = "";
};

$("play").onclick = () => post("/api/play", { on: !(S.playing && S.playing === S.active) });
$("stepNext").onclick = () => post("/api/step", { who: "next" });
$("stepFan").onclick = () => post("/api/step", { who: "fan" });
$("stepHer").onclick = () => post("/api/step", { who: "her" });
$("delay").onchange = e => TF.post("/api/settings", { delay: +e.target.value || 1 });
$("maxTurns").onchange = e => TF.post("/api/settings", { max_turns: +e.target.value || 30 });
$("direction").onchange = e => post("/api/update", { direction: e.target.value });

async function send(who) {
  const t = $("text").value.trim();
  if (!t || !match()) return;
  $("text").value = "";
  await post("/api/update", { direction: $("direction").value });
  const r = await post("/api/send", { who, text: t });
  answer(r, who === "fan" ? "her" : "fan");
}
// Paused and "They answer" ticked: the other side writes once. While playing,
// the loop does that anyway.
function answer(r, who) {
  if (r && !r.error && $("answer").checked && !(S.playing === S.active)) {
    setTimeout(() => post("/api/step", { who }), 300);
  }
}
$("asFan").onclick = () => send("fan");
$("asHer").onclick = () => send("her");
$("text").addEventListener("keydown", e => {
  if (e.key !== "Enter") return;
  if (e.ctrlKey) {            // a new line inside the message
    e.preventDefault();
    const t = e.target, at = t.selectionStart;
    t.value = t.value.slice(0, at) + "\n" + t.value.slice(t.selectionEnd);
    t.selectionStart = t.selectionEnd = at + 1;
    return;
  }
  e.preventDefault();
  send(e.shiftKey ? "fan" : "her");
});

$("ppvToggle").onclick = () => { $("ppvRow").hidden = !$("ppvRow").hidden; };
$("ppvSend").onclick = async () => {
  if (!match()) return;
  const caption = $("text").value.trim();
  $("text").value = "";
  const r = await post("/api/send", { who: "her", text: caption, ppv: {
    content: $("ppvContent").value, price: $("ppvPrice").value, tier: +$("ppvTier").value } });
  $("ppvContent").value = "";
  answer(r, "fan");
};

// ── start ────────────────────────────────────────────────────────────────────
(async () => {
  await loadOptions();
  TF.watch(s => {
    S = s;
    fillSelect($("ppvTier"), s.tiers.slice(1).map((t, i) => [String(i + 1), `shows: ${t}`]),
               $("ppvTier").value || "1");
    render();
  });
})();
