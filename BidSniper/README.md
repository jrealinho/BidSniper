# BidSniper

Finds auctions where the bid is far below the buyout — the 1 silver bid /
15 gold buyout kind — and helps you act on them quickly.

For **World of Warcraft 3.3.5a** (Wrath of the Lich King, tested on Warmane).

---

## Install

Drop the `BidSniper` folder into `Interface\AddOns\`, so you end up with:

```
Interface/AddOns/BidSniper/BidSniper.toc
Interface/AddOns/BidSniper/BidSniper.lua
Interface/AddOns/BidSniper/BidSniperUI.lua
```

> ### ⚠️ The WoW folder must not be read-only
>
> **Do not extract into a read-only folder, and clear the read-only flag on the
> addon folder if Windows set one.** Right-click the folder → *Properties* →
> untick **Read-only** → *Apply* → *Apply to all subfolders*.
>
> This bites hardest on portable "no install" copies of WoW under
> `C:\Program Files`, where Windows blocks writes silently.
>
> Everything BidSniper remembers — your scan results, wishlist, categories,
> settings, resume point and price cache — is written by WoW to
> `WTF\Account\<ACCOUNT>\SavedVariables\BidSniper.lua` when you log out or
> `/reload`. If that path is not writable **the save fails silently**: the
> addon works perfectly all session and then comes back blank every time,
> with no error to explain why.
>
> A quick check: change a filter, `/reload`, and see whether it stuck.

Optional: [Auctionator](https://github.com/Auctionator/Auctionator) fills in
the **Market** and **Profit** columns. Everything else works without it.

---

## Quick start

1. Open the auction house — the window opens with it.
2. Press **Scan AH**.
3. Sort by **Profit** and work down the list.

| Column | Meaning |
| --- | --- |
| Bid | What it costs you to be high bidder right now |
| Buyout | The seller's buyout price |
| Ratio | Buyout ÷ bid — how good it *looks* |
| Market | What the stack is actually worth |
| Profit | Market − bid — what you actually stand to make |
| Left | Time left, or `stale` / `gone` |
| Seller | Who posted it |

---

## Row actions

| Action | Result |
| --- | --- |
| Click | Bid, with a confirmation showing the exact amount |
| Ctrl-click | Load it onto the **BID** button, ready for one press |
| Right-click | Search that item in the normal Browse tab |
| Shift-click | Link the item into chat |
| Tick box | Select it for a batch |
| Drag down the tick boxes | Paint the same state onto every row you cross |
| Shift-click a tick box | Select the whole range back to the last one you ticked |

Range select works across scrolling: tick row 3, scroll down, shift-tick row
200, and everything between takes that state. Dragging is for quick local
adjustments — it covers the rows currently on screen.

Both refuse to *tick* rows already bid on or marked `gone`, but will always
untick anything.

---

## Bidding in bulk

**Select all** ticks everything and flips to **Select none**; untick what you
don't want. The line above the buttons keeps a running count and total, so you
see the damage before committing.

**Bid selected** then works through them **one click per auction** — see
[Why bidding needs a click](#why-bidding-needs-a-click). Press it once to
approve the count and total; from then on the button reads `BID 1s 20c` and
each press bids that auction and lines up the next, so you keep clicking the
same spot.

* **Skip** passes on the current auction, unticks it, and moves on. It also
  cancels a lookup that's dragging, so one awkward item can't hold up the queue.
* **Stop batch** ends the run.
* Auctions are grouped by item, so a run of the same item reuses one set of
  results and those presses come back instantly.

It skips anything whose bid rose since the scan, stops if you run out of gold,
and stops if the running total would pass what you approved. A green `*` marks
rows already bid on; a yellow `?` means sent but not yet confirmed.

### Re-bid

**Re-bid** asks the server which of your bids have been beaten and queues them
all. No scan needed — it reads your live bid list, so it covers bids placed by
any means. Open the Bids tab first and it needs no server round trip at all.

Auctions that climbed past your **Max bid**, or past their own buyout, are left
alone and reported.

---

## Filters

| Filter | Meaning |
| --- | --- |
| **Min ratio** | How many times bigger the buyout must be than the bid |
| **Max bid** | Ignore anything costing more than this to bid on. `0` = no limit |
| **Min buyout** | Ignore junk below this buyout |
| **Min quality** | Click to step up, right-click to step back |
| **Categories** | Limit the scan to chosen categories and subcategories |
| **Only unbid** | Only auctions nobody has bid on |
| **Ending < 2h** | Only Short and Medium time left |
| **Hide mine** | Skip auctions from any of your characters, and ones you're winning |

Money boxes accept `50`, `50g`, `1s50c` — a plain number means gold.

Defaults are ratio `10x`, max bid `50g`, min buyout `1g`.

---

## Categories

The **Categories** button opens a panel listing every auction house category.
Tick as many as you like — each is scanned in turn, which is far quicker than
reading the whole house. Tick none to scan everything.

Categories with subcategories have a `[+]` beside them. Open one and you can
tick individual subcategories instead — *Trade Goods → Herb*, say, rather than
all of Trade Goods. A category showing `(3)` has three subcategories picked.

The two are mutually exclusive per category, which keeps the meaning clear:

* Ticking a **category** clears any subcategory picks under it — you want all
  of it.
* Ticking a **subcategory** unticks the parent — you want only those parts.

**Tick all** selects every category, **Clear** goes back to scanning
everything. The list comes from the auction house itself, so open one once
before the panel can offer anything.

## Wishlist

For items you check often. Press **Wishlist**, then type a name or
shift-click an item into the box and press **Add**. Entries stay sorted and
saved; the `X` removes one.

**Scan wishlist** searches each item in turn with the same filters. It ignores
the Category setting — the list already says what to look for. This is the
fastest scan available.

---

## Scan methods

**GetAll** pulls the entire auction house in one request and takes seconds.
The client permits it once every 15 minutes.

**Page by page** asks the server to sort by current bid, cheapest first, and
stops once bids pass your **Max bid** — everything beyond is too expensive to
qualify. The lower your Max bid, the shorter the scan.

`auto` (the default) uses GetAll when it can and falls back to paging.

**Categories do not cost you GetAll.** The dump arrives unfiltered, so the
categories are applied to the results instead — a filtered scan is just as fast
as an unfiltered one. Occasionally an item is not in your client's cache and
can't be classified; those are kept rather than dropped, and counted at the end.

GetAll is only skipped when resuming, on a wishlist scan, or when the method is
forced to `paged`. Run `/snipe debug` and it will tell you which mode the next
scan uses and, if it's paging, exactly why.

> Don't run Auctionator's or TSM's scanners at the same time — they share the
> same query channel.

### Stopping and resuming

If a scan is interrupted — Stop, closing the auction house, or the server going
quiet — the position is kept along with everything found, and a **Resume**
button appears next to Scan AH showing the page it reached.

**Scan AH always starts a complete new scan.** Resuming is never forced on you;
it is the extra button, and it disappears once there is nothing to resume.

This survives `/reload` and relogging. It's a page number, not a bookmark on
particular auctions, so after a long gap a fresh scan is the honest choice.
A GetAll scan has no halfway point, so a resumed scan always continues paged.

---

## Market and Profit

A huge buyout is not proof an item is worth anything — anyone can list junk at
100g and the ratio will look wonderful. **Profit** is the honest check.

Profit shows **`?`** when there's no price on record. That is *not* the same as
a bad deal, and it's the case to be most careful with: nothing is known about
the item, so the buyout tells you nothing. Treat `?` as "find out first".

Sorting by Profit puts the best deals on top and unpriced items at the bottom.
The tooltip also shows profit after the 5% auction house cut.

Prices are cached for a day so the column fills instantly on load; unknown
prices are retried after ten minutes. `/snipe prices` forces a rebuild.

---

## Auctions that have moved on

A saved scan is a photograph, and the auction house keeps changing. Every
result records when it was seen and the time left it had, which together bound
how long it could still be running.

* **`gone`** — past that point: sold, bought out, or cancelled. Greyed out and
  never picked up by Select all. Dropped at login, with a count.
* **`stale`** — more than halfway through. Treat with suspicion.

None of this replaces the real check: **a bid always re-reads the auction from
the server immediately before spending, and refuses if anything changed.**

---

## Why bidding needs a click

`PlaceAuctionBid` is a protected function. WoW only honours it while handling a
real mouse click or key press. Called from a timer or an event handler the
client silently drops it and prints *"Interface action failed because of an
AddOn"* — and the call reports no error, so an addon cannot even tell that
nothing happened.

**No addon can bid through a list unattended, on any client.** What an addon
can do is everything around the bid: find the auctions, work out the price, and
have the next one ready the instant you click. That is what the BID button is.

---

## Commands

| Command | Does |
| --- | --- |
| `/snipe` | Toggle the window (`/bidsniper` also works) |
| `/snipe scan` | Start a complete new scan |
| `/snipe resume` | Carry on from where a scan was interrupted |
| `/snipe auto` \| `paged` \| `getall` | Choose the scan method |
| `/snipe bids` | Ask the server what you've actually bid on |
| `/snipe syncbids` | Rebuild the "already bid" marks from the server |
| `/snipe clearmarks` | Drop every "already bid" mark |
| `/snipe prices` | Forget cached prices and rebuild Profit |
| `/snipe debug` | Scan method, saved results, why GetAll is or isn't used |
| `/snipe layout` | Print where the filter boxes actually are |
| `/snipe try <n>` | Test-bid row *n* of the Browse list, showing every input |
| `/snipe reset` | Restore defaults and reload |

---

## Saved data

Everything lives in `BidSniperDB` — settings, wishlist, categories, results,
resume point, price cache, and the list of your characters. Results persist
across reloads and relogs, so a scan is never lost to a UI reload.

Two things to know:

* WoW only writes saved variables on a clean `/reload`, logout or exit. A crash
  or alt-F4 loses whatever changed since the last write.
* The folder must be writable — see the warning under [Install](#install).
