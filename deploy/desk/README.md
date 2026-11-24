# Quip buttons in Chatwoot's reply box

`quip-desk.js` adds a row of buttons above the reply box on every ticket, so nobody has to open the
Macros panel or type a `/eng` command. It also adds a **Handbook** item to Chatwoot's left sidebar, under Help
Center, which opens the support team's handbook (the bot's `/handbook` page, from `docs/handbook/handbook.md`) in a
new tab. Its address is `handbookUrl` in `CFG`: `https://desk.quip.network/handbook`. A reverse-proxy rule on the
Chatwoot host sends `desk.quip.network/handbook*` to the bot, which shows the page only to people signed in to our
Chatwoot account (it checks their Chatwoot session cookie). The bot's old `/team` address redirects there.

| Who | Buttons |
| --- | --- |
| Everyone | **Send to triage** (asks why, leaves that as a private note, then moves the ticket) |
| Triage team | **File new issue** (opens a box with the title the bot drafted, to edit and then **File**), **Attach to issue…** (type a key, paste a Linear link, or pick an issue other tickets are attached to) |
| Triage, on a ticket with the `known-issue` label | **Accept suggestion**, **Not the same** |
| Triage, on an attached ticket | **Undo link**, and a link to the Linear issue |
| Triage, on a ticket in the Triage queue | **Hand back to mods**, **Not an issue** |

A click does what the person could do by hand, through Chatwoot's own API with their own session. The
engineering buttons add a private note (`/eng new <title>`, `/eng QUI-123` and so on) and the bot acts on it, after
checking that the person who wrote the note is in the Triage team. The other three run the macros of the
same name. The script never calls the bot, and nothing leaves Chatwoot.

## Why it reacts at once

A call to Chatwoot's server takes about 400 ms from a browser (measured 2026-11-17), so the row never
waits for one:

- What to show comes from the copy of the ticket that Chatwoot's own page already holds and keeps up to
  date. The row appears with the ticket, and follows it when the bot changes a label, with no call at all.
- A click changes the row straight away to what the click will cause, and the server is called behind it.
  If the server refuses, the row goes back and says why.
- The buttons are made once and only shown, hidden or relabelled, so a redraw can't swallow a click.
- A second click on the same button while the first is still on its way is ignored, so nothing is sent twice.

Measured on the live Chatwoot: the row changed 0 to 1 ms after a click, and the server confirmed about
half a second later.

## Installing it (Keith)

Chatwoot has an installation setting, `DASHBOARD_SCRIPTS`, whose contents are added to the end of every page
of the agent app (checked in the v4.19.1 and v4.20.1 source: `dashboard_controller.rb` and `layouts/vueapp.html.erb`).

- Set `DASHBOARD_SCRIPTS` to the contents of `quip-desk.js`, wrapped in a `<script>` tag.
- The screen that edits this setting is in Chatwoot's Enterprise code, so on our community edition it has
  to be set in the database or from the Rails console.
- Chatwoot caches installation settings, so the cache needs clearing (or the app restarting) before it shows.
- To update the buttons, set it again. To remove them, empty the setting.

Paste the file itself. Don't point the setting at a URL: whatever loads there runs inside every agent's
signed-in session, so it should only ever change when someone with access to Chatwoot's server changes it.

## What it depends on

| In Chatwoot | Used for |
| --- | --- |
| The `reply-box` class on the reply box | Where the row sits. If it's missing, the row floats at the top right instead |
| The page's own copy of the ticket, teams and macros (its store) | Showing the row at once. If it can't be read, the row asks the API instead: the same buttons, about half a second later |
| A team named `triage` | Who sees the engineering buttons |
| A **Help Center** item in the left sidebar | Where the Handbook item goes. If it's missing, no Handbook item is added |
| Macros named **Send to triage**, **Hand back to mods**, **Not an issue** | The three buttons that move a ticket |
| The `known-issue` label and the `linear_issue` ticket attribute | Which buttons a ticket shows. A ticket counts as attached only by the attribute, not the `engineering` label |
| The `suggested_issue` ticket attribute | The issue the Accept button names and sends. If it's missing, the button says Accept suggestion and the bot uses its latest match |
| The `issue_title` ticket attribute | The title the File new issue box starts with. If it's missing, the box starts empty and the bot writes the title |

These names are at the top of the file, in `CFG`.

## After a Chatwoot upgrade

Open a ticket and check the row is above the reply box. If it's floating at the top right, Chatwoot has
changed the reply box: update the `.reply-box` selector in `quip-desk.js`. If there's no row at all, the
session cookie or the API changed. Either way the macros in the ticket's side panel still work, and so do
typed `/eng` commands.

## Tests

`npx vitest run test/deskButtons.test.ts` runs the script in headless Chromium against a stand-in for
Chatwoot's page and API, both with and without the page's own copy of the ticket. It was also tried on the
live Chatwoot on 2026-11-17 (ticket #13: Send to triage with a reason, then Hand back to mods).
