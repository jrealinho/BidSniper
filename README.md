# BidSniper

Finds auctions where the bid is far below the buyout — the 1 silver bid /
15 gold buyout kind — and helps you act on them quickly.

It grew into the whole auction house round trip: find the underpriced bids, buy
the reagents for what you plan to make, post what you want to sell, and keep a
record of every bid you placed.

For **World of Warcraft 3.3.5a** (Wrath of the Lich King, tested on Warmane).
No dependencies; [Auctionator](https://github.com/Auctionator/Auctionator) is
used if you have it.

| Tab | What it is for |
| --- | --- |
| **Auctions** | Scan the whole house and sort by what you would actually make |
| **Buy** | The cheapest set of auctions that covers what you need |
| **Sell** | Post from a staging bag, priced against the live market |
| **Profit** | What a craft costs, what it earns, and the shopping list for it |
| **Training** | The cheapest way to buy a skill point |

## Contents

* [Install](#install) · [Quick start](#quick-start) · [The window](#the-window)
* Bidding — [Row actions](#row-actions) · [Bidding in bulk](#bidding-in-bulk) ·
  [Filters](#filters) · [Categories](#categories) · [Wishlist](#wishlist)
* [Buying](#buying) · [Selling](#selling)
* Crafting — [Crafting](#crafting) ·
  [Training](#training-the-cheapest-way-to-level)
* Under the bonnet — [Scan methods](#scan-methods) ·
  [Market and Profit](#market-and-profit) ·
  [Auctions that have moved on](#auctions-that-have-moved-on) ·
  [My bids](#my-bids-what-happened-while-you-were-away) ·
  [Why bidding needs a click](#why-bidding-needs-a-click)
* [Troubleshooting](#troubleshooting) · [Commands](#commands) ·
  [Saved data](#saved-data)

---

## Install

Drop the `BidSniper` folder into `Interface\AddOns\`, so you end up with:

```
Interface/AddOns/BidSniper/BidSniper.toc
Interface/AddOns/BidSniper/BidSniper.lua          the window, scanning, bidding
Interface/AddOns/BidSniper/BidSniperLedger.lua    the record of your bids
Interface/AddOns/BidSniper/BidSniperCraft.lua     recipes, costings, shopping lists
Interface/AddOns/BidSniper/BidSniperSell.lua      posting from your bags
Interface/AddOns/BidSniper/BidSniperBuy.lua       searching and buying
Interface/AddOns/BidSniper/BidSniperShop.lua      buying a whole shopping list
Interface/AddOns/BidSniper/BidSniperAtr.lua       sharing a GetAll with Auctionator
Interface/AddOns/BidSniper/BidSniperUI.lua        every panel
```

The repository is the addon folder itself, so cloning it straight into place
works:

```bash
git clone https://github.com/jrealinho/BidSniper.git BidSniper
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
| Ratio | What it's worth ÷ what a bid costs — see [Ratio](#ratio-is-against-what-its-worth) |
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

## The window

It opens with the auction house and sits over it. Five tabs, in two families:
the three that are about the auction house itself, then the two that are about
what to do with what you bought.

| Tab | What it does |
| --- | --- |
| **Auctions** | The scan results: every auction whose bid is far under what the item is worth. Sort by **Profit** and work down |
| **Buy** | Search one item and buy it properly — the cheapest *combination* of auctions that covers what you need, not the cheapest one |
| **Sell** | Empty a staging patch of your bags onto the auction house, priced from a live check of the market |
| **Profit** | Every recipe you know, what its reagents cost, what it sells for, and what that leaves. Type quantities and it builds the shopping list |
| **Training** | The same recipes read the other way: what a skill point costs |

Three side panels open from the Auctions tab — **Categories**, **Wishlist** and
**My bids** — and close again by pressing the same button.

The window is movable, remembers where you left it, and closes with Escape.

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
| **Min ratio** | How many times over a bid pays you back, against what the item is worth |
| **Max bid each** | Ignore anything costing more than this to bid on **for one of them**. `0` = no limit |
| **Min buyout** | Ignore junk below this buyout |
| **Min quality** | Click to step up, right-click to step back |
| **Min profit** | Bulk ticking skips rows worth less than this over their bid. `0` = no limit |
| **Categories** | Limit the scan to chosen categories and subcategories |
| **Only unbid** | Only auctions nobody has bid on |
| **Ending < 2h** | Only Short and Medium time left |
| **Hide mine** | Skip auctions from any of your characters, and ones you're winning |

Money boxes accept `50`, `50g`, `1s50c` — a plain number means gold.

Defaults are ratio `10x`, max bid `50g` each, min buyout `1g`.

### Ratio is against what it's worth

**Ratio is what the item is worth divided by what it costs you to bid on it.**
Not the seller's buyout.

The buyout was never a valuation — it's one person's asking price, and anyone
can list a grey at 100g and make the ratio read wonderfully. The column used to
have to be described as how good a deal *looked*.

What it's worth is what somebody is actually asking for one right now: the
lowest buyout on the house. Both BidSniper's own scan and Auctionator hold that
figure, and they are the same number by different routes — BidSniper's is
usually fresher, because it came from the sweep you just ran, so it's used
first.

For a stack, it's the whole stack's worth over one bid, because one bid buys the
whole stack.

| Ratio reads | Meaning |
| --- | --- |
| `18.4x` | A bid gets you eighteen times its own value back |
| `7.5x?` in grey | Nothing is known about this item, so that figure is only the seller's buyout over the bid — treat it as "find out first" |

The grey `?` is the same shorthand **Profit** uses, and it means the same thing.
An unpriced item is the case to look at *hardest*, not the case to throw away —
it's exactly where something unrecognised hides — so it's kept and marked rather
than dropped.

Hovering a row shows both readings, so you can always see what the seller
thinks alongside what the market says.

> **Where the scan is deliberately generous.** Working out a ratio needs a
> price, and a scan can't go looking one up forty thousand times without
> crawling. So the scan keeps a wider net — it takes the better of the two
> readings from what's already in hand and keeps the row if *either* clears the
> bar — and the list makes the real decision. Junk at 100g still gets past the
> scan and is thrown out by the list, where the mistake is free. Something worth
> far more than its own buyout gets in too, which the old buyout-only test
> dropped for ever.

### The filters are a window, not a sieve

**Move a filter and the table repaints immediately.** No rescan. The scan's
results stay as they are and the filters decide what you see of them, so you can
tighten Min ratio to 12, look, and put it back to 10 with nothing lost.

There is one thing this cannot do, and it says so rather than pretending: an
auction the scan dropped was never written down, so **loosening a filter past
where it stood during the scan needs a new scan**. Set Min ratio to 8 after
scanning at 10 and you get a line in orange telling you exactly that. Press
**Scan AH** and the auctions it skipped come in.

**Refresh** goes over the list again without asking the auction house for
anything: it re-applies the filters, drops auctions that have certainly ended,
and rebuilds the Profit column from current prices — which is what you want
straight after an Auctionator scan. Changing a filter does not need it.

### Max bid is per item

A stack of twenty at a 40g bid is **2g each**, and 2g is what you are being
asked to pay for one of them. A limit that judged the 40g would throw away every
stack on the house, which made Max bid useless for anything sold in bulk — the
things you most want to buy in bulk.

The auction still costs the whole 40g to bid on. That side is guarded where it
belongs: the BID button always shows what one press spends, and a batch asks you
to approve the total before it starts.

> One consequence, and it only touches `paged`. That method used to stop as soon
> as the server's bid-sorted list passed your Max bid — everything beyond was
> too expensive to qualify, so the lower your Max bid the shorter the scan. Per
> item, that no longer holds: a 400g bid on a stack of two hundred is 2g each
> and sits far down a list ordered by the 400, so nothing on one page bounds
> what a later one is worth per item. **A paged scan now reads to the end.**
> GetAll never paged and is unaffected, and `auto` reaches for GetAll first.

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

## Buying

The **Buy** tab, second from the left. Search an item and it lists every auction
of it, cheapest per item first — which is the whole of a shopping addon's buy
tab, and still the right answer when you only want the cheap one.

Case doesn't matter, but the whole name does: `deadnettle` finds Deadnettle,
`copper` finds nothing, because a page of Copper Bars, Copper Ore and Copper
Rods is not a thing you can plan a purchase of. Type half a name and it tells
you what it found instead of claiming there is nothing there.

What it adds is the other question: **how many do you want?** Type a number in
**How many** and the plan underneath is the cheapest *set* of auctions that gets
you at least that many.

That is not the same as buying down the list. Say you want 20, and the house has
twenty singles at 3g and one stack of 25 at 4g each. Cheapest-first buys the
singles for 60g. Ask for 24 and cheapest-first runs out of singles at 20 and has
to reach for the stack anyway — while that one stack alone is 100g for 25 items,
one purchase, and five items you didn't have to go looking for. Which of those
is better depends on the number you asked for, and that is arithmetic worth
doing rather than eyeballing.

| Column | Meaning |
| --- | --- |
| Per item | Buyout ÷ stack size — what one of them costs you |
| Stack | How many are in one auction |
| Up | How many identical auctions are at this exact price |
| Each | The buyout for one of those auctions |
| All of it | What taking every auction at this price would cost |
| Seller | Who posted it, or `several` when more than one is asking exactly this |
| Left | Time left |
| In plan | How many of these the plan below is taking |

* **Click a listing** to buy from that one alone — the seller you know, the
  stack size that suits, the auction about to end. It takes as many of that
  listing as your number needs.
* **Ctrl-click** takes every one of them.
* **Shift-click** links the item into chat.
* **Right-click** looks the item up in the normal Browse tab.
* **Best mix** puts the worked-out plan back after either of those.

### Changing your mind mid-search

A search walks the auction house a page at a time, and you don't have to wait
for it. **Click another item and the search in flight is dropped for the new
one** — from the box, the Recent list, a shift-click or `/snipe buy`, all the
same. Pressing **Search** again does the same.

There's also a **Stop** button while a search is running, for when you want to
stop without starting another.

Previously the second click did nothing at all, silently, and the only way out
was closing the auction house.

A shopping run is the one exception: it drives searches of its own and won't
have one pulled out from under it half way down a list. It already holds this
page against manual searches anyway, and says so when you try.


### Shift-click anything to look it up

**Shift-click an item anywhere — your bags, a link in chat, a loot window, the
tradeskill list — and this page opens on it and searches.** It doesn't matter
which tab you were on; the window comes up, the Buy tab comes forward, the name
lands in the box and the search runs.

Shift-click already means something, though, so it stays out of the way where it
does:

* away from the auction house, where there is nothing to search;
* while you're typing in chat — shift-click there means "insert the link", and
  hijacking that mid-sentence would be unforgivable;
* on rows that link an item into chat on purpose, which is what shift-click does
  on both the auction table and the Buy listings;
* and with the wishlist box open and focused, where the name goes into the box —
  which is what the wishlist has always said shift-click does.

**Shift-click search** turns it off, for anyone who shift-clicks items into the
Browse box all day and would rather we kept out of it.

### More for less always wins

The list on the right is every *other* quantity worth having, and it exists
because the number you typed is rarely the number that is good value. Sixty in
three stacks is routinely cheaper per item than the fifty you asked for.

**Everything on it reaches your number.** Asking for fifty and being shown one,
or eight, is not being shown a way to buy fifty — picking it would quietly
abandon what you asked for. So quantities below the target are not choices and
are not listed. When nothing reaches it, there is one line saying how close you
can get: the whole of what is for sale, marked `all there is`.

**And everything past the first is better value per item.** There is only ever
one reason to buy more than you asked for: 53 instead of 50 because the 13 came
at a better price than the 10. The same plan with one more single auction stuck
on the end is not a reason — it is more gold for more items at the same rate,
which is not a deal, it's a bigger bill. A row has to beat the cheapest answer
on price per item, by a margin you'd change your mind over rather than by a
hundredth of a silver, or it isn't listed.

Very often that leaves one line, and the heading says so: *buying more is no
better value*. That is an answer, and a useful one.

One rule governs the rest: **a quantity that hands you more items for the same
gold or less is never a worse deal**, so it is never offered as an alternative —
it replaces the worse one. Nothing on the list is beaten by anything else on it.

Rows are marked against the plan you are on:

| Mark | Meaning |
| --- | --- |
| `this one` | The plan currently on the left |
| `cheapest` | The worked-out answer for your number — always listed, so there is always a way back to it |
| `more, for less` (green) | More items than the plan, and no more gold |
| `12% cheaper each` | Overshoots your number, but at a better price per item — the reason the list exists |
| `8% dearer each` | Dearer per item than the plan you have picked |

**Click any of them** to make it the plan. **Best mix** puts the `cheapest` one
back.

By default the list shows the quantities where the price per item actually
drops — the points worth knowing about, rather than every step between them.
**Every option** shows the lot.

### The plan is exact, not a rule of thumb

It is worked out rather than guessed: for every quantity from one up to
everything for sale, the cheapest combination that reaches it. Ties go to the
larger quantity, which is the same rule as above — same gold, more items, take
the items.

Very large ranges cost real time to work out, so there is a limit. When the
range has to be cut it is never cut below the number you asked for, and the
footer says how far the options list goes.

### Buying it

**Buy** shows what the plan costs before you press it, and asks once for the
whole total.

WoW only lets an addon buy while you are actually clicking, the same rule that
makes bidding one press per auction — but a buyout at a price you already
approved needs no confirmation of its own, so a press takes **everything on the
current page of results** rather than one auction. In practice that is one or
two presses for most plans.

It never spends past the total you approved, stops when the gold runs out, and
after each press reads the house again — every purchase renumbers the list
behind it, so the page it was walking no longer means what it meant.

Auctions that have gone in the meantime are reported and skipped. What you did
buy comes off the counts on screen, so the listing table and the plan stay true
without a second search.

**Hide mine** skips auctions posted by any of your characters. Bid-only auctions
with no buyout are counted in the summary and otherwise ignored — there is
nothing there to buy outright.

---

## Selling

The **Sell** tab is a staging area. Tick the bags and slot range you use as
"stuff to sell", drop things into it as you play, and empty it in one pass at
the auction house.

The ticked bags are **one run of space**, not the same window cut out of each of
them. **From slot** cuts into the first ticked bag, **To slot** stops part way
through the last, and every bag between them is taken whole:

> backpack + bag 1 + bag 4, from slot 5, to slot 8 → the backpack from slot 5 to
> its end, **all** of bag 1, and bag 4 up to slot 8.

Tick one bag and both numbers land on it, which is the ordinary case. `0` for To
slot means carry on to the end, so whole bags of different sizes need no numbers
at all.

Everything in that range is grouped by item, priced against a **live check of
the auction house**, undercut, and listed:

| Column | What it is |
| --- | --- |
| What | The item, and how many of it are in the range |
| Per lot | How many go in **one auction** — type here |
| Auctions | The shape that makes, e.g. `5 x 4 + 3` |
| Each | What one full lot is asking |
| Total | What the whole heap is asking |

The list **scrolls** — by the bar or the mouse wheel anywhere over the panel —
so every item is reachable and every lot size editable before you post anything.
The footer counts the whole plan, not the rows on screen.

### It checks the market before it posts anything

Undercutting means going a copper under the cheapest listing, and that is right
almost all the time. It is catastrophic the rest of the time. Somebody misplaces
a decimal, or dumps a stack to clear a bag, and pricing off the cheapest listing
**copies their mistake onto everything you own of that item** — the auctions go
up, somebody takes them all inside a minute, and the gold is gone.

So the first press searches. One query per item, buying nothing, and afterwards
every price on the page is seconds old and has been argued with. The button says
**Check prices & post** while that is still needed and **Start posting** once it
isn't; a check finding nothing to ask about falls straight through to posting.

#### It doesn't ask twice

**A recent scan answers for free.** A sweep walks every auction on the house, so
it already knows what the check wants to know — and it now keeps the **cheapest
eight** listings of each item with a count beside them, rather than the single
lowest price it used to. That one number was exactly the wrong thing to keep:
the lowest listing is precisely the one that might be somebody's misplaced
decimal, and a single figure carries no way to tell. Eight is enough to run the
same outlier test, so anything the sweep saw is priced instantly and never
searched for.

The limit is honest: to notice that `m` giveaways sit below the real market you
must have kept `m + 1` prices, so the scan path spots up to **seven**. Past that
it cannot tell a collapsed market from a misprice — it marks the row `!` in red
and says so, and **Refresh** asks the auction house properly. A live search has
no such limit.

A quote stands for **an hour**, and it is **saved** — so coming back to a half
emptied bag, after a reload or a restart, costs no queries at all for anything
already checked. Only items neither the scan nor a recent check can answer for
are searched.

An hour is deliberately long. A price that old isn't what the item is worth to
the copper any more, and that is not what this figure is for: the expensive
mistake it exists to stop is undercutting a giveaway by two orders of magnitude,
and the *shape* of a market — a wall of listings around 190g with two idiots at
1g — does not rearrange itself in an afternoon. Being a few percent behind on
the wall costs a slower sale; being fooled by the 1g costs the stock. Meanwhile
the cost of a shorter window is paid every single time, in queries, while you
stand at the auction house waiting to post a bag you have already decided about.

**Refresh** throws the quotes away as well as re-reading your bags, so it is the
way to force a fresh look when you know something has just moved.

#### What counts as a giveaway

The cheapest listing is only disregarded when there is a real **cliff** above it
*and* the listings below that cliff are a small minority of what's up. Both
halves matter, and they pull against each other:

| Situation | What it does |
| --- | --- |
| Two silly listings under a wall of sensible ones | Ignores the two, prices under the wall |
| Someone undercutting properly, 25% under | **Leaves it alone** — that's the market working |
| A dumper holding the whole bottom of the list | **Leaves it alone** — if 10 of 15 auctions are at 2g, 2g is what it costs today |
| Only one other auction up | Uses it, and says it couldn't be checked |
| Nothing else for sale | Falls back to the last scan |

The cliff is **2.5×** — undercutting is a few percent, a clearance is tens of
percent, nobody prices at a third of the going rate and means it as a trade. At
most two listings, or 40% of them, may be written off, and never all of them:
something has to be left to be the price. It searches for the *largest* gap in
that range rather than the first, because outliers cluster — a bottom of 1g, 2g,
190g has no cliff between the first two and a very large one after them.

Your own auctions never count as competition, whichever character posted them.
Undercutting yourself is how a price walks to the floor over a week of
relisting.

Rows are marked `*` in orange where a giveaway was disregarded, `?` in yellow
where there was only one rival to judge by, and `!` in red where the scan could
not see past the giveaways and the figure may still be low. Hover any row for the full working:
what's up, what was ignored, what you'll ask.

### Per lot: how many in one auction

**Per lot** is the number of items in a single auction, and it is **saved
against the item**. Set Saronite Ore to 4 once and every future posting of
Saronite Ore goes up in fours, on that character and every other one, until you
change it.

Whatever is left over after the whole lots goes up as **one last smaller
auction**, priced for its own size:

> 23 Saronite Ore, per lot 4 → **five auctions of 4, then one of 3.**

The remainder is posted rather than left behind, which is the whole point — a
half stack sitting in your bags is the easiest way to end up carrying the same
three ore around for a week. It is priced for three, not for four.

**It can be changed mid-run.** Remembering late is the ordinary case — the price
check is the moment you are finally looking at what the item is worth, and that
is exactly when it occurs to you that it should go up in fives. Type the new
size, press enter, and everything still to go is worked out again around it. The
run is rebuilt from your bags rather than patched: anything already posted has
left them, so what is in them now *is* the remainder.

Blank or `0` means **a full stack**, which is what posting did before there was
a setting, so a list you have never touched behaves exactly as it always did.
A number at or above the item's own stack limit is stored as "no choice",
so the setting still means what you meant if you later post the same item from
bags that hold a bigger stack.

### One press per lot

WoW will not let an addon post an auction on its own — `StartAuction` is only
honoured while the client is handling a real click, the same rule that makes
[bidding one press per auction](#why-bidding-needs-a-click). So posting is one
press per **lot**, not per auction: all five lots of four go up in a single
press, because the auction house takes a stack size and a number of stacks
together.

An item that divides evenly is one press. An item with a remainder is two — the
whole lots, then the remainder — and the button greys to **Waiting…** in
between while the stacks actually leave your bags. That pause is not optional:
loading the remainder in the same click would pick up a stack the server is
still in the middle of taking.

#### It won't reach into a slot the client is still using

Spam-clicking POST used to leave the odd gem greyed out and unclickable until a
relog. That is the 3.3.5a item-lock wedge: a bag slot the client has an
operation pending on is *locked*, and touching it before the server answers
means the lock is never lifted.

Two things now stop it, and neither costs anything when nothing is wrong:

* **Nothing goes into the sell slot while the last posting is still leaving
  it.** One call answers that; putting the next item in on top of a half-posted
  one hands it back to a bag slot still locked for it.
* **A locked slot is waited for, not skipped.** Locked and gone used to be the
  same answer, so a stack that was merely mid-operation read as one that had
  left the bag — and the lot was dropped for good over a wait that would have
  been over in a moment.

The wait ends on the bag or item-lock event that says the operation finished, so
it is as short as the server allows rather than a fixed pause — usually
invisible. After about a second and a half of a slot refusing to free up, the
lot is skipped with a note rather than risked.

### What it will and won't do

* It never posts more than the ticked range is holding. The count is taken
  again at the moment of each press, so a range that shrank between drawing the
  plan up and reaching a lot posts less rather than reaching elsewhere for the
  difference.
* It cannot control **where** the client sources the items from. The auction
  house gathers a stack size from your bags as a whole, so if you hold the same
  item outside the ticked range, some of those copies may be the ones that go.
  The number posted is still exactly what the range said.
* Soulbound, quest and conjured items are skipped — they cannot be auctioned.
  So are locked slots and anything with no known price, which is left alone
  rather than guessed at.

`/snipe sellplan` prints the whole plan to chat, item by item and lot by lot,
without opening the window.

---

## Crafting

The tabs come in two families, with a gap drawn between them.

**Auctions**, **Buy** and **Sell** are the auction house itself: what's for sale,
buying it, selling yours. **Profit** and **Training** are a different job — what
to do with what you bought.

Those last two are *modes*, not professions. A mode is why you're looking:

| Mode | Asks |
| --- | --- |
| **Profit** | What does this cost to make, and what does it earn? |
| **Training** | What's the cheapest way to buy a skill point? |

Which profession a mode is showing is chosen **on the page**, from a row of
buttons beside the title — so ten professions still cost two tabs. A profession
can be offered in either mode or both; they aren't mutually exclusive, and a
trade you level today is often one you'll make money from tomorrow.

Out of the box: alchemy under **Profit**, leatherworking under **Training**. See
[Adding a profession](#adding-a-profession) to change or extend that — it's a
table, not a code change.

A crafting page gets the whole window rather than a panel hanging off the edge,
which is what makes room for six columns and for the reagent breakdown to sit
under the list instead of in a tooltip.

**Setup is opening the tradeskill window once.** The client won't say what a
character can make unless that window is open, so BidSniper reads it the moment
you do — no button to press — and keeps the recipes through logging out. It reads
whichever profession is open, into that profession's own book.

### Profit: what it earns

Alchemy keeps only flasks and elixirs, decided by the crafted item's own subclass
rather than a list of names that would go stale — the rest of an alchemist's
window is things nobody trades.

| Column | Is |
| --- | --- |
| **Reagents** | What its reagents cost on the auction house right now |
| **Sells for** | What the finished item is going for |
| **Profit** | The difference, sorted dearest first |

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

**And the other way round.** Pressing **Scan AH** here used to leave
Auctionator's database exactly where it was — same dump, same cooldown, only one
addon any the wiser. Now a fast scan updates both.

The trick is who asks. Auctionator makes the GetAll request (its query is
identical to ours, argument for argument), we hold it still while the dump
arrives, we read the whole thing at our own pace, and *then* we let it look. It
walks an untouched list, updates its own prices with its own code, and prints its
own summary under ours.

> **Why the order matters.** Auctionator ends a full scan by querying for an item
> called `xyzzy` — a deliberate miss, to replace forty thousand rows with none and
> give the memory back. Sensible alone, fatal to anyone still reading, and we read
> a slice per frame so the client doesn't freeze. So we finish first, always.

Nothing is hooked or replaced; holding it still is one variable of Auctionator's
own, and every symbol this needs is checked for before anything happens. On a
version it doesn't recognise the scan just makes its own request as before and
says so. If the list isn't obviously still the full dump when the handover
comes, it's refused outright — handing Auctionator a single 50-row page would
overwrite a server's worth of prices with it.

A scan that stops early, times out, or ends because the auction house closed
hands over nothing and leaves Auctionator's database untouched.

`/snipe atrsync` turns it off; `/snipe debug` says whether it's working.

### What you're holding, and what to buy

Three counts sit together on the Profit page, and they only mean anything
against each other:

| Column | What it counts |
| --- | --- |
| **Can make** | How many more times you could make it right now out of your bags, without buying or fetching anything |
| **Have** | How many finished ones are in your bags — how far through the batch you actually are |
| **On AH** | How many you already have listed |

Bags only, in all three. A stack in the bank shows in the row's tooltip and is
never counted: the sums are about what you can act on without walking anywhere.
The tooltip carries all three plus the bank figure.

#### Want and Can make are both counted in crafts

**Want is how many times to make it, not how many items to end up holding.**
Type 15 against a flask that makes two and you get 15 crafts and 30 flasks, and
reagents are bought for all 15.

That matters for anything whose yield isn't 1. Want used to be read as a number
of finished items and divided by the yield, so 15 came out as **eight** crafts —
which disagreed with **Can make** sitting right beside it, because Can make has
always counted complete sets of reagents. Two adjacent columns in two different
units invite exactly the comparison that can't be made.

The divisor was also the *average* of what the recipe can produce, and for
anything with a chance-based extra that average is not a promise: buying for it
means buying for the lucky case and coming up short when the luck doesn't
arrive.

Crafts is also the number you actually control — you queue crafts in the
tradeskill window; how many items fall out is the recipe's business. Where the
two differ the row tooltip spells it out: *"Each craft makes 2"*, and *"From
what is in your bags — 8 crafts = 16"*.

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

### Price & buy: the shopping run

**Price & buy** (the button is marked with an estimate, `Buy ~293g12s`) takes
the shopping list to the auction house in two steps: it
prices all of it, shows you the exact total, and only buys once you approve that
figure. You don't search for anything. Before you press it, the button shows an
estimate from the last scan — `Buy ~293g12s` — so you know roughly what the list
comes to; the quote replaces it with the exact figure.

For each reagent it fills in the search, reads every page of results, and solves
the same covering knapsack the Buy tab solves by hand — the cheapest set of
auctions that gets you at least what you're short of. When you approve, it arms
each purchase in turn. You press **BUY**; it moves on to the next reagent.

#### You see the exact price, and what it earns, before anything is bought

The first pass buys nothing. It prices every reagent, then checks what each
finished craft sells for, and ends in a **quote** — a window in two halves.

**The crafts**, one row per craft you put a Want against:

| Column | What it shows |
| --- | --- |
| Make | Tick box — untick to leave the craft out |
| Want | How many to make, up to your Want column — lower it here to trim |
| Making | How many can actually be made — orange when a reagent cuts it |
| Reagents each | What one craft's reagents cost |
| Sells for each | What one craft sells for |
| Profit | Making × (sells for − reagents), green or red |

**Reagents each** is priced from this run's own purchases: each reagent at the
**average of everything bought of it, across every craft**, together with what
your bags already hold at its usual price. That's what makes the quote a filter.
The cheapest auctions go first, so a reagent shared between crafts gets dearer the
more of it you buy, and that cost lands on every craft using it. Untick a craft, or
lower its Want, and the dearest auctions drop out of the plan: the average falls,
and the crafts you kept earn more. Every change works the whole quote out again, so
you can keep trimming until the total profit stops going up.

The whole of an auction's cost is carried by the items you needed from it — a
stack bought for its first fifteen costs what it costs — because a craft is only
worth making if it pays for the stack it made you buy.

**Sells for** is the price the Sell tab would post at: giveaway listings ignored,
your own auctions not counted. A price checked or scanned within the hour is reused
rather than searched again, and anything it does search is saved for the Sell tab.
If nobody else is selling a craft, the last scan's price is used and the tooltip
says so; no price at all shows `no price` and is left out of the profit.

An unticked craft still shows what one would earn, in grey, so you can tell
whether it's worth ticking again. Profit is before the 5% auction house cut — hover
a craft for the figure after it, and for its reagent breakdown.

**The reagents**, below the crafts: Need, Buying (orange when short), what you're
paying each, the cost, and a note — `fair price`, `only 12 for sale`,
`nobody is selling it`.

At the bottom: **Spend** — the exact purchase total, from real auctions for real
quantities — and **Expected profit** for what you've left ticked.

The window says how long ago it priced things, and turns orange past five minutes.
**Cancel** buys nothing. Closing the window doesn't cancel — the crafting page's
button turns into **Show the quote**. Nothing in the quote changes your Want column.

#### Over your limit: your call, per reagent

The `pay up to +20%` box next to the button decides what counts as **fair**: at
most that much over a reagent's usual price. A reagent whose cheapest auctions
are fair but whose rest aren't supplies only the fair part — and gets a tick box.
**Tick it** and the dear part is bought too. The quote is worked out again on
every click, because buying more of one reagent can give a recipe its numbers
back, and that changes what the *other* reagents are needed for.

Reagents with no usual price on file get a tick box as well: ticked, they're
bought at whatever the auction house is asking, and the cost column shows that
figure.

The margin is measured **against the part of the purchase you actually need**,
which matters more than it sounds:

| Situation | What a naive check does | What this does |
| --- | --- | --- |
| Short 40, cheapest cover is 50 for less than 40 was quoted | fine | **fair** — the overshoot is free |
| Short 2, the only thing up is a stack of 20 for 380g | per-item price looks fine, **spends 380g** | **over the limit** — 2 were worth 40g |
| Short 40, only 5 up at six times the price | total is under the 40-item quote, **buys** | **over the limit** — 5 were worth 25g |

#### The total you approve is never exceeded

Approving sets a ceiling, and nothing crosses it. Each reagent is held to the
exact price its quote gave it for that quantity. A price that has crept up in the
minutes between the quote and the purchase can be covered — by at most your +% —
but **only out of money another reagent came in under**, never out of what's set
aside for the rest of the list. Anything it still can't get is left short and
named at the end.

It never goes back for more than you approved either. A reagent you left
unticked stays at its fair part, however many times the run looks again.

#### It looks at everything before it buys anything

A recipe you're one reagent short of is a recipe you can't make. Buying forty
flasks' worth of everything *else* is money spent on flasks that won't exist.

That can't be caught by reacting to shortages as they come up, because the
shortage is rarely in the reagent the list happens to reach first. So a run goes
round twice:

1. **Check.** Every reagent is searched and **nothing is bought**. All that comes
   out of it is one number each — how many you could actually get, at a price
   worth paying.
2. **Solve.** Those numbers together decide how many of each recipe are really
   makeable.
3. **Quote.** Those numbers are priced and put in front of you, with the cut
   recipes listed under them — see above.
4. **Buy.** Once you approve, the list is bought to the corrected numbers.

"At a price worth paying" is doing real work in step 1 — it's the fair part,
unless you tick a reagent in the quote. A reagent with 200 up,
of which the first 30 are sensible and the rest are somebody's fantasy, supplies
**30** — because 30 is what will be bought, so 30 is what the recipes have to be
worked out from.

Each recipe is limited by **all** of its reagents at once. That has to be one
calculation rather than a cap per reagent: cutting an elixir because of Ghost
Mushroom frees the Grave Moss it was holding, and a per-reagent cap has no way to
hand that back — quantities only ever come down, so a recipe cut early stays cut
after the reason has gone. Here each recipe takes what it can actually have, and
what it doesn't take stays on the table for the next one.

Where several recipes want the same scarce thing it goes **most profitable
first** — the order the Craft page is already sorted in — because half a batch of
two things is worth less than a whole batch of the better one. Only whole crafts
count: five of something you need two of makes two, never two and a half.

Reagents with **no usual price** are looked up rather than ignored, and only bought
if you tick them in the quote. Either way, what's for sale decides how many of
everything else is worth buying — a reagent nobody can price is just as capable
of being the one you can't get.

The bank counts here, and only here. It never stops a reagent being bought — the
list has always counted bags alone — but it would be a worse lie to say you can't
make a flask you plainly have the materials for.

**Your Want column is never touched.** The run works on its own copy, so fixing
the short reagent and running it again picks up the rest.

#### A press is a request, not a purchase

`PlaceAuctionBid` returns nothing. An auction somebody else bought a second ago
fails exactly as silently as one that succeeds, and the client says nothing
either way. Counting presses as purchases meant the page could report four
auctions bought against the two the server actually made — and worse, a shopping
run would move on from a reagent it was still short of, because as far as it knew
the order had been filled.

**The gold is the witness.** Your money falls by exactly the buyout of every
auction that really was bought and by nothing else, so the difference across a
press is the truth about that press. It arrives with the server's answer rather
than with the press, so each press is followed by a round trip and up to three
checks before the difference is taken as final.

Anything that didn't go through goes back on the wanted list and is tried once
more — an auction can fail simply for arriving in a list the server hadn't
finished updating. Twice, and it's written off: something that fails on a fresh
list isn't coming back.

Purchases are also planned against a search that is **seconds** old rather than
the one the check pass ran minutes earlier, which is where most "not found"
came from in the first place.

#### It goes back for what it didn't get

A purchase buys against a plan built from one search. Auctions named in that plan
get taken by other people while the run works through them — and a plan cannot
buy what it never listed. So a run could come back with **45 of the 75** it
wanted while the auction house still held plenty, report the plan as filled, and
move on. The shortfall was real and invisible: nothing compared what arrived
against what was asked for.

Now it does. When a reagent's purchase ends short, the run **searches again and
buys the difference**, up to four passes. Every pass re-searches, re-plans and
re-prices against what is up *now*, so the quoted prices, the approved total and
the gold check apply to the rest of the order exactly as they did to the start of
it. It never goes back for more than the quote approved.

It goes round again only if the pass that just ended **actually bought
something**. That is what makes it stop rather than a counter: each pass strictly
reduces what is outstanding. A pass that bought nothing has already answered the
question — the price is wrong, the gold has run out, or there is nothing left up
— and searching again would find the same nothing. **Skip** still means skip: a
reagent you leave is not gone back for.

Because bought items go to the **post, not your bags**, the shortfall the
shopping list works out cannot see anything this run has already bought. Each
pass subtracts what is already in the mail, so going back for the last 30 never
sets out to buy all 75 again.

The report says `45 of 75` in orange whenever the two differ, with the number of
tries beside it — a bare count reads as success, and a shortfall you cannot see
is one you find out about at the forge.

This is the shopping run only. A **Buy** you drive by hand stops when its plan is
filled and leaves the next move to you.

#### It says why a craft came up short

The report at the end lists what you can now make, and under every craft that came
up short it names the reagent that held it back — with the counts, and the cause:

```
6 x Flask of Blinding Light   (you asked for 15)
   short on Netherbloom: got 36 of 90 - only 40 were within your +20% limit,
   and you left the rest unticked in the quote
```

Causes decided before buying — not enough for sale, over your limit and left
unticked, no usual price — come from what the price check actually saw. Causes
that happened while buying — taken by somebody else, dearer by the time it was
bought, out of gold, skipped — were written down when they happened. A reagent
that caps several crafts is explained once and pointed at after that, and crafts
you left out in the quote are listed on their own line, so a missing flask is
never a mystery.

#### Telling "about to spend" from "already spent"

Three buttons in this addon commit gold — **BID**, **BUY**, **POST** — and all
three work the same way: the addon lines a thing up, and the press is yours,
because [the client won't allow otherwise](#why-bidding-needs-a-click). That
makes the button the only place the difference can be shown, and it used to be
shown by changing a number on an otherwise identical grey button. Press it twice
out of habit and the second press bought another lot.

So the states now look nothing like each other, and read the same on all three
pages:

| | Button | Line above it |
| --- | --- | --- |
| **Armed** | `>> BUY 12g 30s` in orange | *"This press spends 12g 30s"* |
| **Working** | `finding...`, greyed | *"nothing is being bought this moment"* |
| **Done** | `Bought 40` in green, **dead** | *"Done — bought 40 Lichbloom for 120g"* |
| Ready to start | `Buy 40 for 120g`, plain | *"Nothing bought yet"* |

The important one is **Done**. A finished purchase used to work out a fresh plan
straight away and put it on the button — same place, same shape, same wording,
differing only in a number. Now it leaves nothing armed: the button is disabled,
and buying more takes a deliberate press of **Best mix**, a click on a listing,
or a change to the quantity. Any of those clears the finished notice on the way
through.

The wording changes with the colour, not just the colour, and the disabled button
does the real work — so none of this depends on telling orange from green.

#### While it's running

The top of the Buy tab says which reagent it's on, how far down the list it is,
and how much of the budget is gone. Everything below is real — those are the
listings and the plan for that reagent — you just didn't type it in.

**Skip** leaves the reagent it's on and moves to the next. **Stop** ends the run
and prints what it managed to buy. Searching for something yourself while a run
is going is refused with a reason rather than quietly breaking it.

#### Reagents it never touches

Anything with **no price anywhere** is left out entirely and named before you
approve the run. The whole protection here is "no more than the list said", and
for something the list couldn't price there's no such figure to stay under —
buying it would mean paying whatever is being asked, which is exactly what you
wouldn't do by hand.

**Vials** never appear either. They come off a vendor; there's nothing to buy.

#### One thing to watch: the mailbox

Auction purchases arrive **by post** on 3.3.5a, and the shopping list counts your
bags. So a reagent you bought ten minutes ago and haven't collected still reads
as missing, and a second run would go and buy it again.

Within one run that can't happen — the list holds one entry per reagent, however
many recipes wanted it. Between runs it can, so anything the last run bought that
still shows as missing is named before you approve another one. It's named rather
than deducted: what's in the post isn't knowable from here.

**Collect your mail before pressing it twice.**

#### It still needs your clicks

WoW only honours a purchase while it's handling a real click, so a run is one
press per page of results — the same as buying one item by hand. Everything
between the presses is done for you; the presses are yours. See
[Why bidding needs a click](#why-bidding-needs-a-click).

---

## Training: the cheapest way to level

The **Training** tab answers one question and doesn't pretend to answer any
other: **which recipe gets my skill up for the least gold?**

| Column | Is |
| --- | --- |
| *(the name)* | Painted your tradeskill window's colour for it |
| **Can make** | How many your bags already cover |
| **Mats cost** | What one craft's reagents cost on the auction house |
| **Points** | Expected skill points from one craft |
| **Per point** | Mats ÷ points — **the headline, sorted cheapest first** |

So the top row is the cheapest way to level right now. Grey recipes are hidden by
default; they can't teach you anything.

**What the item is worth is deliberately absent.** You're not making these to
sell them, you're making them to get a number up. Netting the product's value off
the cost would flatter recipes that happen to be sellable over the ones that are
actually cheapest to train on — which is exactly the wrong ranking. If you want
to know what something earns, that's what the Profit page is for, and a
profession can be on both.

### Points, and how much to trust them

`Points` is how many skill points one craft is expected to give: `1` at orange,
`0.75` at yellow, `0.25` at green, nothing at grey, multiplied by the client's
own `numSkillUps` (which is 1 for nearly everything).

Those chances are the standard approximation — the client doesn't publish the
real curve. They're exactly good enough for the job they have, which is ranking
recipes against each other, and not good enough to promise how many Borean
Leather a particular point will take. Treat `Per point` as a comparison, not a
budget.

A recipe with an unpriced reagent shows `?` rather than a cheap-looking number: a
missing reagent counted as free would come out as the cheapest way in the game to
level, when it's only the one we know least about.

### Everything the window makes, not a chosen slice

Leatherworking keeps every recipe its window offers — leg armours, armour kits,
bags, drums, gear, and the intermediate leather half of it is built from.

That matters most for levelling. What's cheapest to train on is very often an
intermediate or a plain piece of armour nobody would ever buy, and a filter that
kept only the saleable things would hide exactly the rows someone working up
through the ranks needs to see.

### Thread and salt are counted, never costed

The same rule the vials get. Reagents that come off the leatherworking supply
vendor are left out of every cost — a trip to a vendor is not an auction house
decision, and pricing it would only muddy what a craft is really worth — but they
are still counted, and they get their own line on the shopping list so you leave
knowing how many to pick up.

Built in: the six threads (Coarse, Fine, Silken, Heavy Silken, Rune, Eternium) and
Salt. Nothing else. Alchemy's rule is a family rather than a list — **anything
whose name ends in "Vial"** is a vendor item, named or not. A list of five was a
list that had to be right, and it wasn't: Enchanted Vial was missing, so the
flasks using it went to the auction house for a container that costs a few
silver off a shelf. A vial this addon has never heard of now can't cost you
anything.

There is no API that says "a vendor sells this", so the rest is a
list, and it errs deliberately towards charging you: anything not on it is treated
as something you buy from other players. Getting it wrong the other way would call
an auction house item free and put the wrong recipe at the top of the page.

The dyes are deliberately off it — vendor goods in most of the world, but also
traded, and far more a tailoring reagent than a leatherworking one.

#### If your realm disagrees

`/snipe vendor <item name>` toggles any reagent, and your answer beats the built-in
list in both directions:

```
/snipe vendor Eternium Thread     -- now costed like anything else you buy
/snipe vendor Black Dye           -- now treated as vendor stock, left out of costs
/snipe vendor                     -- list the corrections you've made
```

Spell it as the game spells it — the name is matched exactly, and it's told you if
nothing on file uses it. It applies to both professions, because an item is either
on a vendor's shelf or it isn't.

### The colour of a recipe name

Recipe names are painted the same colour your tradeskill window paints them,
meaning the same thing:

| Name | Difficulty | Making one |
| --- | --- | --- |
| Orange | optimal | Almost always a skill point |
| Yellow | medium | Usually a skill point |
| Green | easy | Sometimes a skill point |
| Grey | trivial | Never a skill point |

A name in plain **white** has no difficulty recorded yet — open the profession
once and it fills in. White is not grey, and isn't allowed to look like it.

Because the name carries this now, the estimate marker moved onto the money: a
**`~`** before a price means it's an estimate rather than a figure from the last
scan. That's the more honest place for it anyway — a recipe isn't an estimate,
its price is.

The **Training** page hides grey recipes from the start. **Profit** shows
everything. Either way the tick box top right — **only what can still level me** —
overrides it, and is remembered per page, so a profession open in both modes can
be filtered in one and not the other. The count at the bottom right says how many
it hid.

It's a filter on your eyes and nothing else. A hidden recipe is still costed,
still holds whatever you typed into **Want**, and is still bought by a shopping
run — quietly dropping something you'd asked for forty of, because it had stopped
levelling you, would be far worse than showing it.

The colours are on the Profit page too — a recipe that still levels you is worth
knowing about even when you're making it for the money.

#### Where the colours come from

`GetTradeSkillInfo` returns the difficulty as its second value — `optimal`,
`medium`, `easy` or `trivial` — the same string the default UI colours its own
list by. BidSniper was already reading it to tell a header from a recipe, so this
costs nothing and needs no lookup table of item levels or skill ranges.

Two things follow from that:

* **It's a snapshot**, taken the last time that tradeskill window was open. It
  goes stale in one direction only — skill goes up, so a recipe recorded as
  orange might be yellow by now, never the other way round. That means the error
  always runs towards showing you something that no longer levels you, and never
  towards hiding one that would. Opening the profession again brings it up to
  date.
* **Recipes read before this existed have no colour**, so their names stay white
  and they are never hidden. Not knowing whether something would level you isn't the same
  as knowing it wouldn't. Open the window once and they fill in.

The colours are Blizzard's own values. If `Blizzard_TradeSkillUI` has been loaded
this session its live `TradeSkillTypeColor` table is used instead, so a client
that recoloured them stays consistent with itself.

`/snipe crafts` and `/snipe crafts leather` name the difficulty in words next to
each recipe.

### Adding a profession

A profession is a table in `BidSniperCraft.lua`: which tradeskill window feeds
it, which of the things that window makes are worth costing, which of its
reagents come off a vendor, where its recipe book lives, and which modes it's
offered in.

```lua
AddProfession{
    id         = "tailoring",
    label      = "Tailoring",          -- the selector button
    title      = "Tailoring",
    window     = "tailoring",
    makes      = "tailoring",
    modes      = { profit = true, training = true },   -- both, or either
    trade      = { ["Tailoring"] = true },
    subTypes   = nil,                  -- nil = everything the window makes
    recipesKey = "tailorRecipes",      -- its own book in BidSniperDB
    wantKey    = "tailorWant",
    vendor     = { ["Rune Thread"] = true },
    vendorOne  = "vendor item",
    vendorMany = "vendor items",
}
```

That's the whole change. It gets a button on every mode it lists, its own recipe
book, its own planned quantities, and it's picked up by scans, shopping runs and
the vendor overrides without anything else being touched.

A **mode** is a table in the same file: five column headings with their geometry,
a function that fills those five cells for a recipe, a sort order, and what to
put in the tooltip. Nothing in the page code knows the name of any profession,
and nothing in a profession knows the name of any column — which is what keeps
both lists open-ended.

### The rest works the same

Prices, the exact-or-estimate split, **Can make**, the **Want** column, the
shopping list, the bank never being deducted, and **Price & buy** all behave
exactly as described under [Crafting](#crafting). A shopping run started from a
page shops for that page's recipes and no others — it remembers which page sent
it, so switching tabs mid-run changes nothing. It also remembers the mode, so
when the auction house can't supply enough, a run started from Training cuts back
whatever levels you least cheaply rather than whatever sells worst.

One scan prices both pages. A price is a fact about an item rather than about a
profession, and Borean Leather costs what it costs whoever is asking, so the sweep
you were running anyway fills in both books at once.

---

## Scan methods

**GetAll** pulls the entire auction house in one request and takes seconds.
The client permits it once every 15 minutes.

**Page by page** asks the server to sort by current bid, cheapest first, and
walks every page of it. It used to stop once bids passed your **Max bid**; now
that Max bid is per item it can't — see [Max bid is per item](#max-bid-is-per-item).

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

**Profit** is Market minus what the row costs you. Since
[Ratio](#ratio-is-against-what-its-worth) is now measured against the same
market value, the two agree rather than pulling against each other — Ratio is
the multiple, Profit is the gold.

Profit shows **`?`** when there's no price on record. That is *not* the same as
a bad deal, and it's the case to be most careful with: nothing is known about
the item, so the buyout tells you nothing. Treat `?` as "find out first".

Sorting by Profit puts the best deals on top and unpriced items at the bottom.
The tooltip also shows profit after the 5% auction house cut.

Prices are cached for a day so the column fills instantly on load; unknown
prices are retried after ten minutes. `/snipe prices` forces a rebuild.

### Where the number came from

Three things can answer "what is one of these worth", and they answer from
different moments:

| Source | What it knows |
| --- | --- |
| **This addon's last scan** | The cheapest one it walked past. Freshest, but only covers what that sweep actually read |
| **Auctionator's database** | The cheapest its last scan saw, for everything. Complete, but only moves when Auctionator scans |
| **A remembered price** | Auctionator's answer from up to a day ago |

Hovering a row says which of the three priced it, which is the first question
worth asking whenever a Market figure disagrees with what Auctionator's own
window shows for the same item.

### Prices settle before anything is priced from them

A scan repaints the list as it runs, and painting a row prices it — so a sweep
used to finish with every row it found already carrying a Market and a Profit
worked out from the prices held *before* it started, and never recompute them.
The result was an addon that read forty thousand current prices and then showed
you last week's.

That order is now the other way round. When a scan ends:

1. what it saw is committed as this addon's prices;
2. every figure worked out from the old ones is thrown away, along with the
   day-old cache entries the sweep has just outdated;
3. Auctionator is handed the same dump and updates its own database from it;
4. **then** the rows are priced and sorted.

So the Market column and Auctionator's own window are looking at the same
auction house rather than at two different afternoons. A scan that was stopped
part way does the same with what it managed to read.

`/snipe prices` still forces the whole lot to be worked out again, which is
what to reach for after running Auctionator's scan by itself.

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

### Several copies under one entry

Bidding on eight identical auctions makes eight bids that share one identity, so
they share one row here — `on 8 of them, 15g in all`.

Being outbid on one of them does not mean losing the lot, and the row says which:
`3 outbid of 8`. Your Bids tab is asked first because it's first-hand and exact;
the mail can only ever account for as many refunds as you placed bids, so a
coincidental refund from somewhere else can't condemn a group you're still
winning.

You cannot outbid yourself. The server refuses a bid on an auction you already
lead, and BidSniper skips those rows before it gets that far — so an outbid on
something you just bid on is somebody else, every time.

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

## Troubleshooting

| What you see | What it is |
| --- | --- |
| A change to the addon did not take | `/reload` re-runs the files already listed in the `.toc`, and has been seen serving them from a stale cache. **Fully exit and start the client again** — always after a version that adds a file |
| Settings and results come back blank every session | The WoW folder is read-only, and the save fails silently — see [Install](#install). Change a filter, `/reload`, and check whether it stuck |
| Errors about a nil value after updating | A file was added to the `.toc` and the client has not re-read it. Restart |
| *"GetAll is on cooldown"* | That cooldown is about fifteen minutes and is shared by every addon on the client. `/snipe thorough` pages through instead, and misses nothing |
| A scan finds fewer auctions than you expect | Do not run Auctionator's or TSM's scanner at the same time — see [Scan methods](#scan-methods) |
| **Market** and **Profit** are empty | Nothing has priced those items yet. Run a scan, or install Auctionator; `/snipe prices` rebuilds the column |
| A Market price disagrees with Auctionator | Hover the row — it names which of the three sources priced it. `/snipe prices` forces a rebuild |
| A stack is greyed out and unclickable after posting | The client's item lock was left set; relogging clears it. The Sell tab now waits for locks rather than reaching into a slot the client is still using |
| You have fewer items than a run reported buying | Auction purchases arrive **by post**. Check the gold: if the full total left your purse, the rest is in the mailbox |
| A craft came up short | The report at the end names the reagent that limited it, with the counts and the cause |
| A shopping run bought nothing | Its status line says why, and the report says it reagent by reagent. Most often everything for sale was over your `+%` limit |

---

## Commands

| Command | Does |
| --- | --- |
| `/snipe` | Toggle the window (`/bidsniper` also works) |
| `/snipe scan` | Start a complete new scan |
| `/snipe resume` | Carry on from where a scan was interrupted |
| `/snipe auto` \| `paged` \| `getall` \| `thorough` | Choose the scan method |
| `/snipe piggyback` | Read another addon's full scan as if it were ours |
| `/snipe atrsync` | Let Auctionator make our GetAll, so both update from it |
| `/snipe buy` | Open the Buy tab |
| `/snipe buy <item>` | Open it and search for that item straight away |
| `/snipe buyplan` | Print what the current plan would buy, and for how much |
| `/snipe shop` | Buy the whole shopping list — it drives the Buy tab for you |
| `/snipe shoplist` | Print what a shopping run would buy, and for how much |
| `/snipe shopmax <n>` | How far over its usual price a reagent still counts as fair (default 20%) |
| `/snipe shopstop` | End the shopping run that's going |
| `/snipe shopped` | Print the report from the last shopping run again |
| `/snipe craft` | Open the Profit tab (`/snipe profit` too) |
| `/snipe training` | Open the Training tab (`/snipe level` too) |
| `/snipe flasks` | Profit tab, on alchemy |
| `/snipe leather` | Training tab, on leatherworking |
| `/snipe recipes` | Read whatever tradeskill window is open into its own list |
| `/snipe crafts` | Print the flask and elixir costings to chat |
| `/snipe crafts leather` | Print the leatherworking costings to chat |
| `/snipe vendor <item>` | Mark a reagent as vendor-bought, or list your corrections |
| `/snipe sell` | Open the Sell tab |
| `/snipe sellplan` | Print what that patch would post, and for how much |
| `/snipe mybids` | Open the record of every bid you've placed |
| `/snipe checkbids` | Fast check: your Bids tab and your mail, no AH queries |
| `/snipe findbids` | Slow check: search the auction house itself |
| `/snipe listbids` | Print that record to chat |
| `/snipe mail` | Settle ended bids from the mail (at a mailbox) |
| `/snipe bids` | Ask the server what you've actually bid on |
| `/snipe syncbids` | Rebuild the "already bid" marks from the server |
| `/snipe clearmarks` | Drop every "already bid" mark |
| `/snipe prices` | Forget cached prices and rebuild Profit |
| `/snipe refresh` | Re-apply the filters, drop ended auctions, rebuild Profit |
| `/snipe debug` | Scan method, saved results, why GetAll is or isn't used |
| `/snipe layout` | Print where the filter boxes actually are |
| `/snipe why <n>` | Say which filter dropped row *n* of the Browse list |
| `/snipe peek <n>` | Read row *n* of the Browse list, bidding on nothing |
| `/snipe try <n>` | Test-bid row *n* of the Browse list, showing every input |
| `/snipe trysel <n>` | Same, but select the row first |
| `/snipe help` | Print every command in chat |
| `/snipe reset` | Restore defaults and reload |

Shorter names for the same things: `newscan` for `scan`, `profit` for `craft`,
`level` for `training`, `alchemy` for `flasks`, `lw` for `leather`, and
`leathercrafts` for `crafts leather`.

---

## Saved data

Everything lives in `BidSniperDB` — settings, wishlist, categories, results,
resume point, price cache, your recent Buy searches, and the list of your
characters. Results persist across reloads and relogs, so a scan is never lost
to a UI reload.

Buy results are the exception: a search is live prices, and stale prices are
worth nothing, so the listing table is not saved. The searches themselves are,
under **Recent**.

Each profession keeps its own recipe book and its own planned quantities; the
harvested prices are shared, since a price is about an item rather than about a
trade. Your `/snipe vendor` corrections are saved too, and outrank the built-in
lists, as does the per-profession **only what can still level me** tick.

A shopping run keeps only its margin setting. What a run bought is remembered for
the session, so pressing **Price & buy** again can warn you about purchases
still sitting in the post — but it goes at a reload, and after one the list
counts your bags and nothing else.

Sell keeps its bags and slot range, its undercut and duration, the market quotes
from its last price check (for an hour, then dropped), and a **lot size per
item**. The lot sizes are keyed by item name and shared by every character
on the account, which is the point — how many Saronite Ore belong in one auction
is a fact about the ore, not about who is holding it.

Two things to know:

* WoW only writes saved variables on a clean `/reload`, logout or exit. A crash
  or alt-F4 loses whatever changed since the last write.
* The folder must be writable — see the warning under [Install](#install).
