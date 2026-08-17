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
Interface/AddOns/BidSniper/BidSniperLedger.lua
Interface/AddOns/BidSniper/BidSniperUI.lua
```

> ### Upgrading? Restart the client, don't `/reload`
>
> WoW reads an addon's file list from the `.toc` **once, when the client
> starts**. `/reload` re-runs the files already on that list but never notices a
> new one, so a version that adds a file — `BidSniperLedger.lua`, say — will
> half-load however many times you reload, and every ledger command will error.
>
> BidSniper checks for this at login and tells you plainly if it happened.
> **Fully exit the game and start it again.**

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
| Item | Name, the grey `x20` stack size, and `(4 up)` when several identical auctions share the row — see [One row, several auctions](#one-row-several-auctions) |
| Bid | What it costs you to be high bidder on **one** of them |
| Buyout | The seller's buyout price, for one |
| Ratio | Buyout ÷ bid — how good it *looks* |
| Market | What the row is worth: one stack's value × how many are still up |
| Profit | Market − what the row costs — what you actually stand to make from all of them |

**Market and Profit count the whole row; Bid and Buyout are per auction.** Bid has
to be per auction because it's what one press of **BID** spends. Profit is the
whole row because that's what you sort on to decide where to go first — eight bags
at 60g each is a 480g row, not a 60g one. Hover for the per-auction breakdown.

As you bid the copies off a row, its Profit falls to what's left on it.
| Left | Time left, or `stale` / `gone` |
| Seller | Who posted it |

---

## Row actions

| Action | Result |
| --- | --- |
| Click | Bid on one of them, with a confirmation showing the exact amount |
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
untick anything. A row standing for several auctions only counts as bid on once
every copy has had a bid.

---

## Bidding in bulk

**Select all** ticks everything and flips to **Select none**; untick what you
don't want. The line above the buttons keeps a running count and total, so you
see the damage before committing.

**Bid selected** then works through them **one click per auction** — see
[Why bidding needs a click](#why-bidding-needs-a-click). A ticked row covers
every identical auction at its price, so the count it queues can be more than
one — see [One row, several auctions](#one-row-several-auctions). Press it once to
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
| **Min profit** | Bulk ticking skips rows worth less than this over their bid. `0` = no limit |
| **Categories** | Limit the scan to chosen categories and subcategories |
| **Only unbid** | Only auctions nobody has bid on |
| **Ending < 2h** | Only Short and Medium time left |
| **Hide mine** | Skip auctions from any of your characters, and ones you're winning |

Money boxes accept `50`, `50g`, `1s50c` — a plain number means gold.

Defaults are ratio `10x`, max bid `50g`, min buyout `1g`.

### Min profit — a selection filter, not a scan filter

**Min profit** is the odd one out: it hides nothing. It governs which rows a
*bulk* tick will take — **Select all**, a shift-click range, or dragging across
the boxes — so you can sweep up only the auctions actually worth the gold.

* A single deliberate click always ticks, whatever the minimum says. A filter
  must never put a row you can see and want out of reach.
* Items Auctionator has no price for are **skipped** by a bulk tick. Everywhere
  else an unpriced item gets the benefit of the doubt, because it's the case you
  most need to look at — but this is where gold actually gets spent, and "no idea
  what this is worth" is not a reason to bid.
* `0` ticks everything, and costs nothing: the profit lookup is skipped entirely
  unless you set a minimum.

It works on selection rather than on the scan because profit depends on
Auctionator's prices, which often arrive *after* a scan has run. Filtering
results on it would throw away the auctions that turn out to be the good ones.

### One row, several auctions

3.3.5a hands out no auction id on the browse list. Two listings with the same
item, stack size, price, seller and time-left bracket are, as far as anything an
addon can see, the same thing — and a seller posting eight of one bag makes
eight of them.

So they share a row, and the row says how many: `Frostweave Bag (8 up)`. That
count is separate from the stack size, which is still the grey `x20`.

* **Clicking** the row bids on one of them.
* **Ticking** it and pressing **Bid selected** bids on all of them — one click
  each, at the price the row shows.
* Part-way through, the row reads `(3 of 8 up bid)`; once every copy has a bid
  it closes like any other bid-on row.

**The count corrects itself as you bid, at no cost.** A scan undercounts runs of
identical auctions (below), but every bid already searches that one item by name
and loads the page — and that page has the whole run on it. So the addon counts
them while it's there. No extra queries, nothing to wait for.

If more turn up than the total you approved, they aren't bid on — that total was
the deal. The batch finishes what you approved, says how many more are up, and
leaves the rows carrying the true count, so pressing **Bid selected** again takes
the rest at a figure you approve on its own. Rows whose copies have all gone read
`(none left)`; rows you've swept read `(all 8 bid)`.

### "There are several of these up and only one was listed"

Usually that one row *is* all of them — look for the `(n up)` count. Otherwise
there are two causes, and it's worth knowing which.

**A filter dropped it.** **Ratio is the buyout over what the auction would cost
*you*, right now** — so the moment somebody else bids, that auction's ratio
collapses and it can fall under **Min ratio** while its identical twin sits
untouched. **Hide mine** does the same to whichever one you're currently winning.
A bid also changes the price, which makes it a different deal and a different
row.

**The scan never read it.** A sorted paged scan steps over auctions, worst of all
runs of identical listings from one seller — see *Scan methods*. Use GetAll, or
`/snipe thorough`. Bidding covers for this on its own: the lookup it does anyway
finds the copies the scan walked past, and the row's count corrects itself.

To tell them apart: search the item in Browse and run `/snipe why <row>`. It
walks the scan's own filter chain and prints, test by test, what happened to that
auction. If every test passes, the scan simply never read it.

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

## Flasks and elixirs

**Craft** costs out every flask and elixir you can make against current reagent
prices, and says what each one would earn.

**Setup is opening your alchemy window once.** The client won't say what a
character can make unless that window is open, so BidSniper reads it the moment
you do — no button to press — and keeps the recipes through logging out. Only
flasks and elixirs are kept, decided by the crafted item's own subclass rather
than a list of names that would go stale.

### The prices are free

Reagent prices come out of the scan you were running anyway. Every row a scan
reads is checked against your reagent names on the way past — one hash lookup,
the same trick that settles bids — and the cheapest buyout per unit is kept. The
crafting tab never sends a single query of its own.

**Including a scan you started somewhere else.** GetAll's ~15 minute cooldown is
shared by every addon on the client, so running Auctionator's full scan and then
BidSniper's meant waiting a quarter of an hour to read the same data twice. The
dump lands in the auction list all addons share, so BidSniper now walks it too:
press **full scan** in Auctionator and your bids, profits and reagent prices all
fill in beside it. One request, one cooldown, both sets of answers. It takes
smaller bites while doing this so Auctionator still gets its frames. `/snipe
piggyback` turns it off.

### What you're holding, and what to buy

**Can make** is how many you could produce right now out of your bags, without
buying or fetching anything.

**Click a recipe** and the lower half shows its reagents as `have/need`, green
once you have enough, with how many more you're short.

**Type a number in Want** against anything you plan to make, then press
**Shopping list**. It adds up the reagents for the whole plan, deducts your bags
*once* across everything — do it per recipe and two things sharing a reagent
would each claim the same stack — and prices what's left.

### The bank is mentioned, never counted

Every figure uses your bags alone. What's in the bank may well be there on
purpose, and a shopping list that assumed you'd go and fetch it would be planning
your trip for you.

It's still reported: anything you're short of carries a grey `12 of those are in
your bank` after the price, so a stack you'd forgotten is a stack you get told
about. It never changes a number.

> The bank count is only as good as what the client cached the last time you
> opened your bank. If you haven't opened it this session it reads zero — no note
> is not proof there's nothing there.

**Vials are listed separately and not costed.** They come off a vendor at a fixed
few silver, so putting them in a profit figure only muddies it; but you still
need to know how many to pick up after the auction house, so they get their own
line with a count. A recipe whose vials you don't have still reports 0 in **Can
make**, because you genuinely can't make it.

That check sits ahead of the filters, because it has to: reagents are cheap bulk
goods and **Min buyout** and **Min ratio** would throw away every one of them.
Only buyouts count, never bids — you can't plan a craft around an auction you
might be outbid on.

### Exact, or an estimate that says why

| Row | Meaning |
| --- | --- |
| White | Every figure came from the most recent scan |
| Orange | An estimate — hover to see which reagent made it one |
| `?` in Profit | A reagent has no price anywhere, so there's no honest figure |

"Most recent" means that scan, not recently-ish: a price from the scan before
last is a price for a market that has since moved. Anything else — Auctionator's
database, an older sweep, nothing at all — is named in the tooltip, reagent by
reagent.

A missing reagent is never costed as free. That would make the recipe you know
least about look like the most profitable one on the list, so it gets no profit
figure at all.

**After an Auctionator scan, press Recalculate.** Auctionator is read live rather
than cached, so it picks up its new prices immediately — that's where the figures
for anything your last BidSniper scan didn't see come from.

Reagents are costed at what it would take to buy them, not at what's in your
bags. What you already own is a sunk cost, and the question is whether turning
materials into a flask is worth doing at today's prices either way.

Profit is raw; the 5% auction house cut is in the tooltip, as with the results
list.

---

## Scan methods

**GetAll** pulls the entire auction house in one request and takes seconds.
The client permits it once every 15 minutes.

**Page by page** asks the server to sort by current bid, cheapest first, and
stops once bids pass your **Max bid** — everything beyond is too expensive to
qualify. The lower your Max bid, the shorter the scan.

**Thorough** pages too, but without sorting and without stopping early: every
page, every auction. Slower than the rest, and the one to reach for when
auctions go missing — see below.

`auto` (the default) uses GetAll when it can and falls back to paging.

### Why a paged scan can step over auctions

Paging walks a **live** server-side list by index. Anything posted, bought or bid
on while the scan runs shifts every later row, and a page boundary quietly
swallows whatever it stepped across.

Sorting by current bid — which is what makes `paged` fast — makes this
considerably worse, because auctions sharing a bid are **tied**. Several
identical listings from the same seller sit adjacent in the order with nothing
to break the tie consistently between one page request and the next, so a
boundary landing inside that run drops part of it. Seeing five identical orbs on
the auction house and one in your results is this, exactly.

| Method | Steps over auctions? |
| --- | --- |
| **GetAll** | No — one request, no paging, no boundaries |
| **Thorough** | Rarely — no sort and no ties, but still paged |
| **Paged** | Yes, especially runs of auctions sharing a bid |

GetAll remains the best answer where the realm allows it. Where it doesn't,
`/snipe thorough` trades speed for seeing everything.

It matters less than it used to, because bidding corrects the count. A search
for one item name doesn't page through the whole house, so the run of identical
listings comes back together — and a bid loads that page anyway. Whatever the
scan managed to see, the copies show up when you go to bid, for free.

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
the server immediately before spending, and refuses to pay more than the price
shown on the button.**

If the row has moved in the meantime — which happens constantly, because every
accepted bid renumbers the list — the auction is looked up again by what it is
rather than where it was. Only a price that has actually risen, or an auction
that has genuinely gone, stops the bid.

---

## My bids: what happened while you were away

The auction house cannot tell you what became of a bid you left running.
`GetBidderAuctionItems()` only ever returns auctions you are **currently
winning**. Auctions you were outbid on are held by the client in memory for the
current session alone, so after a relog they are gone from the Bids tab with
nothing left to show they were ever there — no won, no lost, no trace.

So BidSniper keeps its own record. Every bid is written down as it is placed and
survives logging out. Press **My bids** to see it.

That record is settled from three sources. Two of them are instant and free; the
third is slow and you have to ask for it.

| Source | Cost | Settles |
| --- | --- | --- |
| **Your mail** | free | outbid, and won |
| **Any scan** | free | anything the scan walks past |
| The auction house, asked directly | slow | the last stragglers |

### Your mail is the fast answer

Being outbid puts your gold **straight back in the post, immediately** — not when
the auction ends. That mail then sits in your mailbox for thirty days whether you
log out or not, which makes it the one record that survives a logout by itself.
Winning instead sends you the item.

**Check now** reads your Bids tab and your mail and asks the auction house for
nothing at all, so it answers at once.

> The client only has your mail after you have opened a mailbox — WoW does not
> hand it over from across the world. Visit one and BidSniper reads it the moment
> it appears; until then that half of the check simply has nothing to go on.

Because outbid mail arrives the moment you are beaten, a refund does **not** mean
the auction is over — very often it is still sitting there to be re-bid. BidSniper
only calls it `lost` once the auction's own time-left bracket says it cannot still
be running.

### Any scan settles bids for nothing

A scan already reads every auction it pages through, so each row is checked
against the ledger on its way past — no extra queries, no waiting. Press **Scan
AH** and your bids settle themselves as a side effect.

**That includes bids you are currently winning.** `highBidder` on the row is the
server's own answer, so a scan is the cheapest way there is to find out somebody
has just taken one off you — it says so at the end, and points you at **Re-bid**.

Only a scan that read the *whole* house can conclude an auction is gone. One
narrowed by categories, cut short at your max bid, or aimed at a wishlist settles
what it found and stays quiet about the rest.

### Asking the auction house directly

**Find on AH** searches for each still-unaccounted-for bid, one item name at a
time. It is the only way to be certain and it is genuinely slow, so it is never
run for you — try a scan first. Clicking any row searches Browse for that one
item, which is usually all you actually want.

Both this and the lookup a bid does read the item cheapest-bid-first and stop the
moment the page has priced past the buyout of what they're hunting — an auction
always costs less to bid on than to buy, so past that point the answer can't be
ahead. Looking for a 70g Abyss Crystal no longer pages out through the 800g ones
to decide it's gone.

An auction is identified by **item, stack size, starting bid and buyout**, every
one of which is fixed for its whole life. The current bid is deliberately no part
of that: it moves the instant somebody outbids you, which is exactly the event
this has to survive. Starting bid is what separates two auctions of the same item
that happen to share a buyout.

Settled bids clear themselves after a fortnight, or on **Clear settled**.
Right-click a row to forget it.

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
| `/snipe auto` \| `paged` \| `getall` \| `thorough` | Choose the scan method |
| `/snipe mybids` | Open the record of every bid you've placed |
| `/snipe checkbids` | Fast check: your Bids tab and your mail, no AH queries |
| `/snipe findbids` | Slow check: search the auction house itself |
| `/snipe listbids` | Print that record to chat |
| `/snipe mail` | Settle ended bids from the mail (at a mailbox) |
| `/snipe bids` | Ask the server what you've actually bid on |
| `/snipe syncbids` | Rebuild the "already bid" marks from the server |
| `/snipe clearmarks` | Drop every "already bid" mark |
| `/snipe prices` | Forget cached prices and rebuild Profit |
| `/snipe debug` | Scan method, saved results, why GetAll is or isn't used |
| `/snipe layout` | Print where the filter boxes actually are |
| `/snipe why <n>` | Say which filter dropped row *n* of the Browse list |
| `/snipe peek <n>` | Read row *n* of the Browse list, bidding on nothing |
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
