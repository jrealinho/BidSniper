BidSniper - for WoW 3.3.5a (WotLK / Warmane)
============================================

Scans the whole auction house and lists only the auctions where the bid is
far below the buyout - the 1 silver bid / 15 gold buyout kind.


USING IT
--------
1. Open the auction house. The window opens with it (turn that off with the
   "Open with AH" checkbox).
2. Press "Scan AH" and wait.
3. Results are sorted by ratio, biggest first. Click any column header to
   re-sort.

On a result row:
  left click   - bid on it (a confirmation box shows the exact amount first)
  ctrl click   - bid immediately, no confirmation box
  right click  - search that item in the normal Browse tab
  shift click  - link the item into chat

Each row has a tick box. "Select all" ticks every row at once and turns into
"Select none"; untick the handful you do not want, then press "Bid selected".
The line above the buttons keeps count and shows what the ticked rows add up
to, so you can see the damage before you commit.

"Bid selected" works through the ticked rows ONE CLICK PER AUCTION. This is
not a design choice - see WHY BIDDING NEEDS A CLICK below.

Press it once to start and approve the count and total. From then on the
button reads "BID 1s 20c": each press bids that auction and immediately lines
up the next one, so you sit and click the same spot. It reads "preparing..."
for the moment it is fetching the next auction. The line above shows progress,
and the left button becomes "Stop batch".

"Skip" appears beside BID while a batch is running. It passes on the auction
currently on the button and moves to the next, and unticks that row so a later
run leaves it alone. It also cancels a lookup that is dragging, so one awkward
item cannot hold up the queue.

Auctions are grouped by item, so a run of the same item reuses one set of
results and those presses come back instantly.

It skips any auction whose bid has risen since the scan, stops if you run out
of gold, and stops if the running total would pass the amount you approved.
A green * marks rows you have already bid on, and those rows cannot be ticked.


RE-BIDDING
----------
"Re-bid" (top right, next to Scan AH) asks the server which of your bids have
been beaten and queues every one of them for the BID button. It needs no scan
and no saved results - it works straight off your own bid list, so it is fast
and it covers bids you placed by any means, not just ones this addon made.

Auctions that have climbed past your Max bid are left alone, as are ones where
the next bid would cost more than simply buying the item out. Both are counted
and reported so you know what was passed over.

Because it reads your live bid list, an auction you have already won back is
never offered again, however many times you press Re-bid.


WHY BIDDING NEEDS A CLICK
-------------------------
PlaceAuctionBid is a protected function. WoW only lets an addon call it while
the game is handling a real mouse click or key press. Called from a timer or
an event, the client silently drops it and prints "Interface action failed
because of an AddOn" - the call reports no error, so the addon cannot even
tell that nothing happened.

So no addon can bid on a list of auctions unattended, on any client. What an
addon can do is everything around the bid: find the auctions, work out the
price, and have the next one ready the instant you click. That is what the BID
button is.

Results are saved, so a /reload or a relog keeps your last scan.


FILTERS
-------
Min ratio     How many times bigger the buyout has to be than the bid.
              10 means "buyout is at least 10x the bid".
Max bid       Ignore anything that costs more than this to bid on.
              Accepts 50, 50g, 1s50c ... plain numbers mean gold. 0 = no limit.
Min buyout    Ignore junk. The buyout must be at least this much.
Min quality   Minimum item quality. Click the button to step up through the
              qualities, right-click to step back.
Only unbid    Only auctions nobody has bid on, so the starting bid is what
              you actually pay.
Ending < 2h   Only Short and Medium time left - the ones worth sniping now.
Hide mine     Skip your own auctions and ones you are already winning.

Defaults: ratio 10x, max bid 50g, min buyout 1g. Both of your examples pass
those - 1s bid / 15g buyout is 1500x, 2g bid / 100g buyout is 50x.


COMMANDS
--------
/snipe            toggle the window   (/bidsniper works too)
/snipe scan       start a scan
/snipe auto       GetAll if the realm allows it, otherwise page by page (default)
/snipe paged      always scan page by page
/snipe getall     always try GetAll
/snipe reset      restore defaults and reload the UI


AUCTIONS THAT HAVE MOVED ON
---------------------------
A saved scan is a photograph, and the auction house keeps changing after it.
Every result records when it was seen, and the time left it had at the time,
which together say how long it could possibly still be running.

  gone   past that point - it sold, was bought out or was cancelled. Greyed
         out, and never picked up by Select all.
  stale  more than halfway through, so treat it with suspicion.

Results that are certainly gone are dropped when you log in, and it says how
many. Nothing is thrown away that could still be live.

None of this replaces the real check: a bid always re-reads the auction from
the server immediately before spending, and refuses if anything has changed.


CATEGORY
--------
The Category button limits a scan to one auction house category - Trade Goods,
Gem, Recipe and so on - which is far quicker than reading the whole house.
GetAll cannot be filtered, so picking a category always scans page by page;
that is still much less work than a full scan.

The list comes from the auction house itself, so open one once before the
button will offer anything.


WISHLIST
--------
For items you check often. Press "Wishlist" to open the panel, then type a
name or shift-click an item into the box and press Add. Names are kept sorted
and saved between sessions; the X beside a row removes it.

"Scan wishlist" searches for each item on the list in turn and applies the
same filters as a normal scan. It ignores the Category setting - the list says
what to look for. This is the quickest scan there is, so it is the one to run
when you just want to check on the handful of things you care about.


STOPPING AND RESUMING
---------------------
If a scan is interrupted - you pressed Stop, you closed the auction house, or
the server stopped answering - the position is kept along with everything
found so far. The Scan button then reads "Resume scan" and carries on from
that page.

  click        resume, keeping the results already found
  right-click  throw the resume point away and scan from the start
  shift-click  same as right-click

This survives a /reload and a relog, so a scan interrupted last night can be
finished today. It is a page number, not a bookmark on particular auctions, so
if the auction house has changed a lot in between, a fresh scan is the honest
choice.

Changing a filter and then resuming is allowed, but the older results were
matched against the old settings; it says so when that happens.

A GetAll scan is a single request with no halfway point, so there is nothing
to resume - a resumed scan always continues page by page.


SCAN METHODS
------------
Page by page asks the server to sort by current bid, cheapest first, then
stops as soon as the bids pass your Max bid - everything after that point is
too expensive to be worth reading. So the lower your Max bid, the shorter the
scan. With Max bid at 0 (no limit) there is no cutoff and it reads the whole
auction house, which is slow.

GetAll pulls everything in one request and takes seconds, but the server has
to allow it and the client only permits it once every 15 minutes. On "auto"
BidSniper tries GetAll and drops back to page by page if the realm ignores it,
so nothing is lost by leaving it on auto.

While scanning, don't use Auctionator's or TSM's scanners at the same time -
they all share the same query channel.


MARKET AND PROFIT
-----------------
A huge buyout is not proof an item is worth anything. Anyone can list junk at
100g and the ratio will look wonderful. Market and Profit are the honest check.

Market  what Auctionator reckons the stack is worth.
Profit  Market minus the bid - what you actually stand to make. Green for a
        gain, red for a loss.

Profit shows "?" when Auctionator has no price on record for that item. That
is NOT the same as a bad deal, and it is the case to be most careful with:
nothing is known about the item, so the buyout tells you nothing at all. Treat
"?" as "find out first", not as "no profit".

Click the Profit header to sort by it - best deals on top, unpriced items at
the bottom. The row tooltip also shows the profit after the 5% auction house
cut on the resale.

All of this needs Auctionator loaded with its own scan data. Without it every
row reads "?". Run an Auctionator full scan once and the column fills in.
