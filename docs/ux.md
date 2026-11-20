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

## Nudging

- Make the right action the easy one. For example, quote-reply (`q`) is one key, while linking to a message in the same topic takes a little friction, because a reply is usually what you want.
- The current place is always the most prominent thing in its list.

## The sidebar is where we innovate

Everywhere else, match Gopher Chat first. The sidebar is the exception: it should act "like a good referee", quiet until you need it and ordered by what you'll click next.

## How a UI change is checked

- Screenshot the page at desktop and phone widths (`tools/screenshot.shale`, once it exists) and look before handing back. A visual claim made without looking is a guess. Say so.
- Report sizes in px or em, so the owner can check the numbers against what he sees.
- When a choice depends on how people will behave, ask the owner rather than guess.
