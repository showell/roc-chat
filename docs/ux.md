# roc-chat's UX: the rules and the reasons

This is for anyone changing a page. `design.md` holds the owner's decisions; this file holds the habits behind the UI, so that a change can follow the reasoning and not just the letter of a past request.

## The bar

"Chat is simple, but all the micro decisions for UX distinguish a professional system from a system that looks like it's still a prototype. A well-written UX maximizes real estate and respects that the user is busy while nudging them toward the right actions." (Steve, 2026-11-20)

## Who we design for

- **Mostly desktop,** with phones for catching up. A phone must work well, but desktop decides the layout.
- **Power users use the keyboard,** and everyone uses the mouse. Every keyboard action needs a visible, clickable way too. A feature that only a key reaches is half-built. Some features don't fit a phone (citing, for one), and that's fine when it's deliberate.
- **Most people talk to one or two others.** DMs are a major source of clutter. Until there is a buddy system, infer from behavior what to show, and err on less clutter even when it costs a click.

## Real estate

- Chrome is economical: status lines, bars and headers get thin padding. Space goes between groups, not inside thin bars.
- Collapsing is the answer to "too much to show", not shrinking. Once a section can collapse, it's fine for it to run below the fold.
- Inputs in the sidebar itself are clutter. A popup is roomy, so put the action (a field, a button) right in the popup. A popup never opens another popup.
- A popup also shows where you can go next (e.g. the place's topics under the new-topic form). It trains people that they may explore; nothing has to be reached one way only.
- A popup's buttons are one family with the compose box's: the primary action in the accent, the rest quiet, each with a hover and a visible keyboard focus. Opening a popup puts the focus where the most common task starts.

## Nudging

- Make the right action the easy one. For example, quote-reply (`q`) is one key, while linking to a message in the same topic takes a little friction, because a reply is usually what you want.
- The current place is always the most prominent thing in its list.

## Consistency teaches

- Treat the same kind of thing the same way everywhere, the viewer included. Your own row gets a presence dot like everyone else's, always green: "This is how we teach people how presence works! You see green for Steve." (Steve, 2026-11-20)
- In the sidebar, each kind of row does one thing and has its own hover look: a triangle or a group heading collapses, a name opens its card in the centre, and a topic opens its page.
- Lists with no natural order are alphabetical, such as the keyboard help's letter keys, and a key's mnemonic shows in its words ("l: link to this message").
- A message to yourself behaves like a message from anyone else: it notifies, as Zulip's did. It's how people test the chat on their own.

## Actions look like actions

Quiet styling (small, muted) is for metadata such as times and ids. Anything a reader acts on looks clickable: the citation link was once 11px and muted, and it "looked like filler" (Steve, 2026-11-20).

## Single pages

A page with one job (Recent, Add a device) is centred. Its action area gives imperative steps in the order the reader does them ("On your phone, open …" before "Make a code"), with no status clutter or raw timestamps there.

## Notifications

Never hide a notification without the owner's yes. A message from someone else on the topic you're reading must still turn the tab violet: "I need to know when Bob talks to me when I'm already talking to Bob!" (Steve, 2026-11-20). Match Gopher's notify behaviour first.

## The sidebar is where we innovate

Everywhere else, match Gopher Chat first. The sidebar is the exception: it should act "like a good referee", quiet until you need it and ordered by what you'll click next.

## How a UI change is checked

- Screenshot the page at desktop and phone widths and look before handing back: `shale tools/screenshot.shale out=build:shots/<name>` writes PNGs of the main pages in both themes, and of what a click or a key opens (the person card, a selected message, the compose rail, emoji autocomplete). Its header lists them; a new state is a few steps (click, key, type, wait) in its STATES list. Claude's Read tool shows a PNG. A visual claim made without looking is a guess. Say so.
- Report sizes in px or em, so the owner can check the numbers against what he sees.
- When a choice depends on how people will behave, ask the owner rather than guess.
