// Quip buttons for Chatwoot's reply box (docs/chatwoot-plan.md, sections 8 and 9).
//
// Chatwoot loads this on every page of the agent app, through its DASHBOARD_SCRIPTS setting (desk/README.md).
// On a ticket it adds a row of buttons above the reply box: send to triage, and for the Triage team, file a
// new engineering issue (in a box holding the title the bot drafted, to edit first), attach to one, accept or
// reject the bot's match, undo, and hand back. On every page it
// adds a Handbook item to the left sidebar, opening the support team's handbook (the bot's /handbook page, which desk.quip.network proxies to the bot; it shows only to people signed in to Chatwoot).
//
// A click does what the person could do by hand, through Chatwoot's own API with their own session: it adds
// a private note (the bot reads `/eng ...` notes, and checks who wrote them) or runs one of the macros. The
// bot is never called from here and nothing leaves Chatwoot.
//
// It has to feel instant, and a call to Chatwoot's server takes about 400 ms. So:
//   - what to show is read from the copy of the ticket Chatwoot's own page already holds and keeps up to date
//     (its store). That is internal to Chatwoot, so every read falls back to the API, which is slower but public;
//   - a click never waits: the row changes at once to what the click will cause, the server is called behind
//     it, and the row is put back with a message if the call fails;
//   - the buttons are made once and only shown, hidden or relabelled, so a redraw can never swallow a click.
//
// It must never break the agent app: everything is wrapped, and a failure shows nothing. The one fragile
// part is where the row sits (the `reply-box` class). If that is gone the row floats at the top right, and
// the macros in the ticket's side panel always work without this script.
(() => {
  "use strict";
  if (window.__quipDesk) return;
  window.__quipDesk = true;

  const CFG = {
    triageTeam: "triage",
    supportTeam: "support",
    labels: { knownIssue: "known-issue", engineering: "engineering" },
    issueAttribute: "linear_issue",
    titleAttribute: "issue_title", // the title the bot drafted for a new issue (src/chatwoot/issueDraft.ts)
    maxTitle: 200,
    suggestedAttribute: "suggested_issue", // the issue behind known-issue, set by the bot's note
    answerMs: window.__quipDeskAnswerMs || 60000, // how long to wait for the bot's answer to a command before saying so
    macros: { toTriage: "Send to triage", handBack: "Hand back to mods", notAnIssue: "Not an issue" },
    minReason: 10,
    hopeMs: 10000, // how long the row shows what a click should cause before believing the server instead
    cacheMs: 300000,
    pollMs: 20000, // only used when Chatwoot's own copy of the ticket can't be read
    // The support team's handbook. The Chatwoot host proxies /handbook* to the bot, and the bot checks the
    // reader's Chatwoot sign-in cookie, so it has to be opened on this host, not on the bot's own address.
    handbookUrl: "https://desk.quip.network/handbook",
  };
  const NAV_ID = "quip-desk-handbook";
  const BAR_ID = "quip-desk-bar";
  const STYLE_ID = "quip-desk-style";
  const CSS = `
#${BAR_ID}{font:inherit;font-size:12.5px;line-height:1.3;color:inherit;padding:8px 12px;display:flex;flex-direction:column;gap:6px;border-bottom:1px solid color-mix(in srgb,currentColor 12%,transparent)}
#${BAR_ID}[hidden],#${BAR_ID} [hidden]{display:none!important}
#${BAR_ID}.quip-desk-floating{position:fixed;top:64px;right:24px;z-index:50;max-width:440px;border:1px solid color-mix(in srgb,currentColor 18%,transparent);border-radius:10px;box-shadow:0 6px 24px rgba(0,0,0,.18)}
#${BAR_ID} .quip-desk-row{display:flex;flex-wrap:wrap;gap:6px;align-items:center}
#${BAR_ID} button{font:inherit;color:inherit;background:transparent;border:1px solid color-mix(in srgb,currentColor 22%,transparent);border-radius:8px;padding:4px 10px;min-height:28px;cursor:pointer;white-space:nowrap;user-select:none;touch-action:manipulation;transition:background-color .08s ease-out,transform .05s ease-out}
#${BAR_ID} button:hover{background:color-mix(in srgb,currentColor 8%,transparent)}
#${BAR_ID} button:active{background:color-mix(in srgb,currentColor 18%,transparent);transform:translateY(1px)}
#${BAR_ID} button.quip-desk-primary{background:color-mix(in srgb,currentColor 12%,transparent);font-weight:600}
#${BAR_ID} button.quip-desk-primary:active{background:color-mix(in srgb,currentColor 22%,transparent)}
#${BAR_ID} input{font:inherit;color:inherit;background:transparent;border:1px solid color-mix(in srgb,currentColor 22%,transparent);border-radius:8px;padding:4px 10px;min-height:28px;flex:1 1 220px;min-width:0}
#${BAR_ID} button:focus-visible,#${BAR_ID} input:focus-visible,#${BAR_ID} a:focus-visible{outline:2px solid color-mix(in srgb,currentColor 55%,transparent);outline-offset:1px}
#${BAR_ID} a{color:inherit;text-decoration:underline;white-space:nowrap}
#${BAR_ID} .quip-desk-status{opacity:.8;margin-left:auto}
#${BAR_ID} .quip-desk-hint{opacity:.6}
@media (prefers-reduced-motion:reduce){#${BAR_ID} button{transition:none}#${BAR_ID} button:active{transform:none}}
`;
  const lower = (v) => String(v || "").toLowerCase();

  // --- Chatwoot's API, as the signed-in agent ---------------------------------------------------------

  /** The agent's own session, from the cookie Chatwoot's app keeps. Null when signed out. */
  function session() {
    const raw = document.cookie.split("; ").find((c) => c.startsWith("cw_d_session_info="));
    if (!raw) return null;
    try {
      const s = JSON.parse(decodeURIComponent(raw.slice(raw.indexOf("=") + 1)));
      if (!s["access-token"] || !s.client || !s.uid) return null;
      return { "access-token": s["access-token"], client: s.client, uid: s.uid, "token-type": s["token-type"] || "Bearer", expiry: String(s.expiry || "") };
    } catch {
      return null;
    }
  }

  async function api(method, path, body) {
    const headers = session();
    if (!headers) throw new Error("You're signed out of Chatwoot. Reload the page.");
    const res = await fetch(`/api/v1${path}`, {
      method,
      headers: body ? { ...headers, "content-type": "application/json" } : headers,
      body: body ? JSON.stringify(body) : undefined,
    });
    if (!res.ok) throw new Error(`Chatwoot answered ${res.status}. Check the ticket, then try again.`);
    return res.json().catch(() => null);
  }

  // --- What Chatwoot's own page already knows (instant; internal, so every read can come back empty) ----

  function store() {
    try {
      const s = document.querySelector("#app").__vue_app__.config.globalProperties.$store;
      return s && s.getters ? s : null;
    } catch {
      return null;
    }
  }

  function known(name) {
    try {
      const s = store();
      return s ? s.getters[name] : undefined;
    } catch {
      return undefined;
    }
  }

  /** The ticket on screen: from the address, or (in views whose address has no ticket) from Chatwoot's page. */
  function where() {
    const account = (location.pathname.match(/\/app\/accounts\/(\d+)/) || [])[1];
    if (!account) return null;
    let conversation = (location.pathname.match(/\/conversations\/(\d+)/) || [])[1];
    if (!conversation && document.querySelector(".reply-box")) {
      const chat = known("getSelectedChat");
      if (chat && chat.id) conversation = String(chat.id);
    }
    return conversation ? { account, conversation, key: `${account}/${conversation}` } : null;
  }

  /** An issue key from "QUI-123" or a Linear link. Null for anything else. */
  function issueFrom(text) {
    const t = String(text || "").trim();
    const link = t.match(/linear\.app\/[^\s/]+\/issue\/([A-Za-z][A-Za-z0-9]*-\d+)(?:\/([^\s/?#]+))?/);
    if (link) return { key: link[1].toUpperCase(), title: (link[2] || "").replace(/-/g, " "), url: (t.match(/https?:\/\/\S+/) || [""])[0] };
    const key = t.match(/^([A-Za-z][A-Za-z0-9]*-\d+)$/);
    return key ? { key: key[1].toUpperCase(), title: "", url: "" } : null;
  }

  /** What the row depends on, from a conversation as Chatwoot's page or its API gives it. */
  const shape = (c) => ({
    labels: c.labels || [],
    team: lower(c.meta && c.meta.team && c.meta.team.name),
    issue: issueFrom((c.custom_attributes || {})[CFG.issueAttribute]),
    title: String((c.custom_attributes || {})[CFG.titleAttribute] || "").replace(/\s+/g, " ").trim().slice(0, CFG.maxTitle),
    suggested: (issueFrom((c.custom_attributes || {})[CFG.suggestedAttribute]) || {}).key || "",
  });

  /** The ticket and whether this person is in Triage, from Chatwoot's page. Null when it can't be read. */
  function live(w) {
    const chat = known("getSelectedChat");
    const teams = known("teams/getMyTeams");
    if (!chat || String(chat.id) !== w.conversation || !Array.isArray(teams)) return null;
    return { triage: teams.some((t) => lower(t.name) === CFG.triageTeam), ticket: shape(chat) };
  }

  // --- The same from the API, for when Chatwoot's page can't be read -----------------------------------

  let who = null;
  async function me(account) {
    if (who && who.account === account && Date.now() - who.at < CFG.cacheMs) return who;
    const [profile, teams] = await Promise.all([api("GET", "/profile"), api("GET", `/accounts/${account}/teams`)]);
    const team = (teams || []).find((t) => lower(t.name) === CFG.triageTeam);
    const members = team ? (await api("GET", `/accounts/${account}/teams/${team.id}/team_members`)) || [] : [];
    who = { account, at: Date.now(), triage: members.some((m) => m.id === profile.id) };
    return who;
  }

  let fetched = null; // { key, view }
  async function fetchView(w) {
    const [person, c] = await Promise.all([me(w.account), api("GET", `/accounts/${w.account}/conversations/${w.conversation}`)]);
    fetched = { key: w.key, view: { triage: person.triage, ticket: shape(c) } };
    schedule();
  }

  // --- What the row is showing ------------------------------------------------------------------------

  let here = null; // the ticket the row is for
  let since = 0; // when it became that ticket
  let panel = null; // null, "triage", "attach" or "file"
  let status = "";
  let shown = null; // the ticket as last drawn, for what a box opens with
  let issues = null; // issues other tickets are attached to, for the attach panel
  let hope = null; // { key, team, until }: where a click is sending the ticket, shown before the server says so
  let ui = null; // the row's elements, made once
  let subscribed = false;

  /** The view with a click's expected result applied, until the server agrees or the wait runs out. */
  function hoped(w, view) {
    if (!hope || hope.key !== w.key) return view;
    if (Date.now() > hope.until || view.ticket.team === hope.team) {
      hope = null;
      return view;
    }
    return { triage: view.triage, ticket: { ...view.ticket, team: hope.team } };
  }

  let statusTimer = 0;
  /** Shows a message at the end of the row. It clears itself, unless `stay` (an action still on its way). */
  function say(message, stay) {
    status = message;
    clearTimeout(statusTimer);
    if (!stay) {
      statusTimer = setTimeout(() => {
        status = "";
        safely(draw);
      }, 9000);
    }
    draw();
  }

  // --- Doing things -----------------------------------------------------------------------------------

  const note = (w, text) => api("POST", `/accounts/${w.account}/conversations/${w.conversation}/messages`, { content: text, private: true, message_type: "outgoing" });

  let macroList = null; // { account, at, list }
  async function macroId(w, name) {
    const find = (list) => (Array.isArray(list) ? list : []).find((m) => lower(m.name) === lower(name));
    let m = find(known("macros/getMacros"));
    if (!m) {
      if (!macroList || macroList.account !== w.account || Date.now() - macroList.at > CFG.cacheMs) {
        macroList = { account: w.account, at: Date.now(), list: ((await api("GET", `/accounts/${w.account}/macros`)) || {}).payload || [] };
      }
      m = find(macroList.list);
    }
    if (!m) throw new Error(`The "${name}" macro is missing in Chatwoot. Ask an admin to add it back.`);
    return m.id;
  }

  async function macro(w, name) {
    try {
      await api("POST", `/accounts/${w.account}/macros/${await macroId(w, name)}/execute`, { conversation_ids: [Number(w.conversation)] });
    } catch (e) {
      macroList = null; // a macro that was deleted and made again has a new id
      throw e;
    }
  }

  let chain = Promise.resolve();
  const flying = new Set();
  /**
   * Starts an action without making anyone wait: the message shows at once, and the work runs behind any
   * earlier click, in order. The same action on the same ticket is ignored while it is still on its way.
   */
  function act(name, doing, work, done, undo) {
    const w = here;
    if (!w) return;
    const id = `${w.key}|${name}`;
    if (flying.has(id)) return;
    flying.add(id);
    say(doing, true);
    const still = () => here && here.key === w.key;
    chain = chain
      .then(() => work(w))
      .then(
        () => {
          if (still()) say(done);
        },
        (e) => {
          if (undo) undo();
          const why = (e && e.message) || "That didn't work. Try again.";
          say(still() ? why : `Ticket #${w.conversation}: ${why}`);
        },
      )
      .then(() => {
        flying.delete(id);
        if (!live(w)) for (const ms of [1500, 5000]) setTimeout(() => safely(() => still() && fetchView(w)), ms);
        schedule();
      });
  }

  const command = (text) =>
    act(
      text,
      "Sending to the bot\u2026",
      async (w) => {
        const sent = await note(w, text);
        if (sent && sent.id) setTimeout(() => safely(() => checkAnswer(w, sent.id)), CFG.answerMs);
      },
      "Sent to the bot. Its answer appears as a note.",
    );

  /** The bot answers a command with a note ending "(ref <id>)". None after a minute: say so, if still on the ticket. */
  async function checkAnswer(w, id) {
    const r = await api("GET", `/accounts/${w.account}/conversations/${w.conversation}/messages`);
    const list = (r && (Array.isArray(r) ? r : r.payload)) || [];
    if (list.some((m) => [`(ref ${id})`, `(command ${id})`].some((ref) => String(m.content || "").includes(ref)))) return;
    if (here && here.key === w.key) say("No answer from the bot yet. Try again in a minute, or tell the admin.");
  }

  /** Moves the ticket with a macro, showing it in its new team at once. */
  function move(name, team, doing, done, before) {
    const w = here;
    if (!w) return;
    hope = { key: w.key, team, until: Date.now() + CFG.hopeMs };
    setTimeout(schedule, CFG.hopeMs + 50);
    panel = null;
    act(
      name,
      doing,
      (t) => Promise.all([before ? before(t) : null, macro(t, name)]),
      done,
      () => {
        if (hope && hope.key === w.key) hope = null;
      },
    );
  }

  /** Files a new issue with the title in the box. Left empty, the bot uses the title it drafted. */
  function fileNew(text) {
    const title = String(text || "").replace(/\s+/g, " ").trim().slice(0, CFG.maxTitle);
    panel = null;
    command(title ? `/eng new ${title}` : "/eng new");
  }

  function sendToTriage(reason) {
    const why = reason.trim().replace(/\s+/g, " ");
    if (why.length < CFG.minReason) return say("Say why first: what you tried, and what you think is wrong.");
    move(CFG.macros.toTriage, CFG.triageTeam, "Sending to triage\u2026", "Sent to triage.", (w) => note(w, `Sent to triage: ${why}`));
  }

  function attach(text) {
    const issue = issueFrom(text);
    if (!issue) return say("Enter an issue key, or paste a Linear link.");
    panel = null;
    command(`/eng ${issue.key}`);
  }

  /** Issues that tickets are already attached to, most tickets first: what a new ticket most often joins. */
  async function loadIssues() {
    const w = here;
    const found = new Map();
    try {
      for (let page = 1; page <= 3; page++) {
        const r = await api("GET", `/accounts/${w.account}/conversations?labels[]=${encodeURIComponent(CFG.labels.engineering)}&status=all&page=${page}`);
        const list = (r && r.data && r.data.payload) || [];
        for (const c of list) {
          const issue = issueFrom((c.custom_attributes || {})[CFG.issueAttribute]);
          if (!issue) continue;
          const row = found.get(issue.key) || { key: issue.key, title: issue.title, tickets: 0 };
          row.tickets++;
          found.set(issue.key, row);
        }
        if (list.length < 25) break;
      }
    } catch {
      // The list is a convenience: the box above it still takes any key.
    }
    if (!here || here.key !== w.key) return;
    issues = [...found.values()].sort((a, b) => b.tickets - a.tickets).slice(0, 8);
    draw();
  }

  /** Opens a box (or closes it, if it's open). The new-issue box starts with the title the bot drafted. */
  function open(which) {
    if (panel !== which && ui) {
      ui.input.value = which === "file" && shown ? shown.title : "";
      ui.touched = false;
    }
    panel = panel === which ? null : which;
    status = "";
    if (panel === "attach" && !issues) safely(loadIssues);
    draw();
    if (panel && ui) ui.input.focus();
  }

  // An untouched new-issue box sends a bare /eng new: the bot then uses its newest draft, not the title shown when
  // the box opened.
  const submit = () => (panel === "triage" ? sendToTriage(ui.input.value) : panel === "file" ? fileNew(ui.touched ? ui.input.value : "") : attach(ui.input.value));

  // --- Drawing ----------------------------------------------------------------------------------------

  function el(tag, attrs, text) {
    const node = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) if (v !== null && v !== undefined && v !== "") node.setAttribute(k, v);
    if (text) node.textContent = text;
    return node;
  }

  function button(label, onClick, cls) {
    const b = el("button", { type: "button", class: cls || "" }, label);
    b.addEventListener("click", (e) => {
      e.preventDefault();
      safely(onClick);
    });
    return b;
  }

  const show = (node, on) => {
    if (node.hidden === Boolean(on)) node.hidden = !on;
  };
  const text = (node, value) => {
    if (node.textContent !== value) node.textContent = value;
  };

  /** Makes the row once. After this its buttons are only shown, hidden or relabelled, never replaced. */
  function build() {
    const b = {
      triage: button("Send to triage", () => open("triage")),
      fileNew: button("File new issue", () => open("file")),
      attach: button("Attach to issue\u2026", () => open("attach")),
      // With the issue the row shows, so the bot attaches exactly that one.
      accept: button("Accept suggestion", () => command(shown && shown.suggested ? `/eng accept ${shown.suggested}` : "/eng accept")),
      reject: button("Not the same", () => command("/eng no")),
      undo: button("Undo link", () => command("/eng undo")),
      back: button("Hand back to mods", () => move(CFG.macros.handBack, CFG.supportTeam, "Handing back\u2026", "Handed back to the mods.")),
      notIssue: button("Not an issue", () => move(CFG.macros.notAnIssue, CFG.supportTeam, "Marking not an issue\u2026", "Marked not an issue.")),
    };
    const bar = el("div", { id: BAR_ID, role: "group", "aria-label": "Quip ticket actions" });
    const row = el("div", { class: "quip-desk-row" });
    const link = el("a", { target: "_blank", rel: "noopener noreferrer" });
    const statusEl = el("span", { class: "quip-desk-status", role: "status", "aria-live": "polite" });
    row.append(...Object.values(b), link, statusEl);

    const form = el("div", { class: "quip-desk-row" });
    const input = el("input", { type: "text", maxlength: "500" });
    input.addEventListener("input", () => {
      if (ui) ui.touched = true;
    });
    // Keys stay out of Chatwoot's own shortcuts. Enter sends, Escape closes.
    input.addEventListener("keydown", (e) => {
      e.stopPropagation();
      if (e.key === "Enter") {
        e.preventDefault();
        safely(submit);
      } else if (e.key === "Escape") {
        panel = null;
        safely(draw);
      }
    });
    const send = button("", submit, "quip-desk-primary");
    form.append(input, send, button("Cancel", () => open(panel)));
    const list = el("div", { class: "quip-desk-row" });
    bar.append(row, form, list);
    return { bar, b, link, status: statusEl, form, input, send, list, listFor: "", touched: false };
  }

  /** A Handbook item in the left sidebar, after Help Center, styled like Chatwoot's own items. It opens in a
   *  new tab. If the sidebar has changed so Help Center can't be found, nothing is added. */
  function sidebarLink() {
    if (document.getElementById(NAV_ID)) return;
    const help = [...document.querySelectorAll("aside a")].find((a) => a.textContent.trim().startsWith("Help Center"));
    const item = help && help.closest("li");
    if (!item || !item.parentElement) return;
    const li = document.createElement("li");
    li.id = NAV_ID;
    li.className = item.className;
    const a = document.createElement("a");
    a.className = help.className;
    a.href = CFG.handbookUrl;
    a.target = "_blank";
    a.rel = "noopener";
    a.title = "Support handbook: training videos and rules";
    a.innerHTML =
      '<div class="relative flex items-center gap-2"><svg class="size-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M2 3h6a4 4 0 0 1 4 4v14a3 3 0 0 0-3-3H2z"/><path d="M22 3h-6a4 4 0 0 0-4 4v14a3 3 0 0 1 3-3h7z"/></svg></div>' +
      '<div class="flex items-center gap-1.5 flex-grow justify-between min-w-0 flex-1"><span class="truncate text-body-main">Handbook</span></div>';
    li.append(a);
    item.after(li);
  }

  /** An issue's title for a picker button: whole up to 60 characters, else cut at a word with "...". */
  function shortTitle(t) {
    if (t.length <= 60) return t;
    const cut = t.lastIndexOf(" ", 57);
    return `${t.slice(0, cut > 30 ? cut : 57)}...`;
  }

  const COMMAND_NOTE = /^\/eng(\s+new\s+.+|\s+accept\s+\S+|\s+\S+)?$/;
  // The bot's answer to a command ends "(ref <the command's message id>)". Its ticket note's ref has a dash in it.
  const ANSWER_REF = /\((?:ref|command) (\d+)\)\s*$/;

  /**
   * The buttons work by leaving a "/eng ..." private note for the bot, which answers with a note saying what it
   * did ("Triage: filed CLT-4 ..."). Once answered, the command note means nothing to whoever reads the ticket
   * later, so it's hidden. One the bot hasn't answered stays in view, so a lost command can be seen. Which command
   * an answer belongs to comes from its ref, the command's message id, read from Chatwoot's own copy of the
   * messages; the command notes on screen are matched to those in order, newest last. Without that copy nothing is
   * hidden. Only private notes whose whole text is one /eng command are hidden: one word after /eng, /eng accept
   * and an issue key, or /eng new and a title on one line.
   */
  function hideCommands() {
    const rows = [];
    for (const row of document.querySelectorAll(".conversation-panel > *")) {
      const bubble = row.querySelector(".prose-bubble");
      const note = row.querySelector("[class*='amber']");
      if (bubble && note && COMMAND_NOTE.test(bubble.textContent.trim())) rows.push(row);
    }
    if (!rows.length) return;
    const chat = known("getSelectedChat");
    const messages = chat && Array.isArray(chat.messages) ? chat.messages : null;
    const answered = new Set();
    const commands = [];
    for (const m of messages || []) {
      const text = String(m.content || "").trim();
      const ref = text.match(ANSWER_REF);
      if (ref) answered.add(Number(ref[1]));
      if (m.private && COMMAND_NOTE.test(text)) commands.push(m);
    }
    commands.sort((a, b) => a.id - b.id);
    const offset = commands.length - rows.length;
    rows.forEach((row, i) => {
      const m = messages ? commands[i + offset] : null;
      const hide = Boolean(m && answered.has(m.id));
      if (hide && !row.dataset.quipCommand) {
        row.dataset.quipCommand = "1";
        row.style.display = "none";
      } else if (!hide && row.dataset.quipCommand) {
        delete row.dataset.quipCommand;
        row.style.display = "";
      }
    });
  }

  function draw() {
    safely(sidebarLink);
    safely(hideCommands);
    const w = where();
    if ((w && w.key) !== (here && here.key)) {
      here = w;
      since = Date.now();
      panel = null;
      status = "";
      issues = null;
      fetched = null;
      if (ui) ui.input.value = "";
      if (w) {
        if (!live(w)) safely(() => fetchView(w));
        setTimeout(schedule, 1600);
        // Off the click path: so "Send to triage" doesn't have to look the macro up first.
        safely(() => macroId(w, CFG.macros.toTriage));
      }
    }
    if (!subscribed) {
      const s = store();
      if (s && typeof s.subscribe === "function") {
        subscribed = true;
        s.subscribe(schedule);
      }
    }
    const base = w && (live(w) || (fetched && fetched.key === w.key ? fetched.view : null));
    if (!base) {
      if (ui) ui.bar.remove();
      return;
    }
    const view = hoped(w, base);
    const box = document.querySelector(".reply-box");
    // No reply box yet: wait a moment for the page before falling back to the floating row.
    if (!box && Date.now() - since < 1500) {
      if (ui) ui.bar.remove();
      return;
    }
    if (!ui) ui = build();

    const t = view.ticket;
    const inTriage = t.team === CFG.triageTeam;
    // Linked means the bot's own record on the ticket, not a label someone can add by hand.
    const linked = Boolean(t.issue);
    const matched = t.labels.includes(CFG.labels.knownIssue);
    if ((panel === "triage" && inTriage) || ((panel === "attach" || panel === "file") && (!view.triage || linked))) panel = null;
    shown = t;

    show(ui.b.triage, !inTriage);
    show(ui.b.fileNew, view.triage && !linked);
    show(ui.b.attach, view.triage && !linked);
    show(ui.b.accept, view.triage && matched);
    text(ui.b.accept, t.suggested ? `Accept ${t.suggested}` : "Accept suggestion");
    show(ui.b.reject, view.triage && matched);
    show(ui.b.undo, view.triage && linked);
    show(ui.b.back, view.triage && inTriage);
    show(ui.b.notIssue, view.triage && inTriage);
    const url = (t.issue && t.issue.url) || "";
    show(ui.link, Boolean(url));
    if (url && ui.link.getAttribute("href") !== url) ui.link.setAttribute("href", url);
    text(ui.link, url ? `${t.issue.key} \u2197` : "");
    text(ui.status, status);

    show(ui.form, Boolean(panel));
    if (panel) {
      const hint = {
        triage: "Why? What you tried, and what you think is wrong",
        attach: "Issue key or Linear link",
        file: "Issue title (leave empty and the bot writes one)",
      }[panel];
      if (ui.input.getAttribute("placeholder") !== hint) {
        ui.input.setAttribute("placeholder", hint);
        ui.input.setAttribute("aria-label", hint);
      }
      const max = String(panel === "file" ? CFG.maxTitle : 500);
      if (ui.input.getAttribute("maxlength") !== max) ui.input.setAttribute("maxlength", max);
      // The bot's title arrived while the box was open and nobody has typed yet: put it in.
      if (panel === "file" && t.title && !ui.touched && !ui.input.value) ui.input.value = t.title;
      text(ui.send, { triage: "Send to triage", attach: "Attach", file: "File" }[panel]);
    }
    show(ui.list, panel === "attach");
    const listFor = panel === "attach" ? JSON.stringify(issues) : "";
    if (panel === "attach" && ui.listFor !== listFor) {
      ui.listFor = listFor;
      ui.list.replaceChildren();
      if (!issues) ui.list.append(el("span", { class: "quip-desk-hint" }, "Looking up issues with tickets attached\u2026"));
      else if (!issues.length) ui.list.append(el("span", { class: "quip-desk-hint" }, "No tickets are attached to an issue yet."));
      else {
        for (const k of issues) {
          ui.list.append(
            button(`${k.key}${k.title ? ` \u00b7 ${shortTitle(k.title)}` : ""} (${k.tickets})`, () => {
              panel = null;
              command(`/eng ${k.key}`);
            }),
          );
        }
      }
    }

    show(ui.bar, Object.values(ui.b).some((x) => !x.hidden) || Boolean(url));
    ui.bar.classList.toggle("quip-desk-floating", !box);
    const paint = box ? "" : getComputedStyle(document.body).backgroundColor;
    if (ui.bar.style.background !== paint) ui.bar.style.background = paint;
    const home = box || document.body;
    if (ui.bar.parentElement !== home || !ui.bar.isConnected) {
      if (box) box.prepend(ui.bar);
      else document.body.append(ui.bar);
    }
  }

  // --- Running ----------------------------------------------------------------------------------------

  function safely(fn) {
    try {
      const out = fn();
      if (out && typeof out.catch === "function") out.catch(() => {});
    } catch {
      // Never let these buttons break the agent app.
    }
  }

  let queued = false;
  /** Redraws soon, once, however many things changed. Clicks redraw at once instead. */
  function schedule() {
    if (queued) return;
    queued = true;
    setTimeout(() => {
      queued = false;
      safely(draw);
    }, 30);
  }

  safely(() => {
    if (!document.getElementById(STYLE_ID)) document.head.append(el("style", { id: STYLE_ID }, CSS));
    new MutationObserver(schedule).observe(document.documentElement, { childList: true, subtree: true });
    setInterval(() => {
      if (!document.hidden && here && !live(here)) safely(() => fetchView(here));
    }, CFG.pollMs);
    draw();
  });
})();
