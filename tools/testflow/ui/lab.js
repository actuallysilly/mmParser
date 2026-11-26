// TestFlow Lab — an AI-training tool. Who you play, how a chat starts, the AI
// settings, the rating scale, your data. Blind drafts live under Advanced.
const $ = id => document.getElementById(id);
let S = null, personas = [], models = { models: [], default: "" }, mode = "agent", scenario = "cold";
const chosenModels = new Set();

// A state update never overwrites a field you are typing in.
function setVal(el, v) { if (document.activeElement !== el && el.value !== String(v ?? "")) el.value = v ?? ""; }

function fillTiers(sel, tiers) {
  if (sel.options.length === tiers.length) return;
  sel.innerHTML = tiers.map((t, i) => `<option value="${i}">${i} · ${TF.esc(t)}</option>`).join("");
}

const ROLE_HINT = {
  fan: "Type in the TestFlow window as the fan. She replies after the pause and a card asks you to rate her: score, tags, what was wrong, and what you'd have sent. Your rewrite can replace hers so the chat carries on from a good message.",
  her: "Type in the TestFlow window as her, with all your MMA tools. The AI fan answers. Everything you send is a gold example of real chatting; click any of your messages to say why you sent it, and rate how real he sounds.",
};
const SC_HINT = {
  cold: "Nobody has written yet. Whoever you are writes first (or press \"Make him reply now\" to let the AI fan open).",
  welcome: "A new subscriber: her automated welcome message goes first, then he replies.",
  mass: "He's replying to a mass message: yours below, or one of your real ones from the archive.",
  random: "Any of the three, with a random fan persona and name.",
};

function render(s) {
  S = s;
  const chat = TF.activeChat(s);
  $("roleFan").classList.toggle("on", s.role === "fan");
  $("roleHer").classList.toggle("on", s.role === "her");
  $("roleHint").textContent = ROLE_HINT[s.role] || "";
  setVal($("welcome"), s.welcome_text);

  const ids = Object.keys(s.chats);
  const opts = ids.map(id => {
    const c = s.chats[id];
    const sc = (c.scenario || {}).kind || "cold";
    return `<option value="${id}">${TF.esc(c.fan.name)} · ${sc} · ${c.messages.length} msgs${c.ended ? " · reviewed" : ""}</option>`;
  }).join("");
  if ($("chatSel").innerHTML !== opts) $("chatSel").innerHTML = opts;
  $("chatSel").value = s.active;
  if (chat) {
    fillTiers($("tier"), s.tiers); fillTiers($("ppvTier"), s.tiers);
    if (document.activeElement !== $("tier")) $("tier").value = chat.tier || 0;
    const p = personas.find(x => x.id === chat.fan.persona);
    const sc = chat.scenario || {};
    $("chatInfo").textContent = `${chat.fan.name}, ${p ? p.name.toLowerCase() : chat.fan.persona}` +
      (p ? ` (${p.about})` : "") + (sc.opener ? `. Opened with: "${sc.opener}"` : "") +
      (chat.ended ? ". Reviewed and closed." : "");
    $("review").disabled = !!chat.ended || !chat.messages.length;
  }
  $("ppvBox").hidden = s.role !== "her";
  $("autoFan").checked = !!s.auto_fan;
  $("autoHer").checked = !!s.auto_her;
  setVal($("fanDelay"), s.fan_delay);
  setVal($("herDelay"), s.her_delay);
  if (document.activeElement !== $("fanModel")) $("fanModel").value = s.fan_model || "";
  if (document.activeElement !== $("herModel")) $("herModel").value = s.her_model || "";

  $("autoAgent").checked = !!s.auto_agent;
  $("busy").textContent = s.busy ? (mode === "agent" ? "Reading the chat, then drafting…" : "Drafting… (each model loads in turn)")
                                 : (s.typing ? (s.role === "fan" ? "She is typing…" : "He is typing…") : "");
  $("draft").disabled = !!s.busy;
  renderRead(s);
  renderDrafts(s);
  showError(s.error);
  if (!s.busy) loadStats();
}

function setScenario(sc) {
  scenario = sc;
  for (const b of document.querySelectorAll("[data-sc]")) b.classList.toggle("on", b.dataset.sc === sc);
  $("scHint").textContent = SC_HINT[sc];
  $("welcomeWrap").hidden = sc !== "welcome";
  $("massWrap").hidden = sc !== "mass";
  $("newPersona").disabled = sc === "random";
}
for (const b of document.querySelectorAll("[data-sc]")) b.onclick = () => setScenario(b.dataset.sc);
setScenario("cold");

$("start").onclick = async () => {
  const r = await TF.post("/api/chat/new", {
    scenario, persona: $("newPersona").value, name: $("newName").value,
    welcome: $("welcome").value, mass: $("mass").value });
  if (r.error) return showError(r.error);
  $("newName").value = "";
  $("startMsg").textContent = `Started: ${r.scenario}, ${r.persona}.`;
  setTimeout(() => { $("startMsg").textContent = ""; }, 4000);
};

for (const [ol, key] of [["scaleHer", "her"], ["scaleFan", "fan"]]) {
  $(ol).innerHTML = TF.SCALE[key].slice(1).map(t => `<li>${TF.esc(t)}</li>`).join("");
}

const STEP_NAMES = {
  tease: "Tease", sext: "Keep sexting", pitch_ppv: "Pitch a PPV", bump_ppv: "Bump the PPV",
  yap: "Talk normally", back_off: "Back off", aftercare: "Aftercare", hand_off: "Hand to the chatter",
};

// The agent's read: interest, mood, the step it chose, and your verdict on it.
function renderRead(s) {
  const box = $("read");
  const d = s.drafts;
  const r = d && d.chat === s.active ? d.read : null;
  if (!r) { box.innerHTML = ""; box.dataset.key = ""; return; }
  const j = d.judged || {};
  const key = d.run + JSON.stringify(j);
  if (box.dataset.key === key) return;
  box.dataset.key = key;
  const lvl = r.interest <= 2 ? "low" : r.interest === 3 ? "mid" : "";
  const steps = Object.keys(s.steps || STEP_NAMES);
  const on = (cond) => cond ? " on" : "";
  box.innerHTML = `
    <div class="read${r.step === "hand_off" ? " handoff" : ""}">
      <div class="row"><span class="k">Interest</span>
        <span class="meter5 ${lvl}" aria-label="${r.interest} of 5">${[1, 2, 3, 4, 5].map(n => `<i class="${n <= r.interest ? "on" : ""}"></i>`).join("")}</span>
        <span>${r.interest}/5 · ${TF.esc(r.mood)}</span></div>
      <div class="ev">${TF.esc(r.evidence)}</div>
      <div class="row"><span class="k">Next step</span><span class="step">${TF.esc(STEP_NAMES[r.step] || r.step)}</span></div>
      <div class="note">${TF.esc(r.note)}</div>
      ${r.step === "hand_off" ? `<div class="flags">No draft: this one is yours.</div>` : ""}
      <div class="meta">read by ${TF.esc(r.model)} in ${(r.ms / 1000).toFixed(1)} s${d.draft_ms ? ` · drafts ${(d.draft_ms / 1000).toFixed(1)} s` : ""}</div>
      <div class="verdict" role="group" aria-label="Was his interest right?"><span class="k">Interest</span>
        <button data-j="interest" data-v="low" class="${on(j.interest === "low")}">Really lower</button>
        <button data-j="interest" data-v="right" class="${on(j.interest === "right")}">Right</button>
        <button data-j="interest" data-v="high" class="${on(j.interest === "high")}">Really higher</button></div>
      <div class="verdict" role="group" aria-label="Was the step right?"><span class="k">Step</span>
        <button data-j="step_ok" data-v="1" class="${on(j.step_ok === true)}">Right</button>
        <button data-j="step_ok" data-v="0" class="${on(j.step_ok === false)}">Wrong</button>
        ${j.step_ok === false ? `<select id="stepShould" aria-label="What it should have been">
          <option value="">It should have been…</option>
          ${steps.filter(k => k !== r.step).map(k => `<option value="${k}"${j.step === k ? " selected" : ""}>${TF.esc(STEP_NAMES[k] || k)}</option>`).join("")}
        </select>` : ""}</div>
      <div class="verdict"><span class="k">Note</span>
        <input id="judgeNote" type="text" placeholder="anything else (Enter saves)" spellcheck="false" value="${TF.esc(j.note || "")}"></div>
    </div>`;
}

$("read").addEventListener("click", e => {
  const b = e.target.closest("[data-j]");
  if (!b) return;
  const v = b.dataset.j === "step_ok" ? b.dataset.v === "1" : b.dataset.v;
  TF.post("/api/judge", { [b.dataset.j]: v });
});
$("read").addEventListener("change", e => {
  if (e.target.id === "stepShould" && e.target.value) TF.post("/api/judge", { step: e.target.value });
  if (e.target.id === "judgeNote") TF.post("/api/judge", { note: e.target.value.trim() });
});
$("read").addEventListener("keydown", e => {
  if (e.target.id === "judgeNote" && e.key === "Enter") { e.preventDefault(); e.target.blur(); }
});

function renderDrafts(s) {
  const box = $("drafts");
  const d = s.drafts;
  if (!d || d.chat !== s.active) { box.innerHTML = ""; return; }
  if (!d.items.length) { box.innerHTML = `<p class="hint">No drafts came back.</p>`; return; }
  const blind = $("blind").checked && !d.revealed;
  // Keep edits in progress: only rebuild when the set of drafts or their state changed.
  const key = JSON.stringify(d.items.map(x => [x.id, x.rating, x.picked])) + blind;
  if (box.dataset.key === key) return;
  box.dataset.key = key;
  box.innerHTML = d.items.map(x => `
    <div class="draft${x.picked ? " picked" : ""}" data-id="${x.id}">
      <div class="top"><div class="lbl">Draft ${x.label}${blind ? "" : `<small>${TF.esc(x.model)}</small>`}</div>
        <div class="stars" role="group" aria-label="Rate draft ${x.label}">
          ${[1, 2, 3, 4, 5].map(n => `<button data-rate="${n}" class="${x.rating === n ? "on" : ""}" aria-label="${n} of 5">${n}</button>`).join("")}
        </div></div>
      <textarea rows="3" spellcheck="false">${TF.esc(x.text)}</textarea>
      ${x.flags && x.flags.length ? `<div class="flags">Still breaks: ${TF.esc(x.flags.join(", "))}</div>` : ""}
      <div class="actions"><span class="hint">${x.picked ? "Sent." : "Edit it if you want, then send."}</span>
        <button data-pick class="primary"${x.picked ? " disabled" : ""}>Send this</button></div>
    </div>`).join("");
}

$("drafts").addEventListener("click", e => {
  const card = e.target.closest(".draft");
  if (!card) return;
  const id = card.dataset.id;
  const r = e.target.closest("[data-rate]");
  if (r) return TF.post("/api/rate", { id, rating: +r.dataset.rate });
  if (e.target.closest("[data-pick]")) {
    TF.post("/api/pick", { id, text: card.querySelector("textarea").value });
  }
});

function showError(msg) {
  $("err").hidden = !msg;
  $("err").querySelector("span").textContent = msg || "";
}
$("err").querySelector("button").onclick = () => TF.post("/api/error/clear");

async function loadStats() {
  const st = await TF.post("/api/stats");
  if (!st.rows) return;
  const d = st.data || {};
  $("dataStats").textContent = `${d.annotated || 0} messages annotated · ${d.rewrites || 0} rewrites · ` +
    `${d.explained || 0} of your messages explained · ${d.reviews || 0} conversations reviewed`;
  const rr = st.replies || [];
  $("replyStats").textContent = rr.length ? "Average score: " + rr.map(r =>
    `${r.speaker === "fan" ? "fan" : "her"} (${r.model}) ${r.avg} over ${r.rated}`).join(" · ") : "";
  $("statsFile").textContent = "Everything is in " + st.file.replace(/ratings\.jsonl$/, "");
  $("stats").querySelector("tbody").innerHTML = st.rows.length ? st.rows.map(r =>
    `<tr><td>${TF.esc(r.model)}</td><td class="num">${r.rated}</td><td class="num">${r.avg ?? "—"}</td><td class="num">${r.picked}</td></tr>`).join("")
    : `<tr><td colspan="4" class="hint">Nothing rated yet.</td></tr>`;
  const a = st.agent || {};
  const pct = (x, n) => n ? `${x}/${n} (${Math.round(100 * x / n)}%)` : "none judged yet";
  $("agentStats").textContent = a.reads
    ? `Agent reads: ${a.reads}. Step right ${pct(a.step_right, a.step_judged)}. Interest right ${pct(a.interest_right, a.interest_judged)}.`
    : "";
}

$("export").onclick = async () => {
  $("exportMsg").textContent = "Building…";
  const r = await TF.post("/api/export");
  if (r.error) { $("exportMsg").textContent = ""; return showError(r.error); }
  $("exportMsg").textContent = "Done.";
  const names = { her_sft: "her: good examples", her_dpo: "her: better/worse pairs",
    fan_sft: "fan: good examples", fan_dpo: "fan: better/worse pairs", scored: "scored AI messages",
    rationales: "your explained messages", moves: "wrong-move verdicts", conversations: "conversation reviews" };
  $("exportOut").hidden = false;
  $("exportOut").textContent = r.dir + "\n" + Object.entries(r.counts)
    .map(([k, v]) => `  ${String(v).padStart(4)}  ${k}.jsonl  (${names[k] || k})`).join("\n");
};

async function loadModels() {
  models = await TF.get("/api/models");
  const ok = models.models && models.models.length && !models.error;
  $("ollama").textContent = ok ? "Ollama ready" : (models.error ? "Ollama down" : "No models");
  $("ollama").className = "chip " + (ok ? "ok" : "bad");
  $("ollama").title = models.error || "";
  const list = models.models || [];
  if (!chosenModels.size && models.default) chosenModels.add(models.default.replace(/:latest$/, ""));
  $("models").innerHTML = list.map(m => `<label class="check"><input type="checkbox" value="${TF.esc(m)}"${chosenModels.has(m) ? " checked" : ""}> ${TF.esc(m)}</label>`).join("")
    || `<span class="hint">No Ollama models found.</span>`;
  $("fanModel").innerHTML = `<option value="">Default (${TF.esc(models.default || "llm.ini")})</option>` +
    list.map(m => `<option value="${TF.esc(m)}">${TF.esc(m)}</option>`).join("");
  if (S) $("fanModel").value = S.fan_model || "";
  $("herModel").innerHTML = $("fanModel").innerHTML;
  // Her model may be one Ollama does not list (not pulled yet): keep it visible.
  const hm = S ? S.her_model || "" : "";
  if (hm && !list.includes(hm)) $("herModel").insertAdjacentHTML("beforeend", `<option value="${TF.esc(hm)}">${TF.esc(hm)} (not installed)</option>`);
  if (S) $("herModel").value = hm;
}
$("models").addEventListener("change", e => {
  if (e.target.checked) chosenModels.add(e.target.value); else chosenModels.delete(e.target.value);
});

// ── controls ──────────────────────────────────────────────────────────────
$("roleFan").onclick = () => TF.post("/api/settings", { role: "fan" });
$("roleHer").onclick = () => TF.post("/api/settings", { role: "her" });
$("welcome").onchange = e => TF.post("/api/settings", { welcome_text: e.target.value.trim() });
$("chatSel").onchange = e => TF.post("/api/chat/select", { id: e.target.value });
$("tier").onchange = e => TF.post("/api/chat/update", { id: S.active, tier: +e.target.value });
$("review").onclick = () => TF.post("/api/review/open", { id: S.active });
$("delChat").onclick = () => {
  const b = $("delChat");
  if (b.dataset.armed) { delete b.dataset.armed; b.textContent = "Delete"; TF.post("/api/chat/delete", { id: S.active }); }
  else { b.dataset.armed = "1"; b.textContent = "Click again (it's archived, not lost)"; setTimeout(() => { delete b.dataset.armed; b.textContent = "Delete"; }, 3000); }
};
$("autoFan").onchange = e => TF.post("/api/settings", { auto_fan: e.target.checked });
$("fanDelay").onchange = e => TF.post("/api/settings", { fan_delay: Math.max(1, +e.target.value || 4) });
$("fanModel").onchange = e => TF.post("/api/settings", { fan_model: e.target.value });
$("fanNow").onclick = () => TF.post("/api/fan/now");
$("autoHer").onchange = e => TF.post("/api/settings", { auto_her: e.target.checked });
$("herDelay").onchange = e => TF.post("/api/settings", { her_delay: Math.max(0.5, +e.target.value || 3) });
$("herModel").onchange = e => TF.post("/api/settings", { her_model: e.target.value });
$("herNow").onclick = () => TF.post("/api/her/now");
$("sendPpv").onclick = () => {
  TF.post("/api/ppv", { content: $("ppvContent").value, price: $("ppvPrice").value || "30",
                        tier: +$("ppvTier").value, caption: $("ppvCaption").value });
  $("ppvCaption").value = "";
};

function setMode(m) {
  mode = m;
  $("modeAgent").classList.toggle("on", m === "agent");
  $("modeCo").classList.toggle("on", m === "co");
  $("modeFiller").classList.toggle("on", m === "filler");
  $("modePpv").classList.toggle("on", m === "ppv");
  $("contentWrap").hidden = m === "filler";
  $("draft").textContent = m === "agent" ? "Ask her agent" : "Draft her replies";
}
$("modeAgent").onclick = () => setMode("agent");
$("modeCo").onclick = () => setMode("co");
$("modeFiller").onclick = () => setMode("filler");
$("modePpv").onclick = () => setMode("ppv");
setMode("agent");
$("autoAgent").onchange = e => TF.post("/api/settings", { auto_agent: e.target.checked });

async function fanSend() {
  const t = $("fanText").value.replace(/\s+$/, "");
  if (!t.trim()) return;
  $("fanText").value = "";
  await TF.post("/api/send", { who: "fan", text: t });
}
$("fanSend").onclick = fanSend;
$("fanText").addEventListener("keydown", e => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); fanSend(); } });

$("draft").onclick = async () => {
  const chosen = [...chosenModels];
  if (!chosen.length) return showError("Tick at least one model.");
  const r = await TF.post("/api/drafts", {
    mode, tier: +$("tier").value, content: $("content").value, direction: $("direction").value,
    models: chosen, per_model: +$("perModel").value });
  if (r.error) showError(r.error);
};
$("blind").onchange = () => { $("drafts").dataset.key = ""; if (S) renderDrafts(S); };

(async () => {
  personas = await TF.get("/api/personas");
  $("newPersona").innerHTML = `<option value="random">Random</option>` +
    (personas || []).map(p => `<option value="${p.id}">${TF.esc(p.name)}</option>`).join("");
  $("newPersona").value = "regular";
  await loadModels();
  TF.watch(render);
})();
