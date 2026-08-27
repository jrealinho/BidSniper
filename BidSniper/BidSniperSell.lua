--[[
	BidSniper - posting a patch of your bags to the auction house

	The idea is a staging area. You decide that some part of your bags - the
	first two rows, a whole bag, whatever - is "stuff to sell", you drop things
	into it as you play, and at the auction house you empty it in one pass.

	Two things shape everything here.

	The client will not let an addon post an auction on its own. StartAuction is
	only honoured while the client is handling a real click, exactly like
	PlaceAuctionBid, so this cannot be a button you press once and walk away
	from. It is one press per item, with the item and the price on the button
	before you commit to it - the same bargain the bidding side makes, and for
	the same reason.

	What it does get for free is stacks. StartAuction takes a stack count, so
	six stacks of the same herb are one press, not six. Only distinct items
	cost a press each.
]]

local BS = BidSniper
if not BS then return end

local floor, format, sort = math.floor, string.format, table.sort

-- 1, 2 and 3 are the auction house's own 12/24/48 hour codes
BS.SellDurations = { [1] = "12 hours", [2] = "24 hours", [3] = "48 hours" }

--[[
	A tooltip nobody can see, for asking a question the item API will not answer.

	GetContainerItemInfo says nothing about whether an item is bound, and a
	soulbound item cannot be auctioned - so short of trying it and being
	refused, reading its tooltip is the only way to know.
]]
local scanTip = CreateFrame("GameTooltip", "BidSniperSellScanTip", nil, "GameTooltipTemplate")
scanTip:SetOwner(UIParent, "ANCHOR_NONE")

--[[
	Remembered per slot, because this list now redraws on every bag event and
	building a tooltip for forty slots several times a second is exactly the
	sort of thing that makes a window feel heavy.

	Keyed on what is in the slot as well as where, so the answer is thrown away
	the moment the slot holds something else - which is the only way it can go
	wrong.
]]
local boundCache = {}

local function IsSoulbound(bag, slot, link)
	local key = bag .. ":" .. slot
	local hit = boundCache[key]
	if hit and hit.link == link then return hit.bound end

	local bound = false
	scanTip:ClearLines()
	scanTip:SetBagItem(bag, slot)
	for i = 2, math.min(scanTip:NumLines(), 6) do
		local line = _G["BidSniperSellScanTipTextLeft" .. i]
		local text = line and line:GetText()
		if text then
			-- quest items and conjured goods cannot be posted either
			if text == ITEM_SOULBOUND or text == ITEM_BIND_ON_PICKUP
			   or text == ITEM_BIND_QUEST or text == ITEM_CONJURED then
				bound = true
				break
			end
		end
	end

	boundCache[key] = { link = link, bound = bound }
	return bound
end

--=============================================================================
--  which part of the bags
--=============================================================================

function BS:SellSettings()
	self.db.sell = self.db.sell or {}
	local s = self.db.sell

	--[[
		A set of bags rather than one, because a staging area is rarely a whole
		bag and rarely just one - two rows of the backpack and the whole of the
		last bag is an ordinary way to want it.

		The slot range applies inside each ticked bag, and a `toSlot` of 0 means
		"to the end of it". So one bag ticked with 1-8 is the first two rows;
		three bags ticked with 1-0 is all three bags entire.
	]]
	if s.bags == nil then
		-- carry over the single bag this used to hold
		s.bags = { [s.bag or 0] = true }
		s.bag  = nil
	end

	if s.fromSlot == nil then s.fromSlot = 1  end
	if s.toSlot   == nil then s.toSlot   = 8  end	-- two rows of a four-wide bag
	-- 0 means "a copper under the lowest", which is what undercutting normally
	-- means; a percentage is for deliberately going in cheaper than that
	if s.undercut == nil then s.undercut = 0  end
	if s.duration == nil then s.duration = 2  end	-- 24 hours
	if s.bidPct   == nil then s.bidPct   = 95 end	-- opening bid, as % of buyout

	--[[
		How big a lot to post each item in, remembered per item.

		Nothing here is a preference about selling in general - it is a
		different answer for every item. Herbs go in twenties because that is
		how people buy them; gems go one at a time; a levelling enchanter wants
		dust in fives. Getting that right is worth doing once and never again,
		which is why it is saved rather than typed at the auction house.

		Keyed by item name, and absent means "a full stack", so an untouched
		list behaves exactly as it did before there was a setting.
	]]
	if s.stacks == nil then s.stacks = {} end
	return s
end

--=============================================================================
--  how big a lot
--=============================================================================

-- the client's own limit: twenty for most herbs, one for a sword
function BS.MaxStack(link)
	if not link then return 1 end
	local n = select(8, GetItemInfo(link))
	return (type(n) == "number" and n > 0) and n or 1
end

--[[
	The lot size in force for an item, and the ceiling it is held under.

	A saved size is still clamped every time it is read rather than when it is
	written. The ceiling is the item's own stack limit, which is not knowable
	until the client has the item cached - so a number saved while it was
	unknown would otherwise stick at whatever it was allowed to be then.
]]
function BS:SellStackSize(name, link)
	local maxStack = BS.MaxStack(link)
	local want     = name and self:SellSettings().stacks[name]

	-- nothing chosen means a full stack, which is what posting has always done
	if not want or want <= 0 then return maxStack, maxStack end

	return math.max(1, math.min(want, maxStack)), maxStack
end

--[[
	Choose a lot size for an item.

	A size at or above the item's own stack limit is stored as "no choice at
	all" rather than as that number: the two behave identically today, and only
	the first still behaves the way you meant if you later post the same item on
	a character whose bags hold a bigger stack of it.
]]
function BS:SetSellStackSize(name, link, n)
	if not name then return end
	local s = self:SellSettings()
	n = tonumber(n) or 0

	if n <= 0 or n >= BS.MaxStack(link) then
		s.stacks[name] = nil
	else
		s.stacks[name] = math.floor(n)
	end
	self:RefreshSell()
end

--[[
	Split a heap into lots: as many whole ones as it makes, then the rest.

	Twenty-three in lots of four is five fours and a three, and the three is
	posted rather than left in the bag - a remainder sitting in your bags is the
	single easiest way to end up carrying half a stack of something around for a
	week.

	Returned separately because the two are not the same auction and cannot be
	the same call: the auction house posts numStacks lots of stackSize at one
	price, so a lot of four and a lot of three are two postings at two prices.
]]
function BS.SplitLots(total, size)
	total = math.max(0, math.floor(total or 0))
	size  = math.max(1, math.floor(size or 1))
	return math.floor(total / size), total % size
end

-- ticked bags, lowest first, so the list reads in the order the bags sit
function BS:SellBags()
	local s, out = self:SellSettings(), {}
	for bag = 0, 4 do
		if s.bags[bag] then out[#out + 1] = bag end
	end
	return out
end

function BS:ToggleSellBag(bag)
	local s = self:SellSettings()
	s.bags[bag] = (not s.bags[bag]) or nil
	self:RefreshSell()
end

-- one line saying what is currently selected, for the panel and for chat
function BS:SellRangeText()
	local s, bags = self:SellSettings(), self:SellBags()
	if #bags == 0 then return "No bags ticked" end

	local names = {}
	for _, bag in ipairs(bags) do
		names[#names + 1] = (bag == 0) and "backpack" or ("bag " .. bag)
	end

	local ending = (s.toSlot > 0) and ("slot " .. s.toSlot) or "the end"

	-- one bag and the two numbers are simply its range; several and they are
	-- the two ends of a run, which is a different sentence
	if #bags == 1 then
		return format("%s, slots %d to %s", names[1], s.fromSlot, ending)
	end

	return format("%s, starting at slot %d and ending at %s",
		table.concat(names, " + "), s.fromSlot, ending)
end

--[[
	Bag slots are numbered left to right, top to bottom, so "the first two rows"
	of a four-wide bag is slots 1 to 8 and there is nothing to guess at.

	Rows themselves are a drawing detail - how wide a bag looks depends on the
	bag frame, and on whichever addon happens to be drawing it - so the range is
	kept in slot numbers and the panel lists exactly what falls inside it. What
	you see listed is what gets posted.
]]
function BS:SellRegion()
	local s    = self:SellSettings()
	local bags = self:SellBags()
	local out  = {}

	for i, bag in ipairs(bags) do
		local size = GetContainerNumSlots(bag) or 0

		--[[
			One stretch of bag space, not the same window cut out of every bag.

			The range used to apply inside each ticked bag independently, so
			three bags and "slots 1 to 8" meant the first two rows of all three
			and the rest of every one of them left alone. That is almost never
			what a staging area is: it is a run of space that starts somewhere
			and ends somewhere, and the bags in the middle of it are simply
			full of it.

			So the two numbers bound the ends and nothing else. From slot cuts
			into the first ticked bag, To slot stops part way through the last,
			and everything between them is taken whole. Tick one bag and both
			land on it, which is the old behaviour and the common case.
		]]
		local first = (i == 1) and math.max(1, s.fromSlot) or 1
		local last  = size
		if i == #bags and s.toSlot > 0 then last = math.min(size, s.toSlot) end

		for slot = first, last do
			local _, count, locked, quality = GetContainerItemInfo(bag, slot)
			local link = GetContainerItemLink(bag, slot)
			if link then
				local name = GetItemInfo(link)
				out[#out + 1] = {
					bag = bag, slot = slot, link = link, name = name or link,
					count = count or 1, quality = quality, locked = locked,
					bound = IsSoulbound(bag, slot, link),
				}
			end
		end
	end
	return out
end

--=============================================================================
--  what the market is really asking, ignoring the giveaways
--=============================================================================

--[[
	The problem this exists for, stated plainly.

	Undercutting means going a copper under the cheapest listing, and that is
	right almost all the time. It is catastrophic the rest of the time. Somebody
	misplaces a decimal point, or dumps a stack to clear a bag, or lists a
	200-gold item at two gold to get rid of it - and pricing off the cheapest
	listing copies their mistake onto everything you own of that item. It is not
	a small loss and it is not recoverable: the auctions go up, somebody takes
	them all inside a minute, and the gold is gone.

	So the cheapest listing is not automatically the price. What we want is the
	cheapest listing *that the rest of the market agrees with* - and the honest
	way to find it is to look for a gap.

	Three things this has to get right, and they pull against each other:

	  * A genuine cheap competitor is not an outlier. Somebody undercutting you
	    properly, at ten or twenty percent under, is the market working. Ignore
	    them and your auction sits there unsold behind theirs.
	  * A dumper with the whole bottom of the list is not an outlier either. If
	    ten of the fifteen auctions up are at two gold, then two gold is what
	    the item costs today, however much you dislike it. You cannot outvote
	    the market by calling most of it a mistake.
	  * Two silly listings under a wall of sensible ones is exactly what this is
	    for.

	The test is therefore about *both* the size of the gap and how few auctions
	sit below it. A price is only disregarded when there is a real cliff above
	it and the things below that cliff are a small minority of what is up.
]]

--[[
	How big a jump counts as a cliff rather than as competition.

	Two and a half times. Undercutting is a few percent; a clearance is tens of
	percent; nobody prices a third of the going rate and means it as a trade.
	Below this and it is treated as the market disagreeing with itself, which it
	is entitled to do.
]]
local OUTLIER_GAP = 2.5

--[[
	And the most of the list that may be written off as mistakes: two auctions,
	or 40% of them, whichever is more generous - but never all of them, because
	something has to be left to be the price.

	Two rather than one because mistakes travel in pairs: the same person
	listing the same misjudged stack twice is the ordinary shape of this, and a
	cap of one would catch the first and price off the second.
]]
local function OutlierCap(n)
	local cap = math.max(2, floor(n * 0.4))
	return math.min(cap, n - 1)
end

--[[
	The unit prices actually competing with you, cheapest first.

	Your own auctions are left out whoever you are logged in as. Undercutting
	yourself is how a price walks to the floor over a week of relisting - every
	pass goes under the last one - and it is the one listing that certainly
	should not influence what you ask.

	Identical listings are counted rather than listed once, because how many
	there are is exactly what the minority test below is measuring.
]]
function BS:SellCompetition(offers)
	local mine, out = self.db.knownChars or {}, {}
	for _, o in ipairs(offers or {}) do
		if not (o.owner and mine[o.owner]) and (o.unit or 0) > 0 then
			for _ = 1, (o.qty or 1) do out[#out + 1] = o.unit end
		end
	end
	sort(out)
	return out
end

--[[
	The price to go under: the cheapest one the rest of the market stands behind.

	Returns that price, how many listings were disregarded getting to it, and
	how many were competing in the first place. The last two are not decoration
	- they are what the panel shows you so the number can be argued with rather
	than trusted.

	The search is for the largest gap anywhere in the disregardable range, not
	the first gap found. Outliers cluster: a bottom of 1g, 2g, 190g, 195g has no
	cliff between the first two and a very large one after them, and a walk that
	stopped at the first small step would price off the 1g and be exactly as
	wrong as before.
]]
function BS.SellNormalPrice(prices, total)
	local kept = #prices
	if kept == 0 then return nil, 0, 0 end

	--[[
		`total` is how many were really up, when the caller only has the cheapest
		few of them. A scan writes down a handful per item and counts the rest,
		and the two numbers do different jobs here: the count decides how much of
		the list may be written off as mistakes, and the prices are where the
		cliff is looked for. Passing only prices means the two are the same
		thing, which is the ordinary case.
	]]
	local n = math.max(total or kept, kept)
	if n == 1 then return prices[1], 0, 1 end

	-- never look past what we actually hold: a cap of eight is no use over five
	-- prices, and reading off the end would compare against nothing
	local cap = math.min(OutlierCap(n), kept - 1)
	local cut, best = 0, 1

	for i = 1, cap do
		local ratio = prices[i + 1] / prices[i]
		if ratio > best then best, cut = ratio, i end
	end

	if best < OUTLIER_GAP then cut = 0 end
	return prices[cut + 1], cut, n
end

--[[
	Everything the panel and the tooltip need to say about one item's market.

	`thin` is the case worth naming rather than hiding: one competing listing
	cannot be checked against anything, so undercutting it is a guess. It is
	still the best guess available - and it is still what gets used - but you
	are told, because "one auction up and it is 2g" is a situation a person
	should look at rather than post into.
]]
function BS:SellQuoteFrom(offers)
	local prices = self:SellCompetition(offers)
	local unit, dropped, n = BS.SellNormalPrice(prices)
	if not unit then return nil end

	return {
		unit    = unit,
		lowest  = prices[1],
		dropped = dropped,
		rivals  = n,
		thin    = n < 2,
		src     = "search",
		at      = time(),
	}
end

--[[
	How long a quote stands before it has to be asked again.

	An hour. A price an hour old is not what the item is worth to the copper any
	more, and that is not what this figure is for: the expensive mistake it
	exists to stop is undercutting a giveaway by two orders of magnitude, and
	the shape of a market - a wall of listings around 190g with two idiots at
	1g - does not rearrange itself in an afternoon. Being a few percent behind
	on the wall costs a slower sale; being fooled by the 1g costs the stock.

	The cost of a shorter window is real and it is paid every time: a query per
	item, on the same channel as the scan, while you stand at the auction house
	waiting to post a bag you have already decided about.
]]
local QUOTE_TTL = 60 * 60

--[[
	Kept in saved variables rather than in the session.

	An hour of grace that a reload throws away is not an hour of grace. Posting
	is exactly the activity that gets interrupted - you empty half a bag, go and
	do something else, come back - and the client here needs restarting often
	enough that a session-only memory would almost never be the thing that
	answered.

	Small enough not to care about: a handful of numbers per item you have
	actually sold, and anything past its hour is dropped on the way past rather
	than kept for ever.
]]
function BS:SellQuotes()
	local s = self:SellSettings()
	s.quotes = s.quotes or {}
	return s.quotes
end

--[[
	The same answer, out of the last sweep, for nothing.

	A scan walks every auction on the house and now keeps the cheapest few of
	each with a count beside them - which is exactly what the outlier test needs.
	So an item the sweep saw does not have to be searched for again: the check
	can answer it from what is already in hand, instantly and without a query.

	Held to the same hour as any other quote, because a sweep is a photograph
	like any other and the question is only ever how old it is.

	What it cannot do is see past the few it kept. A market whose whole bottom
	five are giveaways is one this will price into, where a live search would
	have read the rest and known better - so that case is marked `partial` and
	the row says the figure came from the sweep rather than from asking.
]]
function BS:SellScanQuote(name)
	if not name or not self.SeenSpread then return nil end

	local e, at = self:SeenSpread(name)
	if not e then return nil end
	if (time() - (at or 0)) > QUOTE_TTL then return nil end

	local prices = {}
	for i = 1, #e do prices[i] = e[i] end

	local unit, dropped, n = BS.SellNormalPrice(prices, e.n)
	if not unit then return nil end

	return {
		unit    = unit,
		lowest  = prices[1],
		dropped = dropped,
		rivals  = n,
		thin    = n < 2,
		--[[
			The cliff we found sits at the very edge of what the sweep kept, and
			it kept fewer than were up. So the giveaway cluster may run past the
			end of what we can see, and the price below is only the best of a
			bad view. Rare, and worth saying rather than quietly pricing into.
		]]
		partial = (dropped >= #prices - 1 and n > #prices) or nil,
		src     = "scan",
		at      = at,
	}
end

function BS:SellQuote(name)
	if not name then return nil end
	local quotes = self:SellQuotes()
	local q      = quotes[name]
	if not q then return nil end

	if (time() - (q.at or 0)) > QUOTE_TTL then
		quotes[name] = nil		-- pruned where it is found, so nothing has to sweep
		return nil
	end
	return q
end

-- everything we think we know about what things are going for, forgotten
function BS:SellForgetQuotes()
	local s = self:SellSettings()
	s.quotes = {}
end

-- the ones nobody came back to, dropped at login
function BS:PruneSellQuotes()
	local s = self.db and self.db.sell
	if not s or type(s.quotes) ~= "table" then return end

	local now = time()
	for name, q in pairs(s.quotes) do
		if type(q) ~= "table" or (now - (q.at or 0)) > QUOTE_TTL then
			s.quotes[name] = nil
		end
	end
end

--=============================================================================
--  what to ask for it
--=============================================================================

--[[
	Priced to sit just under the cheapest one on the auction house.

	Auctionator's figure is not a "market value" in the averaged sense - it is
	the lowest per-item buyout its last scan saw, which is exactly the number
	you want to go under. So the default undercut is nothing at all: the price
	lands one copper below the cheapest listing, which is what undercutting
	means. The percentage is there for when you want to go in deliberately
	cheaper than that, and most of the time it should stay at zero.

	Whatever the percentage says, the result is always strictly below the
	lowest. Matching it to the copper would leave you behind the existing
	auction in the sort order, which is the one outcome nobody wants.

	Deliberately no auction house query per item: that is a round trip each,
	and the point of a staging bag is to empty it quickly. The cost of that is
	that the figure is only as fresh as your last Auctionator scan.
]]
function BS:SellUnitPrice(entry)
	--[[
		Our own scan first, Auctionator second.

		Auctionator's database only moves when Auctionator scans - we read it
		and never write to it - so a sweep from this addon used to leave these
		prices untouched, and only an Auctionator search would shift them. A
		scan here now records the cheapest of everything it walks past, and that
		is a better answer than Auctionator's anyway: it is from minutes ago
		rather than from whenever Auctionator last looked.
	]]
	--[[
		A quote from the check pass outranks everything, and by a long way.

		It is seconds old, it is the live auction house rather than a database,
		and it is the only one of the three that has been tested against the
		listings around it. The other two are a single number with no way of
		knowing whether it came from a sensible auction or a catastrophic one.
	]]
	local q = self:SellQuote(entry.name)
	if q and q.unit and q.unit > 0 then return q.unit, "quote", q end

	local unit, src = self:LowestSeen(entry.name), "scan"
	if not unit or unit <= 0 then
		unit, src = BS.MarketValue(entry.link), "auctionator"
	end
	if not unit or unit <= 0 then return nil end

	-- the quote goes back even when it could not price this: "we looked, and
	-- nothing else of it is for sale" is a different thing to show than "we
	-- have not looked", and the row says which
	return unit, src, q
end

--[[
	What one lot of `count` of them is worth, undercut.

	Per lot rather than per item, and that is the whole reason this is its own
	function now: five lots of four and one lot of three are six auctions at two
	different prices, and each price is the undercut applied to that lot's own
	worth. Pricing the remainder as though it were a full lot would post three
	herbs at the price of four.
]]
function BS:SellLotPrice(unit, count)
	if not unit or unit <= 0 or not count or count <= 0 then return nil end

	local s      = self:SellSettings()
	local stack  = unit * count
	local buyout = floor(stack * (100 - s.undercut) / 100)
	if buyout >= stack then buyout = stack - 1 end
	if buyout < 1 then buyout = 1 end

	local bid = floor(buyout * s.bidPct / 100)
	if bid < 1 then bid = 1 end
	if bid > buyout then bid = buyout end

	return buyout, bid
end

-- kept for anything still asking the old question: one lot the size of the
-- stack as it sits in the bag
function BS:SellPrice(entry)
	local unit, src = self:SellUnitPrice(entry)
	if not unit then return nil end
	entry.priceSrc = src
	local buyout, bid = self:SellLotPrice(unit, entry.count)
	return buyout, bid, unit
end

--[[
	The plan: one entry per distinct item, carrying every one of them in the
	region and how they are to be cut up.

	This used to group by the stack as it sat in the bag, because that is what
	got posted: four stacks of twenty went up as four lots of twenty because
	that is how they happened to be lying. Which meant the bags decided the
	auction, and a heap that had been split by looting went up as an untidy
	shape nobody chose.

	Now the item decides. Everything of one kind in the region is counted
	together, cut into lots of the size saved for that item, and the remainder -
	which there almost always is - goes up as one last smaller lot rather than
	being left behind in the bag.

	Twenty-three in lots of four is five auctions of four and one of three, and
	that is two calls to the auction house: it posts numStacks lots of one
	stackSize at one price, so the odd-sized last lot is its own posting at its
	own price.
]]
function BS:SellPlan()
	local region = self:SellRegion()
	local items, order = {}, {}
	local skipped = { bound = 0, priced = 0, locked = 0 }

	for _, e in ipairs(region) do
		if e.bound then
			skipped.bound = skipped.bound + 1
		elseif e.locked then
			skipped.locked = skipped.locked + 1
		else
			local unit, src, quote = self:SellUnitPrice(e)
			if not unit then
				skipped.priced = skipped.priced + (e.count or 1)
			else
				--[[
					Keyed by link rather than by name, so two things that share
					a name and not a price - a green with a different suffix,
					the same recipe at two qualities - are not thrown into one
					heap and posted as though they were interchangeable.
				]]
				local key = tostring(e.link)
				local it  = items[key]
				if not it then
					it = {
						link = e.link, name = e.name, quality = e.quality,
						unit = unit, src = src, quote = quote, total = 0,
					}
					items[key]        = it
					order[#order + 1] = it
				end
				it.total = it.total + (e.count or 1)
			end
		end
	end

	--[[
		And the arithmetic, once the whole region has been counted - it cannot
		be done a slot at a time, because the lots are cut from the total and
		the total is not known until the last bag has been read.
	]]
	for _, it in ipairs(order) do
		it.size, it.maxStack = self:SellStackSize(it.name, it.link)
		it.full, it.rest     = BS.SplitLots(it.total, it.size)

		it.lots = {}
		if it.full > 0 then
			local buyout, bid = self:SellLotPrice(it.unit, it.size)
			it.lots[#it.lots + 1] = {
				item = it, count = it.size, stacks = it.full,
				buyout = buyout, bid = bid,
			}
		end
		if it.rest > 0 then
			local buyout, bid = self:SellLotPrice(it.unit, it.rest)
			it.lots[#it.lots + 1] = {
				item = it, count = it.rest, stacks = 1,
				buyout = buyout, bid = bid, remainder = true,
			}
		end

		it.worth = 0
		for _, lot in ipairs(it.lots) do
			it.worth = it.worth + (lot.buyout or 0) * lot.stacks
		end
	end

	--[[
		Dearest first, so if you stop half way you have posted what mattered.

		Sorted on the heap's raw worth rather than on what it is being asked
		for, and that is deliberate rather than lazy. The asking price moves by
		a few copper with the lot size - each lot is undercut and rounded on its
		own, so six of them shed six coppers where two shed two - and sorting on
		a number that moves as you type would let a row slide out from under the
		box you were typing into.
	]]
	sort(order, function(a, b)
		local av, bv = a.unit * a.total, b.unit * b.total
		if av == bv then return (a.name or "") < (b.name or "") end
		return av > bv
	end)

	return order, skipped
end

--[[
	The plan flattened into the order the presses happen in.

	One press per lot, and the item's own lots stay together and in order, so
	the odd remainder goes up immediately after the full lots it was left over
	from rather than at the end of the session when you have stopped watching.
]]
function BS:SellQueue()
	local plan, skipped = self:SellPlan()
	local queue = {}
	for _, it in ipairs(plan) do
		for _, lot in ipairs(it.lots) do queue[#queue + 1] = lot end
	end
	return queue, skipped, plan
end

--=============================================================================
--  checking the market before any of it goes up
--=============================================================================

--[[
	One search per distinct item, before a single auction is posted.

	The prices this page ran on came from the last full scan or from
	Auctionator's database, and both are minutes to days old. That is fine for
	deciding what is worth selling and far too stale for deciding what to ask:
	the whole cost of getting it wrong lands in one press, and the press is
	irreversible.

	So the button checks first. It is one query per item, it buys nothing, and
	it is the only way to know that the cheapest listing you are about to
	undercut is a real price rather than somebody's mistake - because the test
	for that is comparing it against the others, and you cannot compare against
	listings you have not read.

	Afterwards every price on the page is seconds old and has been argued with,
	which is the point: the posting run that follows can be clicked straight
	through without stopping to think about any single one of them.
]]
function BS:SellSurveyStart()
	if not self.atAH then
		self:Print("You need to be at the auction house to check prices.")
		return false
	end
	if self.shopRun then
		self:Print("A shopping run is using the auction house - let it finish first.")
		return false
	end
	if self.sellSurvey then return true end

	--[[
		Only what has not been asked about recently. Coming back to the page
		after posting half a bag should not re-check the half already priced,
		and a quote a couple of minutes old is still a live one.
	]]
	local plan   = self:SellPlan()
	local quotes = self:SellQuotes()
	local queue, seen, free = {}, {}, 0

	for _, it in ipairs(plan) do
		if it.name and not seen[it.name] then
			seen[it.name] = true

			if not self:SellQuote(it.name) then
				--[[
					The sweep first, and only then the auction house.

					A scan that ran within the hour already walked every auction
					of this and kept the shape of its bottom end, which is the
					entire question being asked. Sending a query for it would be
					asking again for something we were told minutes ago - and
					queries are the slow part: one round trip each, on the same
					channel as everything else, while you stand there waiting to
					post a bag you have already decided about.
				]]
				local fromScan = self:SellScanQuote(it.name)
				if fromScan then
					quotes[it.name] = fromScan
					free = free + 1
				else
					queue[#queue + 1] = it.name
				end
			end
		end
	end

	if free > 0 then
		self:Print(format("|cff00ff00%d item%s priced straight off the last scan|r - "
			.. "it already read every auction of %s, so there is nothing to ask.",
			free, free == 1 and "" or "s", free == 1 and "it" or "them"))
	end

	if #queue == 0 then
		if free > 0 then self:RefreshSell() end
		return false
	end

	self.sellSurvey  = { queue = queue, at = 0, checked = 0, dropped = 0,
	                     thin = 0, started = GetTime() }
	self:Print(format("Asking the auction house about %d item%s the last scan "
		.. "cannot answer for.", #queue, #queue == 1 and "" or "s"))
	self:SellSurveyNext()
	return true
end

--[[
	On to the next item, or into the posting run when there are none left.

	A loop rather than a call back into itself, for the same reason the shopping
	list walks its queue in one: an item whose search will not even start costs
	no round trip, and a bag of them would otherwise go as many frames deep as
	there are items.
]]
function BS:SellSurveyNext()
	local sv = self.sellSurvey
	if not sv then return end

	while true do
		sv.at = sv.at + 1
		local name = sv.queue[sv.at]

		if not name then
			self.sellSurvey = nil
			self:SellSurveyReport(sv)
			-- straight into posting: the whole point of checking was to be able
			-- to click through what follows without stopping
			self:SellPost()
			return
		end

		self:SetStatus(format("Checking prices %d/%d: %s...",
			sv.at, #sv.queue, name))
		self:RefreshSell()

		if self:BuyStartSearch(name, true) then return end

		-- the search would not start; nothing is known about this one and the
		-- rest of the list should not wait on it
		sv.failed = (sv.failed or 0) + 1
	end
end

-- results are in for the item the survey is standing on
function BS:SellSawSearch()
	local sv = self.sellSurvey
	if not sv then return end

	local name = sv.queue[sv.at]
	local b    = self.buy

	if name and b and b.name and string.lower(b.name) == string.lower(name) then
		local quotes = self:SellQuotes()
		local q      = self:SellQuoteFrom(b.offers)
		if q then
			quotes[name] = q
			sv.checked = sv.checked + 1
			sv.dropped = sv.dropped + (q.dropped or 0)
			if q.thin then sv.thin = sv.thin + 1 end
		else
			--[[
				Nothing of yours is competing with anything. Written down as an
				answer rather than left blank, so the page knows it looked and
				does not ask again on the next press.
			]]
			quotes[name] = { rivals = 0, dropped = 0, none = true, at = time() }
		end
	end

	self:SellSurveyNext()
end

-- the search never came back
function BS:SellSurveyFailed(reason)
	local sv = self.sellSurvey
	if not sv then return end
	sv.failed = (sv.failed or 0) + 1
	self:SellSurveyNext()
end

function BS:SellSurveyStop()
	if not self.sellSurvey then return end
	self.sellSurvey = nil
	if self.buySearch then self:BuyCancelSearch(nil) end
	self:SetStatus("Price check stopped - nothing was posted.")
	self:UpdateUI()
end

--[[
	What the check found, in one line you can act on.

	The disregarded listings are named out loud rather than quietly applied.
	Somebody undercutting the market by two thirds is either a mistake you have
	just been saved from copying or a genuine collapse you should know about,
	and this page cannot tell which - so it says what it did and lets you look.
]]
function BS:SellSurveyReport(sv)
	local bits = {}
	if sv.dropped > 0 then
		bits[#bits + 1] = format("|cffff8800ignored %d giveaway listing%s|r",
			sv.dropped, sv.dropped == 1 and "" or "s")
	end
	if sv.thin > 0 then
		bits[#bits + 1] = format("|cffffcc66%d had only one rival|r", sv.thin)
	end
	if (sv.failed or 0) > 0 then
		bits[#bits + 1] = format("%d could not be checked", sv.failed)
	end

	self:Print(format("Priced %d item%s from the auction house%s. Prices below are "
		.. "seconds old - post away.",
		sv.checked, sv.checked == 1 and "" or "s",
		#bits > 0 and ("  -  " .. table.concat(bits, ", ")) or ""))
end

--=============================================================================
--  posting, one press at a time
--=============================================================================

--[[
	Put the item in the auction house's sell slot and line the price up on the
	button. Nothing is posted here - this only prepares, so that the press which
	follows is the one the client sees, and it spends exactly the figure the
	button was showing when it was pressed.
]]
--[[
	How many of an item the staging area is holding right now, and where the
	first of them is.

	Asked again at the moment of arming rather than remembered from when the
	plan was drawn up, because posting the full lots changes the answer for the
	remainder that follows them: five lots of four taken out of twenty-three
	leaves three, in a slot that may not be the slot they started in. A plan
	that remembered its slots would arrive at the last lot pointing into an
	empty square.
]]
function BS:SellAvailable(link)
	local have, bag, slot = 0, nil, nil
	for _, e in ipairs(self:SellRegion()) do
		if e.link == link and not e.bound and not e.locked then
			have = have + (e.count or 1)
			if not bag then bag, slot = e.bag, e.slot end
		end
	end
	return have, bag, slot
end

function BS:ArmSell(lot)
	if not self.atAH then
		self:Print("You need to be at the auction house.")
		return false
	end
	if not lot or not lot.item then return false end

	local it = lot.item
	local have, bag, slot = self:SellAvailable(it.link)

	if not bag then
		self:Print(format("No more %s in there - skipping it.",
			it.link or it.name or "?"))
		return false
	end

	--[[
		Never post more than the staging area is actually holding.

		The bag can shrink between drawing the plan up and reaching this lot -
		you moved something, a stack was used, the last press took more than it
		looked like it would - and the failure is silent and expensive: the
		auction house takes the shortfall from wherever else in your bags it can
		find it. So the number of lots is cut to what is really there, and a lot
		that no longer fits at all is dropped rather than shrunk into something
		you did not choose.
	]]
	local stacks = math.min(lot.stacks, floor(have / lot.count))
	if stacks < 1 then
		self:Print(format("Not enough %s left for a lot of %d - skipping it.",
			it.link or it.name or "?", lot.count))
		return false
	end
	lot.stacks = stacks

	ClearCursor()
	PickupContainerItem(bag, slot)
	if GetCursorInfo() ~= "item" then
		ClearCursor()
		self:Print("Could not pick that item up.")
		return false
	end
	ClickAuctionSellItemButton()
	ClearCursor()

	self.armedSell = lot
	-- whatever we were waiting on has happened, or we have stopped waiting
	self.sellSettleFor, self.sellArmAt = nil, nil
	self:SetStatus(format("Ready: %d x %s of %d at %s each  -  press POST",
		stacks, it.link or it.name, lot.count, BS.Money(lot.buyout)))
	self:UpdateUI()
	return true
end

-- MUST be reached from a real click. Do not call from OnUpdate or an event.
function BS:FireArmedSell()
	local lot = self.armedSell
	if not lot then return end
	self.armedSell = nil

	local s      = self:SellSettings()
	local it     = lot.item
	local stacks = lot.stacks

	--[[
		The deposit is taken per stack and is not given back when something
		sells, so running dry half way down a bag is worth catching before the
		call rather than after it.
	]]
	local deposit = 0
	if type(CalculateAuctionDeposit) == "function" then
		local ok, d = pcall(CalculateAuctionDeposit, s.duration)
		if ok and type(d) == "number" then deposit = d * stacks end
	end
	if GetMoney() < deposit then
		self:Print(format("Not enough gold for the deposit (%s).", BS.Money(deposit)))
		self:SetStatus("Posting stopped: deposit unaffordable.")
		self:UpdateUI()
		return
	end

	-- numStacks lots of stackSize, at that lot's own price
	StartAuction(lot.bid, lot.buyout, s.duration, lot.count, stacks)

	self:Print(format("Posted %d x %s of %d at %s each, opening bid %s.%s",
		stacks, it.link or it.name, lot.count,
		BS.Money(lot.buyout), BS.Money(lot.bid),
		lot.remainder and "  |cff888888(the remainder)|r" or ""))

	self.sellPosted = (self.sellPosted or 0) + stacks

	--[[
		An item whose lots do not divide evenly now needs two presses in a row
		on the same item - the whole lots, then the remainder - and the second
		must not be loaded until the first has actually left the bags.

		Everything that follows a post is a round trip: the server takes the
		items, and the client only finds out when a bag update arrives. Arming
		inside the same click would pick up a stack the server is in the middle
		of taking, put it in the sell slot, and post it a second time or fail
		outright depending on which got there first.

		Only when it is the same item. Loading a different one immediately is
		what keeps this to one press per lot, and it has never been the problem
		- a different item is in a different slot and nothing is contending for
		it.
	]]
	self.sellSettleFor = it.link
	self:UpdateUI()
end

function BS:CancelSell()
	if self.sellSurvey then self:SellSurveyStop() return end

	self.armedSell = nil
	self.sellList  = nil
	self.sellIndex = nil
	self.sellSettleFor, self.sellArmAt = nil, nil
	self.sellReplanWanted = nil
	ClearCursor()
	self:SetStatus("Posting cancelled.")
	self:UpdateUI()
end

--[[
	Walking the queue.

	Arming is not protected - only StartAuction is - so the next item can be
	loaded into the sell slot inside the same click that posted the last one.
	That is what keeps this to one press per item rather than two: press, it
	posts what was on the button and loads the next, press again.
]]
--[[
	The button's entry point: check the market, then post against what it found.

	Two steps behind one press, deliberately. Asking you to press "check" and
	then "post" would mean the check is the thing you learn to skip, and it is
	the step that stops you giving a bag of goods away. So the first press does
	both, in the only order that is safe, and every press after it posts.

	A check that finds nothing to ask about - everything already priced within
	the last few minutes - falls straight through to posting.
]]
function BS:SellStart()
	if not self.atAH then
		self:Print("You need to be at the auction house.")
		return
	end
	if self.sellSurvey then return end		-- already checking

	if self:SellSurveyStart() then return end
	self:SellPost()
end

function BS:SellPost()
	if not self.atAH then
		self:Print("You need to be at the auction house.")
		return
	end

	local queue, skipped = self:SellQueue()
	if #queue == 0 then
		self:Print("Nothing to post in that part of your bags."
			.. (skipped.priced > 0 and format("  (%d had no price.)", skipped.priced) or "")
			.. (skipped.bound  > 0 and format("  (%d soulbound.)", skipped.bound) or ""))
		return
	end

	self.sellList   = queue
	self.sellIndex  = 0
	self.sellPosted = 0
	self:SellArmNext()
end

function BS:SellArmNext()
	if not self.sellList then return end
	self.sellIndex = (self.sellIndex or 0) + 1
	self:SellArmHere()
end

--[[
	Change your mind about a lot size with the run already lined up.

	The queue is worked out once and then walked, so a size typed after the
	check had run used to change the number on the page and nothing about what
	was actually going up - which is the worst of both, because the page then
	says one thing and does another. Remembering late is the ordinary case: the
	check is the moment you are finally looking at what the item is worth, and
	that is exactly when it occurs to you that it should go up in fives.

	Rebuilt from the bags rather than patched. Everything already posted has
	left the bags, so a plan worked out from what is in them now *is* the
	remainder - there is no separate account of what has gone to keep in step,
	and there is nothing to get wrong.

	The one thing that must not happen is rebuilding while the bags are still
	catching up from a press. That wait already exists for the remainder lot, so
	this joins it rather than inventing a second one.
]]
function BS:SellReplan()
	if not self.sellList then return end

	if self.sellArmAt then
		self.sellReplanWanted = true
		return
	end

	self.armedSell = nil
	ClearCursor()

	local queue = self:SellQueue()
	if #queue == 0 then
		local n = self.sellPosted or 0
		self.sellList, self.sellIndex = nil, nil
		self:SetStatus(format("Nothing left to post. %d auction%s went up.",
			n, n == 1 and "" or "s"))
		self:UpdateUI()
		return
	end

	self.sellList  = queue
	self.sellIndex = 0
	self:SellArmNext()
end

--[[
	Load whichever lot the queue is pointing at, without moving the pointer.

	Split out from SellArmNext because waiting is now one of the answers: a lot
	that has to let the bags settle first comes back to this same position a
	moment later, and a version that advanced on the way in would have walked
	past it.
]]
function BS:SellArmHere()
	local list = self.sellList
	if not list then return end

	while list[self.sellIndex] do
		local lot = list[self.sellIndex]

		if self.sellSettleFor and lot.item and lot.item.link == self.sellSettleFor then
			--[[
				A bag update means the server has taken what it took; the
				deadline is there because a post that put up nothing at all
				produces no bag update to wait for, and waiting for ever is a
				worse answer than trying anyway.
			]]
			self.sellArmAt  = GetTime() + 0.3
			self.sellArmBy  = GetTime() + 2
			self.sellArmSeq = self.bagSeq or 0
			self:SetStatus("Posted - waiting for the bags to catch up before the "
				.. "remainder...")
			self:UpdateUI()
			return
		end

		if self:ArmSell(lot) then return end
		-- that one could not be loaded; go past it rather than stalling
		self.sellIndex = self.sellIndex + 1
	end

	local n = self.sellPosted or 0
	self.sellList, self.sellIndex = nil, nil
	self.sellSettleFor, self.sellArmAt = nil, nil
	self.sellReplanWanted = nil
	self:SetStatus(format("Finished: %d auction%s posted.", n, n == 1 and "" or "s"))
	self:Print(format("Finished posting: %d auction%s.", n, n == 1 and "" or "s"))
	self:UpdateUI()
end

-- pass on the lot currently on the button and load the next one
function BS:SellSkip()
	if not self.armedSell then return end
	local it = self.armedSell.item
	self.armedSell = nil
	ClearCursor()
	self:Print("Skipped " .. ((it and (it.link or it.name)) or "?") .. ".")
	self:SellArmNext()
end

-- how an item's lots read in one phrase: "5 x 4 + 3"
function BS.LotText(it)
	if not it or it.total == 0 then return "-" end
	if it.full == 0 then return tostring(it.rest) end

	local base = (it.full == 1) and tostring(it.size)
		or format("%d x %d", it.full, it.size)
	if it.rest > 0 then return base .. " + " .. it.rest end
	return base
end

-- printed version, for checking the plan without opening the panel
function BS:PrintSellPlan()
	local queue, skipped, plan = self:SellQueue()
	local s = self:SellSettings()

	local auctions = 0
	for _, lot in ipairs(queue) do auctions = auctions + lot.stacks end

	self:Print(format("%s: %d item%s, %d auction%s in %d press%s.",
		self:SellRangeText(),
		#plan, #plan == 1 and "" or "s",
		auctions, auctions == 1 and "" or "s",
		#queue, #queue == 1 and "" or "es"))

	local total = 0
	for _, it in ipairs(plan) do
		total = total + it.worth
		self:Print(format("   %s  x%d  ->  %s  =  %s",
			it.link or it.name, it.total, BS.LotText(it), BS.Money(it.worth)))
		for _, lot in ipairs(it.lots) do
			self:Print(format("      %d auction%s of %d at %s each%s",
				lot.stacks, lot.stacks == 1 and "" or "s", lot.count,
				BS.Money(lot.buyout),
				lot.remainder and "  |cff888888(remainder)|r" or ""))
		end
	end
	if #plan > 0 then
		self:Print(format("Asking |cffffd100%s|r in all, undercutting by %d%%.",
			BS.Money(total), s.undercut))
	end

	if skipped.bound > 0 then
		self:Print(format("|cff888888%d soulbound - those cannot be auctioned.|r",
			skipped.bound))
	end
	if skipped.priced > 0 then
		self:Print(format("|cffff8800%d have no known price|r - left alone rather "
			.. "than guessed at.", skipped.priced))
	end
end
