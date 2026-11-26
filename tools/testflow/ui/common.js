// TestFlow — shared by the clone and the Lab. Both are views of the server's state.
const TF = {
  async post(path, body) {
    try {
      const r = await fetch(path, { method: "POST", headers: { "Content-Type": "application/json" },
                                   body: JSON.stringify(body || {}) });
      return await r.json();
    } catch (e) { return { error: String(e) }; }
  },
  async get(path) {
    try { return await (await fetch(path)).json(); } catch (e) { return { error: String(e) }; }
  },
  // Long-poll: the server answers at once when the version moved, else after ~8 s.
  watch(onState) {
    let version = 0;
    const loop = async () => {
      for (;;) {
        try {
          const s = await (await fetch("/api/state?since=" + version)).json();
          if (s.version !== version) { version = s.version; onState(s); }
        } catch (e) { await new Promise(r => setTimeout(r, 1000)); }
      }
    };
    loop();
  },
  time(ts) {
    const d = new Date(ts * 1000);
    let h = d.getHours(), m = String(d.getMinutes()).padStart(2, "0");
    const ap = h >= 12 ? "pm" : "am"; h = h % 12 || 12;
    return `${h}:${m} ${ap}`;
  },
  esc(s) {
    return String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  },
  initials(name) {
    const w = String(name || "?").replace(/[^A-Za-z ]/g, "").trim();
    return (w.slice(0, 1).toUpperCase() + w.slice(1, 2).toLowerCase()) || "?";
  },
  activeChat(s) { return s.chats[s.active] || Object.values(s.chats)[0]; },

  // THE rating scale (2026-10-16). One meaning per number, shown wherever you
  // rate, so a 6 today means what a 6 meant last week. export.py's thresholds
  // (8 = good enough to imitate, 7 = good enough to prefer) depend on it.
  SCALE: {
    her: ["", "Harmful: loses the fan or breaks a rule (meet-up, admits AI, rude)",
          "Obvious bot: no human would send this",
          "Wrong: wrong move, or ignores what he said",
          "Weak: right idea, wrong execution; needs a rewrite",
          "Sendable only after real edits",
          "Sendable after small edits",
          "Fine: would send as is",
          "Good: on voice, right move",
          "Great: better than a typical chatter",
          "Perfect: exactly what you'd send, or better"],
    fan: ["", "Impossible: no fan would ever write this",
          "Obviously AI",
          "Out of character for his persona",
          "Unlikely for a real fan",
          "Possible, but stiff",
          "Plausible",
          "Realistic",
          "Very realistic",
          "Could be a real fan",
          "A real fan, exactly"],
    convo: ["", "Disaster: lost him or did damage",
            "Bad throughout",
            "Mostly wrong moves",
            "Weak: a few good moments",
            "Average: kept him, nothing more",
            "Decent",
            "Good: you'd be fine with this",
            "Very good: well led, well paced",
            "Great: better than a typical chatter",
            "Perfect: how you'd run it yourself"],
  },
  TAGS: {
    her: ["too long", "too short", "robotic", "narrates", "ignored him", "wrong move",
          "too explicit", "too salesy", "no question", "pet name", "off voice", "repetitive", "good"],
    fan: ["unrealistic", "too eager", "too long", "too articulate", "out of persona",
          "too easy to sell", "repetitive", "good"],
  },
  OUTCOMES: ["bought", "would have bought", "still interested", "finished happy",
             "got bored / ghosted", "got annoyed or mad", "asked if she's real", "other"],
};
