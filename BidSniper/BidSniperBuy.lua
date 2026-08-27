--[[--------------------------------------------------------------------------
	BidSniper - buying, and working out what is actually worth buying

	The auction house sells the same item at a dozen prices in a dozen stack
	sizes, and "cheapest per item" is only the right answer when you want one
	stack of it. Wanting forty Saronite Bars is a different question - which
	auctions, taken together, get you forty for the least gold - and that is a
	covering problem, not a sort.

	So this page answers both from one search:

	  * every listing, cheapest per item first. That is the Auctionator view,
	    and it is what you want when you just need the cheap one.
	  * the cheapest combination that reaches a number you name.
	  * the other quantities worth knowing about, because twenty in one stack
	    is often cheaper per item than the fifteen you asked for.

	The last of those carries one rule, and it is the rule this page exists to
	enforce: more items for the same gold or less is never a worse deal. Any
	quantity that hands you more for no more money beats the one you asked for,
	so it is listed above it rather than left for you to spot.
]]

local BS = BidSniper
if not BS then return end

local floor, ceil, format, sort, huge =
	math.floor, math.ceil, string.format, table.sort, math.huge

local ITEMS_PER_PAGE = 50		-- NUM_AUCTION_ITEMS_PER_PAGE, hardcoded as in
					-- the core file so nothing has to be loaded
local BUY_MAX_PAGES  = 20		-- 1000 auctions of one item is already absurd
local QUERY_TIMEOUT  = 15

--[[
	How much arithmetic the planner is allowed.

	The answer it gives is exact rather than a guess, and exact costs work: it
	fills in one row per quantity, from one up to however many are for sale, and
	visits each of those rows once per stack size on offer. Ten thousand
	Frostweave Cloth would be ten thousand rows.

	So there is a budget. When the full range would cost more than this the
	range shrinks - never below the number you actually asked for - and the page
	says the options were cut short rather than quietly showing you fewer.
]]
local OPS_BUDGET = 250000
local HARD_MAX_Q = 4000

--=============================================================================
--  settings
--=============================================================================

--[[
	Kept out of BS.defaults on purpose. That table is copied into the saved
	variables one level deep, so a default holding a table of its own - the list
	of recent searches, here - would end up shared with the defaults rather than
	copied from them, and writing to it would edit the defaults. The Sell page
	keeps its settings the same way and for the same reason.
]]
--[[
	How many the plan is being worked out for.

	The box on this page and a shopping run are two owners of the same question,
	and they must not share one number. A run sets its own here; everything else
	falls back to the figure you typed.

	They did share BuySettings().qty, and it was wrong in a way that only shows
	up once a run is under way. A plan is not built when the quantity is set: the
	run sets it, fires a search, and the plan is worked out when the results come
	back, which is a window of whole seconds. Anything that wrote to the box in
	that window - a stale value committed as the box lost focus, a keystroke, a
	repaint that could not update a focused box - replaced the run's quantity
	with the page's. The run then surveyed, priced, and bought against a number
	nobody had asked for.

	Both complaints came from that. A stale figure larger than the shortfall is
	"it is only offering me the 100 I typed earlier". A stale figure smaller than
	the shortfall caps what the survey records as available - and since the buying
	pass never asks for more than the survey found, the run quietly comes up short
	on reagent after reagent, which is "it never buys everything".
]]
function BS:BuyTarget()
	local n = tonumber(self.buyTarget) or self:BuySettings().qty or 1
	return math.max(1, math.min(9999, floor(n)))
end

-- a run's claim on the quantity, dropped the moment it stops driving the page
function BS:BuyClearTarget()
	self.buyTarget = nil
end

function BS:BuySettings()
	self.db.buy = self.db.buy or {}
	local s = self.db.buy
	if s.qty         == nil then s.qty         = 1     end
	if s.hideOwn     == nil then s.hideOwn     = true  end
	if s.allOptions  == nil then s.allOptions  = false end
	if s.shiftSearch == nil then s.shiftSearch = true  end
	s.recent = s.recent or {}
	return s
end

-- the last few searches, newest first, so the same item is one click away
local RECENT_MAX = 12

function BS:BuyRemember(name)
	local s = self:BuySettings()
	local lower = string.lower(name)
	for i = #s.recent, 1, -1 do
		if string.lower(s.recent[i]) == lower then table.remove(s.recent, i) end
	end
	table.insert(s.recent, 1, name)
	while #s.recent > RECENT_MAX do table.remove(s.recent) end
end

--[[
	Everything here shares one query channel with the scan, the bid lookup and
	the bid check, and two of them talking at once means one reads the other's
	results. Rather than a lock, each asks this first and says plainly what is
	in the way.
]]
function BS:BuyBusy()
	if self.scanning    then return "a scan is running"        end
	if self.batch       then return "a bid batch is running"   end
	if self.bidSearch   then return "a bid lookup is running"  end
	if self.ledgerSweep then return "the bid check is running" end
	return nil
end

--=============================================================================
--  searching for one item
--=============================================================================

--[[
	Returns whether the search actually started, so a caller driving this
	without a user watching - the shopping run - can tell a refusal from a
	search that is merely still in flight, and move on rather than sit waiting
	for results that were never asked for.

	`internal` is the shopping run identifying itself. Everything else is a
	person, and a person searching while a run is working down the list would
	replace the listings the next press is about to buy from. The run's own
	searches are the one exception, so they say so on the way in, and every
	other route - the box, Recent, a shift-click, /snipe buy - is turned away
	with a reason rather than silently ignored.
]]
function BS:BuyStartSearch(text, internal)
	local name = BS.CleanItemName(text)
	if not name then
		self:Print("Type an item name, or paste an item link.")
		return false
	end

	if self.shopRun and not internal then
		self:Print("A shopping run is using this page. Press Skip to leave the reagent "
			.. "it is on, or Stop to end the run.")
		return false
	end

	if self.sellSurvey and not internal then
		self:Print("The Sell tab is checking prices on this page. Press Stop there to "
			.. "end the check.")
		return false
	end

	if not self.atAH then
		self:Print("You need to be at the auction house.")
		return false
	end

	local why = self:BuyBusy()
	if why then
		self:Print("Cannot search while " .. why .. ".")
		return false
	end
	--[[
		A search already running is replaced, not refused.

		Changing your mind is the ordinary case. You click something, watch a page
		or two go by, spot the thing you actually meant, and click that instead -
		and until now the second click did nothing at all, silently, because a
		search was still walking through pages. The only way out was closing the
		auction house, which is a terrible answer to "I clicked the wrong item".

		Only a person may do this. The shopping run drives searches of its own and
		must not have one pulled out from under it half way down a list, so an
		internal caller still waits its turn and is told no, exactly as before.

		BuyCancelSearch is deliberately not used: it tells the shopping run its
		search failed, and this search did not fail, it was replaced. A run cannot
		be the thing being interrupted here in any case - it holds this page
		against people entirely, further up - but calling it would be saying
		something untrue and waiting for the day that stops being safe.

		The old query may still be in the post. It cannot be read into the new
		search: BuyListUpdate only consumes a page while buyAwaiting is set, and
		that is cleared here and not set again until the new query actually goes
		out. Should one still arrive late, BuyReadPage matches every row against
		the name it is looking for, so the rows land in the "something else the
		search dragged in" count rather than in the results.
	]]
	if not internal then self:BuyClearTarget() end

	if self.buySearch then
		if internal then return false end
		self.buySearch       = nil
		self.buyQueryPending = false
		self.buyAwaiting     = false
		self.buyDone         = nil
	end

	if self.buyRun then
		self:Print("Finish or stop the purchase first.")
		return false
	end

	--[[
		Unsorted, deliberately. A server-side sort ties auctions that share the
		value being sorted on, and a page boundary landing inside a run of ties
		drops part of it - the same thing that makes a sorted paged scan step
		over identical listings. One item is a handful of pages, so there is
		nothing to gain by sorting and a whole run of one seller's stacks to
		lose.
	]]
	if type(SortAuctionClearSort) == "function" then
		pcall(SortAuctionClearSort, "list")
	end

	-- a bid lookup skips its round trip when it believes the auction list still
	-- holds its item; we are about to replace that list, so drop the claim
	self.loadedQueryName = nil

	--[[
		`lower` is what the rows are actually tested against.

		The auction house matches names without caring about case, so "arcane
		dust" finds Arcane Dust and the results come back exactly as they should.
		Testing them against what you typed, character for character, then threw
		every one of them away and reported nothing for sale - which is a
		spectacular way to be wrong, because the auctions were right there.

		So the test is case-insensitive, and still exact: it is the whole name
		that has to match, which is what keeps a search for Copper Bar from
		filling up with Copper Bar Racks. The server's own spelling is picked up
		off the first row and used from then on.
	]]
	self.buySearch = {
		name = name, lower = string.lower(name),
		page = 0, rows = {}, byKey = {},
		noBuyout = 0, mine = 0, truncated = false,
	}
	self.buyQueryPending = true
	self.buyThrottle     = 0
	self.buyDone         = nil
	self:BuyRemember(name)
	self:SetStatus("Searching for " .. name .. "...")
	self:RefreshBuy()
	return true
end

--[[
	Look something up from anywhere: open the window, come to this page, fill in
	the box, and go.

	One function so that every way in behaves the same. A shift-click, the
	Recent list and /snipe buy <item> all land here, and none of them can drift
	into doing three quarters of the job.
]]
function BS:BuySearchFor(text)
	local name = BS.CleanItemName(text)
	if not name then return false end

	if self.frame then self.frame:Show() end
	self:SetTab("buy")
	if self.buyFrame and self.buyFrame.search then
		self.buyFrame.search:SetText(name)
		self.buyFrame.search:ClearFocus()
	end
	self:BuyStartSearch(name)
	return true
end

--[[
	Shift-click an item anywhere, and this page looks it up.

	HandleModifiedItemClick is the client's own funnel for a modified click on
	an item: bags, the character sheet, loot, quest rewards, the tradeskill
	list and the auction rows all end up there, so hooking it once covers the
	lot rather than reaching into every frame that holds an item.

	Hooked, never replaced. Whatever the client already does with the click -
	putting the link in whichever box is waiting for it - still happens exactly
	as before. This only listens.

	Four things stop it, because shift-click already means something:

	  * away from the auction house there is nothing to search;
	  * a chat box open means the click was meant for the chat box, and
	    hijacking it would be unforgivable mid-sentence;
	  * a name box of ours waiting for a name gets the name instead, which is
	    what the wishlist has always claimed shift-click does;
	  * and our own rows call this deliberately to link an item into chat.
	    That is a documented thing they do, not a request to go shopping, so
	    they say so on the way in.

	And it can be turned off, because somebody who shift-clicks items into the
	browse box all day should not have to put up with us.
]]
local function ShiftClickedItem(link)
	local BS = BidSniper
	if not BS or not BS.db then return end
	if BS.linkingToChat then return end
	if not BS.atAH then return end
	if not link or not string.find(link, "|Hitem:", 1, true) then return end
	if not BS:BuySettings().shiftSearch then return end
	-- the user's own binding for "link this", whatever they have set it to
	if type(IsModifiedClick) == "function" and not IsModifiedClick("CHATLINK") then
		return
	end
	if type(ChatEdit_GetActiveWindow) == "function" and ChatEdit_GetActiveWindow() then
		return
	end

	local w = BS.wishFrame
	if w and w:IsShown() and w.entry and w.entry:HasFocus() then
		w.entry:SetText(BS.CleanItemName(link) or "")
		return
	end

	BS:BuySearchFor(link)
end

if type(HandleModifiedItemClick) == "function" then
	hooksecurefunc("HandleModifiedItemClick", ShiftClickedItem)
end

--[[
	And links in chat, which do not come through the funnel above.

	3.3.5a routes a click on a hyperlink through SetItemRef instead, and that
	one handles the modifiers itself rather than delegating - so an item
	somebody linked in guild chat would have been the one place this did not
	work, which is a shame, because "get me twenty of these" is exactly when you
	want it.

	SetItemRef is called for every kind of link there is - players, quests,
	achievements, spells - so the check for an item link in the text is what
	keeps this to items. `text` is the whole clickable link; `link` is only its
	innards.
]]
if type(SetItemRef) == "function" then
	hooksecurefunc("SetItemRef", function(link, text) ShiftClickedItem(text) end)
end

--[[
	Link an item into chat the way the client does, without this page mistaking
	it for somebody asking to buy one.
]]
function BS:LinkToChat(link)
	if not link then return end
	self.linkingToChat = true
	HandleModifiedItemClick(link)
	self.linkingToChat = nil
end

function BS:BuyCancelSearch(reason)
	self.buySearch       = nil
	self.buyQueryPending = false
	self.buyAwaiting     = false
	if reason then self:SetStatus(reason) end
	self:RefreshBuy()

	-- a shopping run is waiting on results that are never coming, and would
	-- otherwise sit on this reagent for the rest of the evening
	if self.shopRun then
		self:ShopSearchFailed(reason)
	elseif self.sellSurvey then
		self:SellSurveyFailed(reason)
	end
end

--[[
	Read one page of results into the search.

	Two listings of the same item at the same stack size and the same buyout are
	the same offer as far as buying goes - it makes no difference which of them
	you take - so they are counted rather than listed twice. Here that is not
	merely tidiness: the plan says "three of these", and the only way to honour
	that when the time comes is for "these" to be exactly what the purchase side
	matches on.

	Which is why the key is stack size and buyout and nothing else. The seller
	and the time left are shown because they are worth seeing, but two sellers
	asking the same price for the same stack are interchangeable, and grouping
	on the seller would split a run of them for no reason.
]]
function BS:BuyReadPage()
	local s = self.buySearch
	if not s then return end

	local numBatch, total = GetNumAuctionItems("list")
	total   = total or 0
	s.total = total

	local mine   = self.db.knownChars or {}
	local hide   = self:BuySettings().hideOwn
	local wanted = s.lower

	for i = 1, (numBatch or 0) do
		local name, texture, count, quality, _, level, _, _, buyout, _, highBidder, owner =
			GetAuctionItemInfo("list", i)

		-- the server matches on part of a name and ignores case, so a search
		-- for "copper bar" also hands back Copper Bar Rack; the whole name has
		-- to match, and the case it comes back in is the case that is right
		if name and string.lower(name) == wanted then
			count = count or 1
			s.realName = s.realName or name

			if not s.texture then
				s.texture, s.quality, s.level = texture, quality, level
				s.link = GetAuctionItemLink("list", i)
			end

			if (buyout or 0) <= 0 then
				-- bid only: there is nothing here to buy outright
				s.noBuyout = s.noBuyout + 1
			elseif hide and owner and mine[owner] then
				s.mine = s.mine + 1
			else
				local timeLeft = GetAuctionItemTimeLeft("list", i) or 4
				local key = format("%d:%d", count, buyout)
				local o   = s.byKey[key]
				if o then
					o.qty = o.qty + 1
					-- a price several people are asking is worth saying so
					if owner and o.owner and owner ~= o.owner then o.manyOwners = true end
					if timeLeft < o.timeLeft then o.timeLeft = timeLeft end
					if highBidder then o.leading = true end
				else
					o = {
						name = name, count = count, buyout = buyout,
						unit = buyout / count, qty = 1,
						owner = owner, timeLeft = timeLeft, leading = highBidder,
						link = GetAuctionItemLink("list", i), key = key,
					}
					s.byKey[key] = o
					s.rows[#s.rows + 1] = o
				end
			end

		elseif name then
			-- something else the search dragged in. Worth counting: a search
			-- for "copper" finds fifty auctions and matches none of them, and
			-- "nothing is for sale" would be a baffling thing to be told while
			-- the browse list next door is full of Copper Bars.
			s.other   = (s.other or 0) + 1
			s.example = s.example or name
		end
	end

	local nextPage = s.page + 1
	if nextPage * ITEMS_PER_PAGE < total then
		if nextPage < BUY_MAX_PAGES then
			s.page = nextPage
			self.buyQueryPending = true
			self:SetStatus(format("Searching for %s (page %d)...", s.name, nextPage + 1))
			return
		end
		s.truncated = true
	end

	self:BuyFinishSearch()
end

function BS:BuyFinishSearch()
	local s = self.buySearch
	if not s then return end
	self.buySearch       = nil
	self.buyQueryPending = false
	self.buyAwaiting     = false

	--[[
		Cheapest per item first, which is the order you shop in. Stack size
		breaks a tie the useful way round: at the same price per item, the
		smaller stack is the more flexible buy because it overshoots less.
	]]
	sort(s.rows, function(a, b)
		if a.unit  ~= b.unit  then return a.unit  < b.unit  end
		if a.count ~= b.count then return a.count < b.count end
		return a.buyout < b.buyout
	end)

	local items, listings = 0, 0
	for _, o in ipairs(s.rows) do
		items    = items + o.count * o.qty
		listings = listings + o.qty
	end

	--[[
		From here on the item is called what the auction house calls it, not
		what you typed. Everything downstream - the purchase, which has to
		recognise these rows again, and Recent, which you will click next
		week - is better off with the real spelling than with yours.
	]]
	local name = s.realName or s.name

	self.buy = {
		name = name, link = s.link, texture = s.texture, quality = s.quality,
		offers = s.rows, total = items, listings = listings,
		noBuyout = s.noBuyout, mine = s.mine, truncated = s.truncated,
		when = time(),
	}
	self.buyDP, self.buyPlan = nil, nil

	if s.realName then
		self:BuyRemember(name)		-- dedupes on case, so this replaces yours
		if self.buyFrame and self.buyFrame.search
		   and not self.buyFrame.search:HasFocus() then
			self.buyFrame.search:SetText(name)
		end
	end

	if #s.rows == 0 then
		if s.noBuyout > 0 then
			self:SetStatus(format("%s: %d up, none with a buyout - nothing to buy outright.",
				name, s.noBuyout))
		elseif not s.realName and (s.other or 0) > 0 then
			-- part of a name, then: say what it did find rather than "nothing"
			self:SetStatus(format("Nothing is called exactly \"%s\". The search found "
				.. "%d other auction%s - %s, for one. Try the whole name.",
				s.name, s.other, s.other == 1 and "" or "s", s.example))
		else
			self:SetStatus(format("Nothing called \"%s\" is for sale.", s.name))
		end
		self:RefreshBuy()
		-- nothing for sale is an answer, and the shopping run wants it as much
		-- as it wants a page full of offers. So does the sell check: an item
		-- with no competition at all is a thing worth knowing before pricing it
		if self.shopRun then
			self:ShopSearchDone()
		elseif self.sellSurvey then
			self:SellSawSearch()
		end
		return
	end

	self:BuyReplan()
	self:SetStatus(format("%s: %s for sale in %d listing%s, cheapest %s each.",
		name, BS.Comma(items), listings, listings == 1 and "" or "s",
		BS.Money(s.rows[1].unit)))
	self:RefreshBuy()

	--[[
		Last, and after the plan exists. A shopping run decides here whether to
		pay for it, and that decision is made against the same plan the page is
		showing rather than against one worked out privately.

		The sell check reads the same listings for the opposite purpose: not
		what they would cost to buy, but what they say the item is worth asking.
	]]
	if self.shopRun then
		self:ShopSearchDone()
	elseif self.sellSurvey then
		self:SellSawSearch()
	end
end

--=============================================================================
--  the planner
--=============================================================================

--[[
	Why this is a knapsack and not a sort.

	Buying by cheapest unit price down the list is wrong the moment stack sizes
	differ. Wanting 20 with a 25-stack at 4g each and 20 singles at 3g each, the
	cheap-first answer buys the twenty singles for 60g; the 25-stack costs 100g
	and is dearer. But wanting 24, cheap-first buys twenty singles and then has
	to reach for something else, while the single 25-stack is one purchase, five
	items more, and quite possibly less gold.

	So: minimise cost subject to getting at least as many as you asked for. That
	is exactly the covering knapsack, and it is solved here exactly.

	The one structural fact that makes it cheap is that within a stack size you
	always take the cheapest ones first - two 20-stacks are the same goods, so
	there is never a reason to pay more for one. That turns hundreds of separate
	auctions into a handful of groups (one per stack size on offer), each with a
	running total, and the table only has to remember one number per group per
	quantity. A dozen stack sizes rather than three hundred auctions is what
	keeps the whole thing inside a frame.
]]

local function BuildGroups(offers, maxq)
	local byStack, order = {}, {}
	for _, o in ipairs(offers) do
		local g = byStack[o.count]
		if not g then
			g = { stack = o.count, entries = {} }
			byStack[o.count] = g
			order[#order + 1] = g
		end
		-- identical auctions were counted rather than listed, so put the
		-- copies back: each one is a separate thing you can buy
		for _ = 1, o.qty do g.entries[#g.entries + 1] = o end
	end

	for _, g in ipairs(order) do
		sort(g.entries, function(a, b) return a.buyout < b.buyout end)

		-- more of one stack size than it takes to cover the whole range can
		-- never be part of an answer, so they are not carried
		local cap = ceil(maxq / g.stack)
		for i = #g.entries, cap + 1, -1 do g.entries[i] = nil end

		g.prefix = { [0] = 0 }
		for k = 1, #g.entries do
			g.prefix[k] = g.prefix[k - 1] + g.entries[k].buyout
		end
		g.kmax = #g.entries
	end

	sort(order, function(a, b) return a.stack < b.stack end)
	return order
end

-- roughly how many table reads the planner would do over this range; used to
-- decide whether the range has to be cut, never to change the answer
local function OpsFor(groups, maxq)
	local ops = 0
	for _, g in ipairs(groups) do
		local full = g.kmax * g.stack		-- above this, the group is all in
		if full >= maxq then
			ops = ops + (maxq * maxq) / (2 * g.stack) + maxq
		else
			ops = ops + (full * full) / (2 * g.stack)
			          + (maxq - full) * g.kmax + maxq
		end
	end
	return ops
end

--[[
	Fill in "the cheapest way to get at least q of them" for every q up to the
	end of the range, and remember enough to say which auctions that was.

	Ties are broken towards more items, which is this page's whole point: if two
	plans cost the same and one hands you five more, that one is the answer, and
	it is picked here rather than left to be noticed in the options list.
]]
function BS:BuyRunDP(need)
	local buy = self.buy
	if not buy or #buy.offers == 0 then return nil end

	local avail = buy.total
	local floorq = math.min(math.max(1, need or 1), avail, HARD_MAX_Q)
	local maxq   = math.min(avail, HARD_MAX_Q)

	local groups = BuildGroups(buy.offers, maxq)
	local capped = false
	while maxq > floorq and OpsFor(groups, maxq) > OPS_BUDGET do
		maxq   = math.max(floorq, floor(maxq * 0.7))
		groups = BuildGroups(buy.offers, maxq)
		capped = true
	end

	local dp, dq = { [0] = 0 }, { [0] = 0 }
	for q = 1, maxq do dp[q], dq[q] = huge, 0 end

	local picks = {}
	for gi, g in ipairs(groups) do
		local s, C, kmax = g.stack, g.prefix, g.kmax
		local ndp, ndq, take = { [0] = 0 }, { [0] = 0 }, { [0] = 0 }
		for q = 1, maxq do
			local bc, bq, bk = dp[q], dq[q], 0
			for k = 1, kmax do
				local prev = q - k * s
				if prev < 0 then prev = 0 end
				local pc = dp[prev]
				if pc ~= huge then
					local c  = pc + C[k]
					local qq = dq[prev] + k * s
					if c < bc or (c == bc and qq > bq) then
						bc, bq, bk = c, qq, k
					end
				end
				--[[
					Once k covers q on its own, taking more of this group only
					adds gold. Every buyout here is above zero, so the cost is
					strictly rising and no later k can tie either.
				]]
				if prev == 0 then break end
			end
			ndp[q], ndq[q], take[q] = bc, bq, bk
		end
		dp, dq, picks[gi] = ndp, ndq, take
	end

	--[[
		Every quantity worth considering, and nothing else.

		dp is indexed by "at least q", so several q can describe the same
		purchase; they collapse to one entry per quantity actually delivered.
		Then the rule this page is built on throws the rest away: an entry a
		bigger purchase matches or undercuts is not an option, it is a mistake,
		so it is not offered.
	]]
	local costOf, srcOf, ns = {}, {}, {}
	for q = 1, maxq do
		if dp[q] ~= huge then
			local n, c = dq[q], dp[q]
			if costOf[n] == nil then
				ns[#ns + 1] = n
				costOf[n], srcOf[n] = c, q
			elseif c < costOf[n] then
				costOf[n], srcOf[n] = c, q
			end
		end
	end
	sort(ns)

	local back, run = {}, huge
	for i = #ns, 1, -1 do
		local n, c = ns[i], costOf[ns[i]]
		if c < run then
			run = c
			back[#back + 1] = { n = n, cost = c, unit = c / n, src = srcOf[n] }
		end
	end
	local options = {}
	for i = #back, 1, -1 do options[#options + 1] = back[i] end

	self.buyDP = {
		groups = groups, picks = picks, dp = dp, dq = dq,
		maxq = maxq, capped = capped, options = options, avail = avail,
	}
	return self.buyDP
end

-- which auctions the answer for state `q` is made of
function BS:BuyRebuild(q)
	local d = self.buyDP
	if not d then return nil end

	local counts, order = {}, {}
	local cur, cost, qty = q, 0, 0

	for gi = #d.groups, 1, -1 do
		local k = d.picks[gi][cur] or 0
		if k > 0 then
			local g = d.groups[gi]
			for i = 1, k do
				local o = g.entries[i]
				if not counts[o] then
					counts[o] = 0
					order[#order + 1] = o
				end
				counts[o] = counts[o] + 1
			end
			cost = cost + g.prefix[k]
			qty  = qty + k * g.stack
			cur  = cur - k * g.stack
			if cur < 0 then cur = 0 end
		end
	end

	local lines = {}
	for _, o in ipairs(order) do
		lines[#lines + 1] = {
			offer = o, take = counts[o],
			cost  = counts[o] * o.buyout,
			items = counts[o] * o.count,
		}
	end
	sort(lines, function(a, b)
		if a.offer.unit ~= b.offer.unit then return a.offer.unit < b.offer.unit end
		return a.offer.count < b.offer.count
	end)

	return lines, cost, qty
end

-- work out the plan for the number in the box, running the table first if the
-- last one cannot answer for that many
function BS:BuyReplan()
	local buy = self.buy
	if not buy or #buy.offers == 0 then
		self.buyPlan = nil
		return
	end

	-- planning a purchase is the act that retires the last one's notice: from
	-- here the button is about what happens next, not about what already did
	self.buyDone = nil

	local target = self:BuyTarget()
	if not self.buyDP or target > self.buyDP.maxq then
		if not self:BuyRunDP(target) then return end
	end

	local d = self.buyDP
	local q = math.min(target, d.maxq)
	local lines, cost, qty = self:BuyRebuild(q)

	self.buyPlan = {
		source = "best",
		target = target,
		lines  = lines, cost = cost, qty = qty,
		unit   = qty > 0 and (cost / qty) or 0,
		short  = target > d.avail,
	}
	return self.buyPlan
end

-- take one of the other quantities instead
function BS:BuyChoose(option)
	local d = self.buyDP
	if not d or not option then return end
	self.buyDone = nil
	local lines, cost, qty = self:BuyRebuild(option.src)
	self.buyPlan = {
		source = "option",
		target = self:BuyTarget(),
		lines  = lines, cost = cost, qty = qty,
		unit   = qty > 0 and (cost / qty) or 0,
	}
	self:RefreshBuy()
end

--[[
	Buy from this listing and no other.

	The whole page is about combinations, but sometimes you have looked at the
	list and simply want that one - the seller you know, the stack size that
	suits, the auction about to end. Takes as many of it as your number needs,
	or all of them on a ctrl-click.
]]
function BS:BuyOnly(offer, all)
	if not offer then return end
	self.buyDone = nil
	local target = self:BuyTarget()
	local take   = all and offer.qty or math.min(offer.qty, ceil(target / offer.count))
	if take < 1 then take = 1 end

	self.buyPlan = {
		source = "listing",
		target = target,
		lines  = { { offer = offer, take = take,
		             cost = take * offer.buyout, items = take * offer.count } },
		cost   = take * offer.buyout,
		qty    = take * offer.count,
		unit   = offer.unit,
	}
	self:RefreshBuy()
end

--[[
	The options list: the other ways of getting what you asked for.

	Two cuts, and the first one is the important one. **Every option has to
	reach the target.** Asking for fifty and being offered one, or eight, is not
	being offered a way to buy fifty - it is a list of things that are not the
	answer, and picking one silently abandons what you asked for. So quantities
	below the target are not choices and are not shown.

	When nothing reaches it there is exactly one thing worth saying, which is
	how close you can get: the whole of what is for sale, on its own line.

	The second cut is the one that decides what an option *is*, and it is worth
	being exact about, because the obvious answer is wrong.

	There is only ever one reason to buy more than you asked for: **it is better
	value per item.** Fifty-three instead of fifty because the thirteen came at
	a better price than the ten is a reason. The same plan with one more single
	auction stuck on the end is not - it is more gold for more stuff at the same
	rate, which is not a deal, it is just a bigger bill. So every row past the
	first has to beat the cheapest answer *on price per item*, and by a margin
	you would change your mind over rather than by a hundredth of a silver.

	Without that, the list degenerates into a counter. One more cheap single, on
	an average of twenty-odd items, improves the rate by a rounding error, so
	every quantity in turn "improves" on the last and the list reads 24, 25, 26,
	27, every row of it saying "0% cheaper each" - a list of nothing, in the
	place meant for the one thing worth noticing.

	Two rows are always kept regardless: the cheapest way to the target - the
	first of them, so it survives anyway - and the plan you are actually on. The
	list may never leave out where you are or where you started.

	Returns the rows and, second, the quantity the cheapest answer delivers, so
	the page can mark it.
]]
-- 1% better per item, or overshooting to reach it is not a deal, just a
-- bigger bill
local LADDER_STEP = 0.99

function BS:BuyOptionRows()
	local d = self.buyDP
	if not d then return {}, nil end

	local target = self:BuyTarget()
	local bestN  = d.dq[math.min(target, d.maxq)]

	local reach = {}
	for _, o in ipairs(d.options) do
		if o.n >= target then reach[#reach + 1] = o end
	end

	if #reach == 0 then
		local most = d.options[#d.options]
		return most and { most } or {}, nil
	end

	if self:BuySettings().allOptions then return reach, bestN end

	local plan = self.buyPlan
	local here = plan and plan.qty
	local out, floorUnit = {}, huge

	for _, o in ipairs(reach) do
		if o.unit < floorUnit * LADDER_STEP or o.n == here or o.n == bestN then
			out[#out + 1] = o
			-- measured against what is on the list, not against every quantity
			-- walked past, so a slow drift eventually earns a rung of its own
			if o.unit < floorUnit then floorUnit = o.unit end
		end
	end
	return out, bestN
end

--=============================================================================
--  buying it
--=============================================================================

StaticPopupDialogs["BIDSNIPER_CONFIRM_BUY"] = {
	text = "Buy %s for %s?",
	button1 = YES,
	button2 = NO,
	OnAccept = function(self) BidSniper:BuyRun(self.data) end,
	timeout = 30,
	whileDead = 1,
	hideOnEscape = 1,
	showAlert = 1,
	preferredIndex = 3,
}

function BS:BuyStart()
	local plan = self.buyPlan
	if not plan or #plan.lines == 0 then
		self:Print("Nothing planned to buy - search for something first.")
		return
	end
	if not self.atAH then
		self:Print("You need to be at the auction house.")
		return
	end
	local why = self:BuyBusy()
	if why then
		self:Print("Cannot buy while " .. why .. ".")
		return
	end
	if self.buySearch then
		self:Print("Wait for the search to finish.")
		return
	end
	if GetMoney() < plan.cost then
		self:Print("That comes to " .. BS.Money(plan.cost) .. " and you have "
			.. BS.Money(GetMoney()) .. ".")
		return
	end

	StaticPopup_Show("BIDSNIPER_CONFIRM_BUY",
		format("%d %s", plan.qty, self.buy.link or self.buy.name),
		BS.Money(plan.cost), plan)
end

function BS:BuyRun(plan)
	if not plan or not self.buy then return end

	local want, keys = {}, {}
	for _, line in ipairs(plan.lines) do
		local o   = line.offer
		local w   = want[o.key]
		if not w then
			w = { count = o.count, buyout = o.buyout, left = 0, link = o.link }
			want[o.key] = w
			keys[#keys + 1] = o.key
		end
		w.left = w.left + line.take
	end

	local auctions = 0
	for _, key in ipairs(keys) do auctions = auctions + want[key].left end

	self.buyRun = {
		name = self.buy.name, want = want, keys = keys,
		approved = plan.cost, items = plan.qty,
		spent = 0, got = 0, bought = 0,
		page = 0, stage = "query",
	}
	self.buyThrottle = 0
	self:SetStatus(format("Finding %d auction%s to buy...",
		auctions, auctions == 1 and "" or "s"))
	self:RefreshBuy()
end

function BS:BuyStop(reason)
	local run = self.buyRun

	--[[
		A press still waiting on the server is settled on the way out rather
		than dropped. Whatever gold has already left the bag bought something,
		and a run that ends here - the auction house closing, or Stop being
		pressed - must still account for it or the reagent silently arrives in
		the post having been reported as never bought.
	]]
	if run and run.pending then
		local p = run.pending
		local spent = p.money - GetMoney()
		if spent < 0 then spent = 0 end
		self:BuyCommit(p, math.min(spent, p.cost), spent < p.cost)
	end

	self.buyRun = nil
	if run and run.bought > 0 then
		self:Print(format("Bought %d auction%s - %s items for %s.",
			run.bought, run.bought == 1 and "" or "s",
			BS.Comma(run.got), BS.Money(run.spent)))

		-- what the page says happened, until something replaces it. Cleared by
		-- anything that plans a new purchase, so it can never sit above one.
		self.buyDone = {
			name = run.name, qty = run.got, cost = run.spent,
			auctions = run.bought, at = GetTime(),
		}
		self:BuySettle(run)
	end
	if reason then self:SetStatus(reason) end
	self:RefreshBuy()

	--[[
		A purchase the shopping run started has ended - finished, out of gold,
		or stopped - so it is that run's turn again.

		`run.shop` is what makes this safe to do from every exit at once: a
		purchase you started by hand while no run is going has no such mark, and
		a run being shut down has already cleared itself, so neither can be
		mistaken for a reagent that is ready to be moved on from.
	]]
	if run and run.shop and self.shopRun then self:ShopItemDone(run) end
end

--[[
	What is still left for anyone to buy.

	The listing table was read before the purchase, so after it the counts on
	screen are a photograph of a shop we have just taken things out of.
	Re-searching would be honest and slow; subtracting what we bought is honest
	and free, so that is what happens, and the plan is worked out again from
	what remains.
]]
function BS:BuySettle(run)
	local buy = self.buy
	if not buy then return end

	for _, o in ipairs(buy.offers) do
		local w = run.want[o.key]
		if w and w.taken and w.taken > 0 then
			o.qty = o.qty - w.taken
			if o.qty < 0 then o.qty = 0 end
		end
	end

	local rows, items, listings = {}, 0, 0
	for _, o in ipairs(buy.offers) do
		if o.qty > 0 then
			rows[#rows + 1] = o
			items    = items + o.count * o.qty
			listings = listings + o.qty
		end
	end
	buy.offers, buy.total, buy.listings = rows, items, listings

	--[[
		And no new plan is worked out. That is a safety decision, not an
		oversight, and it is the whole reason this function ends here.

		Replanning automatically put a fresh, pressable purchase on the button
		the instant the last one finished - same place on screen, same shape,
		same wording, differing only in a number. One more click on a button
		that had just been clicked several times bought a second load of
		everything, and nothing on the page had said the first was over.

		So a finished purchase leaves nothing armed. Buying again means asking
		for it: press Plan, pick a listing, or change the quantity. Each of
		those is a deliberate act, and each of them clears the finished notice
		on its way through.
	]]
	self.buyDP, self.buyPlan = nil, nil
end

--[[
	Walk the page that is loaded, and either count what we could take off it or
	take it.

	Both directions are the same walk on purpose. What the button offers and
	what the button spends have to be worked out by the same code from the same
	list, or the number on it is a promise made somewhere else.

	Auctionator buys every match on a page inside one click and the client
	allows it, which is the one place buying is kinder than bidding: a bid is
	one press per auction because each one needs its own confirmation, while a
	buyout at a price you already approved does not. So a press takes the whole
	page.

	Note what this does *not* depend on: which page is loaded. Auctions are
	recognised by item, stack size and price rather than by where they sit, so a
	page arriving out of order - and one does, because a buyout makes the server
	push a refresh of its own - costs a round trip and can never cost a purchase
	that was not planned.
]]
function BS:BuySweep(andBuy)
	local run = self.buyRun
	if not run then return 0, 0 end

	local num, total = GetNumAuctionItems("list")
	run.total = total or 0

	--[[
		`counting` is only needed on the dry run. Buying takes the wanted number
		down as it goes, so the same tally kept twice would have each purchase
		count against itself and stop the page half bought.
	]]
	local counting, n, cost = {}, 0, 0

	-- what this press actually asked for, key by key, so the money can be
	-- matched against it afterwards
	local pressed, order = {}, {}

	for i = 1, (num or 0) do
		local name, _, count, _, _, _, _, _, buyout = GetAuctionItemInfo("list", i)
		if name == run.name and (buyout or 0) > 0 then
			local key  = format("%d:%d", count or 1, buyout)
			local w    = run.want[key]
			local left = w and w.left or 0
			if w and not andBuy then left = left - (counting[key] or 0) end

			--[[
				Never past the total that was approved, and never past the gold
				actually in the bag. GetMoney does not necessarily fall between
				two purchases in the same click, so what this press has already
				committed is subtracted by hand rather than trusted to it.
			]]
			if left > 0 and (run.spent + cost + buyout) <= run.approved
			   and (not andBuy or GetMoney() >= (cost + buyout)) then
				n    = n + 1
				cost = cost + buyout

				if andBuy then
					--[[
						Asked for, not bought. PlaceAuctionBid is a request with
						no answer: it returns nothing whether the auction is
						still there or somebody took it a second ago, and the
						client says not a word either way.

						So nothing is counted here. What was pressed is written
						down, and the money is what settles it - see BuyConfirm.
						Counting at this point is what had the page reporting
						four purchases against two the server actually made, and
						a shopping run moving on from a reagent it had not
						filled.
					]]
					PlaceAuctionBid("list", i, buyout)
					w.left      = w.left - 1
					w.pressed   = (w.pressed or 0) + 1

					local e = pressed[key]
					if not e then
						e = { key = key, n = 0, buyout = buyout, count = count or 1 }
						pressed[key] = e
						order[#order + 1] = e
					end
					e.n = e.n + 1
				else
					counting[key] = (counting[key] or 0) + 1
				end
			end
		end
	end

	return n, cost, order
end

--=============================================================================
--  did that press actually buy anything?
--=============================================================================

--[[
	The client will not tell us, so the gold has to.

	PlaceAuctionBid is fire and forget. It returns nothing, it raises nothing,
	and an auction somebody else bought a moment ago fails exactly as silently
	as one that succeeds. Believing the press was the purchase is how the page
	came to report four auctions bought against the two the server actually
	made - and worse, how a shopping run moved on from a reagent it was still
	short of, because as far as it knew the order had been filled.

	What cannot be argued with is the money. It falls by exactly the buyout of
	every auction that really was bought and by nothing else, so the difference
	across a press is the truth about that press, whatever the client did or did
	not say.

	It is not instant: the fall arrives with the server's answer, some time
	after the press. So this is asked once per round trip and allowed to say
	"not yet" a few times before it gives up and treats the difference as
	auctions that got away.
]]
local CONFIRM_TRIES = 3

-- how many times one auction may be pressed before it is written off. Two
-- failures is somebody else's purchase, not a slow server.
local RETRY_LIMIT = 2

function BS:BuyConfirm()
	local run = self.buyRun
	local p   = run and run.pending
	if not p then return true end

	local spent = p.money - GetMoney()
	if spent < 0 then spent = 0 end

	if spent >= p.cost then
		self:BuyCommit(p, p.cost, false)
		return true
	end

	if p.tries < CONFIRM_TRIES then
		p.tries   = p.tries + 1
		run.page  = 0
		run.stage = "query"
		self:SetStatus(format("Waiting for the auction house to confirm %s...",
			BS.Money(p.cost)))
		return false
	end

	-- it has had its chances: whatever the gold says is what happened
	self:BuyCommit(p, spent, true)
	return true
end

--[[
	Write down what the gold says was bought.

	Where a press covered several different auctions the successes are
	attributed key by key, and within a key every auction costs the same, so the
	count that fits the money is exact rather than a guess. Across keys it is a
	greedy fit - which of two different auctions failed cannot be known from a
	single figure - but the totals it produces are right either way, and the
	totals are what the run and the report are built on.

	Anything that did not go through goes back on the wanted list to be tried
	once more, because an auction can fail simply for arriving in a list the
	server had not finished updating. Twice, though, and it is gone: something
	that fails on a fresh list is not coming back, and retrying it forever is
	how a purchase loop stops terminating.
]]
function BS:BuyCommit(p, spent, partial)
	local run = self.buyRun
	if not run then return end
	run.pending = nil

	local purse, gotN, gotItems, gotCost = spent, 0, 0, 0

	for _, e in ipairs(p.byKey) do
		local ok = e.n
		if partial then
			ok = math.min(e.n, floor(purse / e.buyout))
			if ok < 0 then ok = 0 end
		end
		purse = purse - ok * e.buyout

		local w = run.want[e.key]
		if w then
			w.taken = (w.taken or 0) + ok
			local missed = e.n - ok
			if missed > 0 then
				w.failed = (w.failed or 0) + 1
				if w.failed <= RETRY_LIMIT then w.left = w.left + missed end
			end
		end

		gotN     = gotN + ok
		gotItems = gotItems + ok * e.count
		gotCost  = gotCost + ok * e.buyout
	end

	run.bought = run.bought + gotN
	run.got    = run.got + gotItems
	run.spent  = run.spent + gotCost

	if gotN > 0 then
		self:Print(format("Bought %d auction%s for %s.",
			gotN, gotN == 1 and "" or "s", BS.Money(gotCost)))
	end
	if gotN < p.n then
		self:Print(format("|cffff8800%d of the %d did not go through|r - taken by "
			.. "somebody else between the page being read and the button being "
			.. "pressed. Nothing was charged for %s.",
			p.n - gotN, p.n, p.n - gotN == 1 and "it" or "them"))
	end
end

-- anything left to look for?
function BS:BuyOutstanding()
	local run = self.buyRun
	if not run then return 0 end
	local left = 0
	for _, key in ipairs(run.keys) do left = left + run.want[key].left end
	return left
end

-- results are in: is there anything on this page for us?
function BS:BuyPageReady()
	local run = self.buyRun
	if not run then return end

	--[[
		Before anything else: did the last press actually buy anything? Until
		that is settled the wanted counts are a guess, and deciding the run is
		finished on a guess is the whole bug this exists to close. A "not yet"
		queues another round trip and comes back here.
	]]
	if not self:BuyConfirm() then return end

	if self:BuyOutstanding() <= 0 then
		self:BuyStop(format("Bought everything the plan asked for - %s items for %s.",
			BS.Comma(run.got), BS.Money(run.spent)))
		return
	end

	local n, cost = self:BuySweep(false)
	if n > 0 then
		run.stage    = "ready"
		run.pageTake = n
		run.pageCost = cost
		self:SetStatus(format("Ready: %d auction%s for %s  -  press BUY",
			n, n == 1 and "" or "s", BS.Money(cost)))
		self:RefreshBuy()
		return
	end

	--[[
		Nothing here. Turn the page; a walk that reaches the last one without
		finding anything is the end of it.

		That is what makes this terminate. Every press must buy at least one
		auction or the run stops, and every press starts the walk again from the
		first page, so the only way round the loop is one that spends - and the
		gold and the approved total both run out.
	]]
	local nextPage = run.page + 1
	if nextPage * ITEMS_PER_PAGE < (run.total or 0) and nextPage < BUY_MAX_PAGES then
		run.page  = nextPage
		run.stage = "query"
		self:SetStatus(format("Looking for the rest (page %d)...", nextPage + 1))
	else
		local left = self:BuyOutstanding()
		self:BuyStop(format("%d auction%s could not be found - gone, or bought by "
			.. "somebody else.", left, left == 1 and "" or "s"))
	end
end

-- MUST be reached from a real click. Do not call from OnUpdate or an event.
function BS:FireArmedBuy()
	local run = self.buyRun
	if not run or run.stage ~= "ready" then return end

	-- read before the presses, because the fall this is measured against
	-- arrives with the server's answer rather than with the press
	local before   = GetMoney()
	local n, cost, byKey = self:BuySweep(true)

	if n == 0 then
		-- the page moved between the offer and the press, or the gold did
		self:BuyStop("Nothing on that page could be bought - stopped.")
		return
	end

	--[[
		Nothing is claimed yet, and nothing is finished yet. Both of those used
		to be decided here, on the strength of having pressed the button - which
		is precisely what the client gives no grounds for. The round trip below
		is what settles it, and BuyConfirm reads the gold when it lands.
	]]
	run.pending = {
		money = before, cost = cost, n = n, byKey = byKey, tries = 0,
	}

	--[[
		Back to the first page rather than on to the next. Every auction bought
		comes off the server's list and renumbers everything after it, so the
		page numbers we were walking no longer mean what they meant. Starting
		over costs one round trip and is the only way the numbers are true.
	]]
	run.page  = 0
	run.stage = "query"
	self:SetStatus(format("Pressed %d auction%s for %s - waiting for the auction "
		.. "house to confirm...", n, n == 1 and "" or "s", BS.Money(cost)))
	self:RefreshBuy()
end

--=============================================================================
--  the query pump, driven from the core file's OnUpdate
--=============================================================================

--[[
	Returns true when it is using the auction list, so the scan side leaves it
	alone. Same shape as the bid lookup and the bid check above it: ask for a
	send slot, then wait for the answer, and never sit waiting for either
	forever.
]]
function BS:BuyTick(elapsed)
	if self.buyQueryPending then
		self.buyThrottle = (self.buyThrottle or 0) + elapsed
		if self.buyThrottle > QUERY_TIMEOUT * 2 then
			self:BuyCancelSearch("The server would not take the search.")
			return true
		end
		if self.buyThrottle >= 0.15 and CanSendAuctionQuery() then
			local s = self.buySearch
			if not s then
				self.buyQueryPending = false
				return false
			end
			self.buyThrottle     = 0
			self.buyQueryPending = false
			self.buyAwaiting     = true
			self.buyQueryTime    = GetTime()
			self.loadedQueryName = nil
			QueryAuctionItems(s.name, nil, nil, nil, nil, nil, s.page, nil, nil)
		end
		return true

	elseif self.buyAwaiting then
		if GetTime() - (self.buyQueryTime or 0) > QUERY_TIMEOUT then
			self:BuyCancelSearch("The search timed out.")
		end
		return true
	end

	local run = self.buyRun
	if not run then return false end

	if run.stage == "query" then
		self.buyThrottle = (self.buyThrottle or 0) + elapsed
		if self.buyThrottle > QUERY_TIMEOUT * 2 then
			self:BuyStop("The server would not take the lookup - stopped.")
			return true
		end
		if self.buyThrottle >= 0.15 and CanSendAuctionQuery() then
			self.buyThrottle     = 0
			run.stage            = "await"
			run.at               = GetTime()
			self.loadedQueryName = nil
			QueryAuctionItems(run.name, nil, nil, nil, nil, nil, run.page, nil, nil)
		end
		return true

	elseif run.stage == "await" then
		if GetTime() - (run.at or 0) > QUERY_TIMEOUT then
			self:BuyStop("The lookup timed out - stopped.")
		end
		return true
	end

	return true		-- armed and waiting for a press: the list is ours
end

-- AUCTION_ITEM_LIST_UPDATE: true when this page consumed it
function BS:BuyListUpdate()
	if self.buySearch and self.buyAwaiting then
		self.buyAwaiting = false
		self:BuyReadPage()
		return true
	end

	local run = self.buyRun
	if run and run.stage == "await" then
		self:BuyPageReady()
		return true
	end

	return false
end

-- the auction house has gone: everything here points at a list that is no
-- longer there
function BS:BuyForget()
	self:BuyClearTarget()
	self.buySearch       = nil
	self.buyQueryPending = false
	self.buyAwaiting     = false
	-- last visit's result, on a page about to be emptied: it would still be
	-- sitting there next time the auction house opened
	self.buyDone         = nil

	local run = self.buyRun
	self.buyRun = nil
	if run and run.bought > 0 then
		-- what it managed to buy is still bought, so the listing counts and the
		-- plan have to come down to match before the page is looked at again
		self:Print(format("Bought %d auction%s before the auction house closed - "
			.. "%s items for %s.", run.bought, run.bought == 1 and "" or "s",
			BS.Comma(run.got), BS.Money(run.spent)))
		self:BuySettle(run)
	end

	-- and a shopping run is a queue of searches against a list that has gone,
	-- so it ends here too - with whatever the last purchase managed counted in
	if self.shopRun then self:ShopForget(run) end
end

--=============================================================================
--  printed version
--=============================================================================

function BS:PrintBuyPlan()
	local plan, buy = self.buyPlan, self.buy
	if not plan or not buy then
		self:Print("Nothing planned - open the Buy tab and search for something.")
		return
	end

	self:Print(format("%s: %s for %s, %s each.", buy.link or buy.name,
		BS.Comma(plan.qty), BS.Money(plan.cost), BS.Money(plan.unit)))
	for _, line in ipairs(plan.lines) do
		self:Print(format("   %d x %d  at %s each  =  %s   (%s each)",
			line.take, line.offer.count, BS.Money(line.offer.buyout),
			BS.Money(line.cost), BS.Money(line.offer.unit)))
	end

	local d = self.buyDP
	if not d then return end
	self:Print("Other ways to buy it:")
	for _, o in ipairs(self:BuyOptionRows()) do
		self:Print(format("   %s for %s   (%s each)%s", BS.Comma(o.n),
			BS.Money(o.cost), BS.Money(o.unit),
			o.n == plan.qty and "   |cffffd100<- this one|r" or ""))
	end
end
