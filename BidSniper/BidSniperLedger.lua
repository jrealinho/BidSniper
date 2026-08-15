--[[--------------------------------------------------------------------------
	BidSniper - persistent bid ledger

	The auction house cannot tell you what happened to a bid while you were
	logged out. GetBidderAuctionItems() only ever returns auctions you are
	currently winning; auctions you were outbid on are kept by the client in
	memory for the current session only, so after a relog they are simply
	absent from the Bids tab with nothing left to say they were ever there.

	So we keep our own record. Every bid is written down as it is placed, and
	each visit to the auction house checks that record against three sources,
	in order of how much each one can actually prove:

	  the Bids tab      leading, or outbid and still live
	  the auction house still up = outbid while we were away, and still
	                    sitting there to be bid on again
	  the mailbox       item delivered = won, gold refunded = lost

	An auction is identified by item, stack size, starting bid and buyout, all
	of which are fixed for its whole life. The current bid is deliberately no
	part of that: it moves the instant somebody outbids you, which is precisely
	the event this is built to survive.
----------------------------------------------------------------------------]]

local BS = BidSniper

local format, floor = string.format, math.floor
local ITEMS_PER_PAGE   = 50
local SWEEP_MAX_PAGES  = 10		-- a very common name is not worth chasing forever
local QUERY_TIMEOUT    = 15
local KEEP_CLOSED_DAYS = 14		-- how long a settled entry stays on the list

--[[
	States, and what each one is worth to you:

	  pending   bid sent, the server has not confirmed it yet
	  leading   the Bids tab says you are the high bidder
	  outbid    somebody is ahead of you and the auction can still be running -
	            the one state that is directly actionable, because you can re-bid
	  missing   gone from the Bids tab and not yet explained
	  won       the mailbox delivered the item
	  lost      you were outbid and the auction can no longer be running
	  ended     off the auction house with no trace in the mail
]]
local CLOSED = { won = true, lost = true, ended = true }

function BS.LedgerClosed(e)
	return CLOSED[e.state] and true or false
end

BS.ledgerStateText = {
	pending = "|cffffcc00sent|r",
	leading = "|cff00ff00winning|r",
	outbid  = "|cffff8800outbid|r",
	missing = "|cffffffffchecking|r",
	won     = "|cff00ff00won|r",
	lost    = "|cffff4444lost|r",
	ended   = "|cff777777ended|r",
}

--=============================================================================
--  identity
--=============================================================================

--[[
	The identifying part of an item link is the item id and the random suffix.
	The rest of a link - the unique id, the level it was linked at - can differ
	between two sightings of the same auction, so none of it belongs in a key
	that has to match across sessions.
]]
local function ItemKeyPart(link, name)
	if link then
		local id, suffix = string.match(link, "Hitem:(%d+):%d+:%d+:%d+:%d+:%d+:(%-?%d+)")
		if id then return id .. ":" .. suffix end
	end
	return "n:" .. tostring(name or "?")
end

--[[
	Every part of this is fixed for the auction's whole life. minBid is the
	seller's starting price, which the server sends separately from the current
	bid, so it survives being outbid - and it is what tells apart two auctions
	of the same item that happen to share a buyout.

	Deliberately absent: the seller. GetAuctionItemInfo hands back a nil owner
	often enough that requiring it would lose auctions that are perfectly real,
	which is the same reason SameAuction in the core does not use it either.
]]
function BS.BidKey(link, name, count, minBid, buyout)
	return format("%s/%d/%d/%d", ItemKeyPart(link, name),
		floor(count or 1), floor(minBid or 0), floor(buyout or 0))
end

-- "3h ago", for a stamp made by time()
function BS.Ago(stamp)
	if not stamp then return "?" end
	local secs = time() - stamp
	if secs < 60 then return "just now" end
	if secs < 3600 then return format("%dm ago", floor(secs / 60)) end
	if secs < 86400 then return format("%dh ago", floor(secs / 3600)) end
	return format("%dd ago", floor(secs / 86400))
end

--[[
	Could this auction still be running at all?

	Bounded exactly the way saved scan results are: an auction seen in a given
	time-left bracket cannot outlive that bracket. Once it has, being outbid on
	it is final, and no amount of searching the auction house will turn it up.
]]
function BS.LedgerCouldStillRun(e)
	if not e.placed then return true end
	local life = (BS.MAX_LIFE and BS.MAX_LIFE[e.timeLeft or 4]) or (48 * 3600)
	return (time() - e.placed) <= life
end

-- Bids belong to a character, but the saved variables are account-wide.
local function Me()
	local name  = UnitName("player") or "?"
	local realm = GetRealmName and GetRealmName() or ""
	if realm and realm ~= "" then return name .. " - " .. realm end
	return name
end

BS.LedgerOwner = Me

function BS:Ledger()
	if not self.db then return {} end
	self.db.bidLog = self.db.bidLog or {}
	return self.db.bidLog
end

-- entries for this character that have not been settled yet
function BS:LedgerOpen()
	local out, who = {}, Me()
	for _, e in ipairs(self:Ledger()) do
		if e.char == who and not BS.LedgerClosed(e) then out[#out + 1] = e end
	end
	return out
end

local function SetState(e, state, note)
	if e.state ~= state then
		e.state   = state
		e.stateAt = time()
	end
	e.note = note
end

BS.LedgerSetState = SetState

--=============================================================================
--  recording
--=============================================================================

--[[
	Called from VerifyAndBid the moment PlaceAuctionBid goes out, with the
	values read back from the auction row itself rather than from the scan, so
	what we store is what we actually bid on.

	The entry starts as "pending" and is only promoted once the server answers.
	A refusal removes it again, so a bid the server threw away never becomes a
	ledger entry that later reads as mysteriously vanished.
]]
function BS:LedgerRecord(info)
	local log = self:Ledger()
	local key = BS.BidKey(info.link, info.name, info.count, info.minBid, info.buyout)
	local who = Me()
	local now = time()

	--[[
		Two ways to arrive at an entry that is already open, and the price tells
		them apart.

		A re-bid on an auction we were outbid on always costs more than last
		time - the server's minimum increment sees to that - and belongs on the
		same entry rather than opening a second one for one auction.

		The same price to the copper is a different thing: a second identical
		auction. Eight bags posted at one price are eight auctions this API
		cannot tell apart, and they all share a key, so the entry carries how
		many were bid on rather than quietly reading as one.
	]]
	local bid = floor(info.myBid or 0)
	for _, e in ipairs(log) do
		if e.key == key and e.char == who and not BS.LedgerClosed(e) then
			if bid == e.myBid then
				e.copies = (e.copies or 1) + 1
			else
				e.myBid = bid
			end
			e.placed = now
			e.owner  = info.owner or e.owner
			e.link   = info.link or e.link
			SetState(e, "pending", nil)
			return e
		end
	end

	local e = {
		key      = key,
		char     = who,
		link     = info.link,
		name     = info.name,
		texture  = info.texture,
		count    = floor(info.count or 1),
		quality  = info.quality or 1,
		owner    = info.owner,
		minBid   = floor(info.minBid or 0),
		buyout   = floor(info.buyout or 0),
		myBid    = floor(info.myBid or 0),
		copies   = 1,		-- identical auctions bid on at this price
		timeLeft = info.timeLeft,
		placed   = now,
		state    = "pending",
		stateAt  = now,
	}
	log[#log + 1] = e
	return e
end

-- the server took the bid
function BS:LedgerConfirm(e)
	if not e then return end
	e.seenAt = time()
	if e.state == "pending" then
		SetState(e, "leading", "the server accepted the bid")
	end
end

-- the server refused it: there is nothing to keep track of
function BS:LedgerDrop(e)
	if not e then return end
	local log = self:Ledger()
	for i = #log, 1, -1 do
		if log[i] == e then
			table.remove(log, i)
			return
		end
	end
end

function BS:LedgerForget(e)
	self:LedgerDrop(e)
	self:RefreshLedger()
end

-- settled entries are worth reading for a while and then just clutter
function BS:PruneLedger()
	local log = self:Ledger()
	local cutoff = time() - KEEP_CLOSED_DAYS * 24 * 3600
	local dropped = 0
	for i = #log, 1, -1 do
		local e = log[i]
		if BS.LedgerClosed(e) and (e.stateAt or 0) < cutoff then
			table.remove(log, i)
			dropped = dropped + 1
		end
	end
	return dropped
end

--=============================================================================
--  step 1: the Bids tab
--=============================================================================

--[[
	Always ask the server rather than reading whatever the client happens to
	still hold. A stale bidder list would report bids as settled that are not,
	and this is the one place where being wrong costs you an auction.
]]
function BS:CheckBids(quiet)
	if not self.atAH then
		if not quiet then self:Print("Open the auction house first.") end
		return
	end
	if #self:LedgerOpen() == 0 then
		if not quiet then
			self:Print("No bids on file. Anything you bid on from now on is recorded.")
		end
		return
	end
	self.wantLedger  = true
	self.ledgerQuiet = quiet
	self:SetStatus("Checking your bids against the server...")
	GetBidderAuctionItems()
end

--[[
	Reconcile the ledger against what the server says we are involved in right
	now. Anything the Bids tab still knows about is settled here and needs no
	further work; anything it has forgotten becomes "missing" and is handed on
	to the auction-house sweep.
]]
function BS:ReconcileLedger(quiet)
	local live = {}
	local n = GetNumAuctionItems("bidder") or 0

	for i = 1, n do
		local name, _, count, _, _, _, minBid, minIncrement, buyout, bidAmount, highBidder =
			GetAuctionItemInfo("bidder", i)
		if name then
			local key = BS.BidKey(GetAuctionItemLink("bidder", i), name, count, minBid, buyout)
			local cur = live[key]
			--[[
				Two auctions identical down to the starting bid collapse onto
				one key. They are interchangeable for our purposes, so the only
				question is which reading to keep, and "winning" is the safer
				one to report: it never sends you off to re-bid something you
				are already ahead on.
			]]
			if not cur or (highBidder and not cur.highBidder) then
				live[key] = {
					highBidder   = highBidder and true or false,
					bidAmount    = bidAmount or 0,
					minIncrement = minIncrement or 0,
				}
			end
		end
	end

	local leading, outbid, missing = 0, 0, 0
	local now = time()

	for _, e in ipairs(self:LedgerOpen()) do
		local l = live[e.key]
		if l then
			e.seenAt  = now
			e.curBid  = l.bidAmount
			e.nextBid = (l.bidAmount > 0) and (l.bidAmount + l.minIncrement) or e.minBid
			if l.highBidder then
				SetState(e, "leading", "you are the high bidder")
				leading = leading + 1
			else
				SetState(e, "outbid", "outbid - still on the auction house")
				outbid = outbid + 1
			end
		elseif e.state == "pending" and (now - (e.placed or 0)) < 60 then
			-- sent moments ago; the bidder list may just not have caught up yet
		else
			SetState(e, "missing", "gone from your Bids tab - not yet explained")
			missing = missing + 1
		end
	end

	--[[
		The mailbox costs no auction-house query at all, so it gets its say
		before anything is reported. It turns most of the "missing" pile into a
		real answer without a single round trip, which is the difference
		between this being instant and it grinding through the auction house.
	]]
	self:ResolveLedgerFromMail(true)

	leading, outbid, missing = 0, 0, 0
	for _, e in ipairs(self:LedgerOpen()) do
		if e.state == "leading" then leading = leading + 1
		elseif e.state == "outbid" then outbid = outbid + 1
		elseif e.state == "missing" then missing = missing + 1 end
	end

	self:PruneLedger()
	self:RefreshLedger()

	--[[
		Even the quiet pass speaks up when there is something to act on. Being
		told on walking up to the auction house that three bids need attention
		is the entire reason this exists.
	]]
	if not quiet or outbid > 0 or missing > 0 then
		self:Print(format("Bids: |cff00ff00%d winning|r, |cffff8800%d outbid|r, "
			.. "%d unaccounted for.", leading, outbid, missing))
	end

	--[[
		Deliberately no auction-house sweep here. That is the slow path, and
		running it unasked is what made walking up to the auction house feel
		like the addon had hung. It is now something you ask for, and a scan
		settles the same entries for nothing on the way past.
	]]
	if missing > 0 and not quiet then
		self:Print("For the unaccounted-for ones the auction house has to be asked "
			.. "directly: |cffffffff/snipe findbids|r, or press Scan AH and they "
			.. "settle themselves at no cost.")
	end

	return leading, outbid, missing
end

--=============================================================================
--  step 2: whatever a scan walks past, for free
--=============================================================================

--[[
	A scan already reads every auction it pages through, so checking each row
	against the ledger costs a hash lookup and not one byte of extra server
	traffic. This is far and away the cheapest way to settle a bid: a scan you
	were going to run anyway resolves the ledger as a side effect of running.

	The name index exists to keep that cost honest. A GetAll hands back the
	whole house, and building a full key for every row of it - which means an
	item link per row - would be real work. The item name is already in hand
	from the row we just read, so a name miss costs one string lookup and stops
	there, and only a name hit pays for the link.
]]
--[[
	Every open entry, "winning" ones included.

	They used to be left out, on the reasoning that the Bids tab had already
	vouched for them. That was wrong, and wrong in the one case that matters
	most: "winning" is a snapshot of when it was last looked at, and being
	outbid is precisely the event that makes it stale. Skipping those entries
	meant a scan run seconds after somebody outbid you walked straight past the
	row that said so, and the ledger went on claiming you were ahead until you
	pressed Check bids.

	A row the scan is reading anyway is the cheapest evidence there is, and it
	is first-hand: highBidder on that row is the server's own answer.
]]
function BS:BuildLedgerWatch()
	local watch, names, n = {}, {}, 0
	for _, e in ipairs(self:LedgerOpen()) do
		watch[e.key] = e
		names[e.name] = true
		n = n + 1
	end
	self.ledgerWatch       = (n > 0) and watch or nil
	self.ledgerWatchNames  = (n > 0) and names or nil
	self.ledgerWatchHits   = 0
	self.ledgerWatchOutbid = 0
	return n
end

-- called from Evaluate for every row a scan reads, ahead of any filter
function BS:LedgerSawAuction(key, minBid, bidAmount, minIncrement, highBidder)
	local e = self.ledgerWatch and self.ledgerWatch[key]
	if not e then return end

	e.seenAt  = time()
	e.curBid  = bidAmount or 0
	e.nextBid = (bidAmount and bidAmount > 0)
		and (bidAmount + (minIncrement or 0)) or minBid
	if highBidder then
		SetState(e, "leading", "you are the high bidder")
	else
		-- the state this exists to catch: it was won off you and the auction is
		-- still there to be taken back
		if e.state ~= "outbid" then
			self.ledgerWatchOutbid = (self.ledgerWatchOutbid or 0) + 1
		end
		SetState(e, "outbid", "outbid - the last scan found it still up")
	end

	self.ledgerWatch[key] = nil
	self.ledgerWatchHits  = (self.ledgerWatchHits or 0) + 1
end

--[[
	`complete` says whether the scan actually read the whole auction house. It
	matters enormously: only a scan that looked everywhere can conclude that an
	auction it did not see is gone. A scan narrowed by categories, cut short at
	your max bid, or aimed at a wishlist simply did not look, and closing bids
	on that basis would settle auctions that are still perfectly live.
]]
function BS:LedgerScanFinished(complete)
	local watch  = self.ledgerWatch
	local hits   = self.ledgerWatchHits or 0
	local outbid = self.ledgerWatchOutbid or 0
	self.ledgerWatch, self.ledgerWatchNames = nil, nil
	self.ledgerWatchHits, self.ledgerWatchOutbid = nil, nil
	if not watch then return end

	local ended = 0
	if complete then
		for _, e in pairs(watch) do
			if e.state == "missing" or e.state == "outbid" then
				SetState(e, "ended", "a full scan of the house did not find it")
				ended = ended + 1
			end
		end
	end

	if hits > 0 or ended > 0 then
		self:Print(format("Bids settled by that scan, at no extra cost: "
			.. "%d still up, %d ended.", hits, ended))
		-- the one part of that worth acting on gets its own line
		if outbid > 0 then
			self:Print(format("|cffff8800%d of them you have been outbid on|r - "
				.. "press |cffffffffRe-bid|r to take them back.", outbid))
		end
		self:RefreshLedger()
	end
end

--=============================================================================
--  step 3: ask the auction house directly (the slow one)
--=============================================================================

--[[
	The Bids tab cannot show an auction you were outbid on before this session
	began, but the auction is still there. Searching for it by name and looking
	for our key among the results separates "you were outbid while logged out,
	go and bid again" from "this auction is over".

	One query per distinct item name covers every missing entry for that item.
]]
function BS:StartLedgerSweep(auto)
	if not self.atAH then
		if not auto then self:Print("Open the auction house first.") end
		return
	end
	if self.scanning or self.bidSearch or self.batch or self.ledgerSweep then
		if not auto then self:Print("Finish the current scan or batch first.") end
		return
	end

	-- the mail may already know, and it is free
	self:ResolveLedgerFromMail(true)

	-- group by name: one lookup answers for every entry sharing it
	local byName, order = {}, {}
	for _, e in ipairs(self:LedgerOpen()) do
		if e.state == "missing" then
			local list = byName[e.name]
			if not list then
				list = {}
				byName[e.name] = list
				order[#order + 1] = e.name
			end
			list[#list + 1] = e
		end
	end

	if #order == 0 then
		if not auto then self:Print("Nothing to check: every bid is accounted for.") end
		return
	end

	-- cheapest current bid first, so the sweep can give up on an item the moment
	-- the page it is reading has priced past every auction it is looking for
	self.ledgerSorted = self:ApplyBidSort()

	self.ledgerSweep = {
		names = order, byName = byName, i = 1, page = 0,
		found = 0, gone = 0, leading = 0,
	}
	self.ledgerQueryPending = true
	self.ledgerThrottle     = 0
	self:SetStatus(format("Checking %d item%s against the auction house...",
		#order, #order == 1 and "" or "s"))
end

function BS:StopLedgerSweep(reason)
	self.ledgerSweep         = nil
	self.ledgerQueryPending  = false
	self.ledgerAwaiting      = false
	if reason then self:SetStatus(reason) end
end

-- fired from OnUpdate once the client will accept another query
function BS:LedgerSweepQuery()
	local s = self.ledgerSweep
	if not s then return end
	self.ledgerAwaiting  = true
	self.ledgerQueryTime = GetTime()
	--[[
		A bid lookup skips its round trip when it believes the auction list
		already holds its item. We are about to replace that list, so drop the
		claim or the next bid would be located against our results.
	]]
	self.loadedQueryName = nil
	QueryAuctionItems(s.names[s.i], nil, nil, nil, nil, nil, s.page, nil, nil)
end

-- results are in: is any of this item's missing auctions among them?
function BS:LedgerSweepResults()
	local s = self.ledgerSweep
	if not s then return end

	local numBatch, total = GetNumAuctionItems("list")
	total = total or 0

	local wanted  = s.names[s.i]
	local entries = s.byName[wanted] or {}

	for i = 1, (numBatch or 0) do
		local name, _, count, _, _, _, minBid, minIncrement, buyout, bidAmount, highBidder =
			GetAuctionItemInfo("list", i)
		-- The auction house matches names by substring, so a search for "Copper
		-- Bar" also hands back Copper Bar Rack and everything else carrying the
		-- words. Only an exact name can be one of ours, and checking that first
		-- keeps the item link - the expensive part of a key - off every row that
		-- came along for the ride.
		if name == wanted then
			local key = BS.BidKey(GetAuctionItemLink("list", i), name, count, minBid, buyout)
			for _, e in ipairs(entries) do
				if e.state == "missing" and e.key == key then
					e.seenAt  = time()
					e.curBid  = bidAmount or 0
					e.nextBid = (bidAmount and bidAmount > 0)
						and (bidAmount + (minIncrement or 0)) or minBid
					if highBidder then
						--[[
							We lead it after all: the Bids tab was read before
							the server had caught up with our own bid.
						]]
						SetState(e, "leading", "you are the high bidder")
						s.leading = s.leading + 1
					else
						SetState(e, "outbid",
							"outbid while you were away - still up, bid again")
						s.found = s.found + 1
					end
				end
			end
		end
	end

	--[[
		A common name spans pages, so keep turning them while anything is still
		unresolved - but stop the moment the answer cannot be ahead.

		Sorted cheapest current bid first, an auction is on a later page only if
		it costs more to bid on than everything read so far. Every auction we are
		hunting costs less to bid on than its own buyout, so once the dearest row
		on this page has passed the dearest buyout among them, none of them can
		still be coming. An auction with no buyout has no such bound and turns
		the shortcut off.
	]]
	local unresolved, ceiling = false, 0
	for _, e in ipairs(entries) do
		if e.state == "missing" then
			unresolved = true
			if (e.buyout or 0) <= 0 then ceiling = nil
			elseif ceiling and e.buyout > ceiling then ceiling = e.buyout end
		end
	end

	if unresolved and ceiling and self.ledgerSorted and (numBatch or 0) > 0 then
		local _, _, _, _, _, _, minBid, _, _, bidAmount =
			GetAuctionItemInfo("list", numBatch)
		local pageBid = (bidAmount and bidAmount > 0) and bidAmount or (minBid or 0)
		if pageBid > ceiling then unresolved = false end
	end

	local nextPage = s.page + 1
	if unresolved and nextPage * ITEMS_PER_PAGE < total and nextPage < SWEEP_MAX_PAGES then
		s.page = nextPage
		self.ledgerQueryPending = true
		self.ledgerAwaiting     = false
		return
	end

	-- done with this name: whatever is still missing is not on the auction house
	for _, e in ipairs(entries) do
		if e.state == "missing" then
			SetState(e, "ended", "not on the auction house - check your mail")
			s.gone = s.gone + 1
		end
	end

	s.i    = s.i + 1
	s.page = 0
	self.ledgerAwaiting = false

	if s.i > #s.names then
		local found, gone = s.found, s.gone
		self:StopLedgerSweep("")
		self:RefreshLedger()
		--[[
			These cannot be reached by the Re-bid button: it works off the Bids
			tab, and the whole point of these is that the Bids tab has forgotten
			them. Clicking the row searches Browse instead, which can still find
			them because they are genuinely still up.
		]]
		if found > 0 then
			self:Print(format("|cffff8800%d auction%s you were outbid on while away "
				.. "%s still up|r - click it in My bids to find it in Browse.",
				found, found == 1 and "" or "s", found == 1 and "is" or "are"))
		end
		if gone > 0 then
			self:Print(format("%d bid%s have ended. Open a mailbox and they will be "
				.. "sorted into won and lost.", gone, gone == 1 and "" or "s"))
		end
		self:SetStatus(format("Bid check done: %d still biddable, %d ended.", found, gone))
		return
	end

	self.ledgerQueryPending = true
	self:SetStatus(format("Checking the auction house (%d/%d)...", s.i, #s.names))
end

--=============================================================================
--  step 3: the mailbox
--=============================================================================

--[[
	The mailbox is the fastest source there is, and the only one that persists
	by itself: it costs no auction-house query at all, and the mail sits there
	for thirty days whether you log out or not.

	Two kinds of mail matter, and they mean quite different things:

	  the item itself   we won it. Auction-won mail is only sent when an
	                    auction ends, so this is final.

	  our gold back     we were outbid. This is sent the *instant* somebody
	                    outbids us, not when the auction ends - so it does not
	                    mean the auction is over, and very often it is still
	                    sitting there to be bid on again. Only when the auction
	                    can no longer be running (see LedgerCouldStillRun) does
	                    being outbid become final.

	Getting that second one wrong is how a still-winnable auction ends up
	reported as settled, so the distinction is worth the extra state.

	Each mail settles at most one entry, so two bids on identical auctions
	cannot both claim the same refund.
]]
function BS:ResolveLedgerFromMail(quiet)
	local pending = {}
	for _, e in ipairs(self:LedgerOpen()) do
		--[[
			Anything not already vouched for by the bidder list. A bid still
			awaiting the server is excluded too: no mail about it can exist
			yet, so any mail it matched would be somebody else's.
		]]
		if e.state ~= "leading" and e.state ~= "pending" then
			pending[#pending + 1] = e
		end
	end
	if #pending == 0 then
		if not quiet then self:Print("Nothing waiting on the mail.") end
		return 0, 0
	end

	local n = GetInboxNumItems() or 0
	if n == 0 then
		if not quiet then self:Print("The mailbox is empty.") end
		return 0, 0
	end

	local used, won, lost = {}, 0, 0

	--[[
		An attachment is the strongest signal there is, so those go first: the
		item turning up in the mail means we won it, and nothing else in the
		mailbox can say that.
	]]
	for i = 1, n do
		local j = 1
		while j <= 16 do		-- ATTACHMENTS_MAX_RECEIVE
			local iname, _, icount = GetInboxItem(i, j)
			if not iname then break end
			if not used[i] then
				for _, e in ipairs(pending) do
					if not used[i] and not BS.LedgerClosed(e)
					   and iname == e.name and (icount or 1) == e.count then
						SetState(e, "won", "the item arrived in the mail")
						e.stateAt = time()
						used[i] = true
						won = won + 1
					end
				end
			end
			j = j + 1
		end
	end

	--[[
		Then refunds. Gold coming back in exactly the amount we bid means we
		were outbid - at that moment, not necessarily at the end. Whether that
		is final depends only on whether the auction can still be running.

		Two passes, because the amount alone can coincide: mail whose subject
		also names the item is matched first, and only then is a bare amount
		match accepted. Subjects are localised, so they can corroborate but must
		never be the thing the decision rests on.
	]]
	local live = 0
	for pass = 1, 2 do
		for i = 1, n do
			if not used[i] then
				local _, _, _, subject, money = GetInboxHeaderInfo(i)
				money = money or 0
				for _, e in ipairs(pending) do
					if not used[i] and not BS.LedgerClosed(e) and money > 0
					   and money == e.myBid
					   and (pass == 2
					        or (subject and string.find(subject, e.name, 1, true))) then
						used[i] = true
						if BS.LedgerCouldStillRun(e) then
							SetState(e, "outbid",
								"outbid - your gold came back, and the auction "
								.. "can still be running")
							live = live + 1
						else
							SetState(e, "lost",
								"outbid, and the auction can no longer be running")
							e.stateAt = time()
							lost = lost + 1
						end
					end
				end
			end
		end
	end

	self:RefreshLedger()

	if not quiet and (won > 0 or lost > 0 or live > 0) then
		self:Print(format("Mail: |cff00ff00%d won|r, |cffff8800%d outbid and still "
			.. "winnable|r, |cffff4444%d lost for good|r.", won, live, lost))
	end
	return won, lost, live
end

--=============================================================================
--  reporting
--=============================================================================

function BS:PrintLedger()
	local open = self:LedgerOpen()
	if #open == 0 then
		self:Print("No bids on file. Anything you bid on from here is recorded.")
		return
	end

	self:Print(format("%d bid%s on file:", #open, #open == 1 and "" or "s"))
	for _, e in ipairs(open) do
		self:Print(format("   %s  %s  bid %s%s%s",
			BS.ledgerStateText[e.state] or e.state,
			e.link or e.name,
			BS.Money(e.myBid),
			(e.copies or 1) > 1
				and format("  |cffffd100on %d of them, %s in all|r",
					e.copies, BS.Money(e.myBid * e.copies)) or "",
			e.note and ("  |cff888888(" .. e.note .. ")|r") or ""))
	end
end

--[[
	The one-line answer to "what happened while I was gone?". Printed when the
	auction house opens, so the first thing you see is what still needs doing.
]]
function BS:LedgerSummary()
	local counts = {}
	for _, e in ipairs(self:LedgerOpen()) do
		counts[e.state] = (counts[e.state] or 0) + 1
	end
	return counts
end
