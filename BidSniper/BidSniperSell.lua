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
	return s
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

	return format("%s, slots %d to %s", table.concat(names, " + "),
		s.fromSlot, (s.toSlot > 0) and tostring(s.toSlot) or "the end")
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
	local s   = self:SellSettings()
	local out = {}

	for _, bag in ipairs(self:SellBags()) do
		local size = GetContainerNumSlots(bag) or 0

		-- 0 means "as far as this bag goes", which is what lets one range cover
		-- bags of different sizes without needing a number per bag
		local hi    = (s.toSlot > 0) and s.toSlot or size
		local first = math.max(1, math.min(s.fromSlot, hi))
		local last  = math.min(size, math.max(s.fromSlot, hi))

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
function BS:SellPrice(entry)
	--[[
		Our own scan first, Auctionator second.

		Auctionator's database only moves when Auctionator scans - we read it
		and never write to it - so a sweep from this addon used to leave these
		prices untouched, and only an Auctionator search would shift them. A
		scan here now records the cheapest of everything it walks past, and that
		is a better answer than Auctionator's anyway: it is from minutes ago
		rather than from whenever Auctionator last looked.
	]]
	local unit, src = self:LowestSeen(entry.name), "scan"
	if not unit or unit <= 0 then
		unit, src = BS.MarketValue(entry.link), "auctionator"
	end
	if not unit or unit <= 0 then return nil end
	entry.priceSrc = src

	local s      = self:SellSettings()
	local stack  = unit * entry.count
	local buyout = floor(stack * (100 - s.undercut) / 100)
	if buyout >= stack then buyout = stack - 1 end
	if buyout < 1 then buyout = 1 end

	local bid = floor(buyout * s.bidPct / 100)
	if bid < 1 then bid = 1 end
	if bid > buyout then bid = buyout end

	return buyout, bid, unit
end

--[[
	The queue: one entry per distinct item, carrying every stack of it.

	StartAuction posts several stacks of one item in a single call, so grouping
	is what turns a bag of six herb stacks into one press instead of six. Stacks
	of different sizes cannot share a call - the auction house posts numStacks
	lots of stackSize - so each size gets its own entry and its own press.
]]
function BS:SellQueue()
	local region = self:SellRegion()
	local groups, order = {}, {}
	local skipped = { bound = 0, priced = 0, locked = 0 }

	for _, e in ipairs(region) do
		if e.bound then
			skipped.bound = skipped.bound + 1
		elseif e.locked then
			skipped.locked = skipped.locked + 1
		else
			local buyout, bid, unit = self:SellPrice(e)
			if not buyout then
				skipped.priced = skipped.priced + 1
			else
				local key = tostring(e.link) .. ":" .. e.count
				local g   = groups[key]
				if not g then
					g = {
						link = e.link, name = e.name, count = e.count,
						quality = e.quality, slots = {},
						buyout = buyout, bid = bid, unit = unit,
						src = e.priceSrc,
					}
					groups[key]       = g
					order[#order + 1] = g
				end
				g.slots[#g.slots + 1] = { bag = e.bag, slot = e.slot }
			end
		end
	end

	-- dearest first, so if you stop half way you have posted what mattered
	sort(order, function(a, b)
		local av = (a.buyout or 0) * #a.slots
		local bv = (b.buyout or 0) * #b.slots
		if av == bv then return (a.name or "") < (b.name or "") end
		return av > bv
	end)

	return order, skipped
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
function BS:ArmSell(group)
	if not self.atAH then
		self:Print("You need to be at the auction house.")
		return false
	end
	if not group or not group.slots[1] then return false end

	local first = group.slots[1]

	-- the slot must still hold what was costed, or the press would post
	-- whatever has since been dropped into it
	if GetContainerItemLink(first.bag, first.slot) ~= group.link then
		self:Print("That bag slot has changed - press Refresh and try again.")
		return false
	end

	ClearCursor()
	PickupContainerItem(first.bag, first.slot)
	if GetCursorInfo() ~= "item" then
		ClearCursor()
		self:Print("Could not pick that item up.")
		return false
	end
	ClickAuctionSellItemButton()
	ClearCursor()

	self.armedSell = group
	self:SetStatus(format("Ready: %d x %s at %s each  -  press SELL",
		#group.slots, group.link or group.name, BS.Money(group.buyout)))
	self:UpdateUI()
	return true
end

-- MUST be reached from a real click. Do not call from OnUpdate or an event.
function BS:FireArmedSell()
	local group = self.armedSell
	if not group then return end
	self.armedSell = nil

	local s      = self:SellSettings()
	local stacks = #group.slots

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

	StartAuction(group.bid, group.buyout, s.duration, group.count, stacks)

	self:Print(format("Posted %d x %s at %s each, opening bid %s.",
		stacks, group.link or group.name, BS.Money(group.buyout), BS.Money(group.bid)))

	self.sellPosted = (self.sellPosted or 0) + stacks
	self:UpdateUI()
end

function BS:CancelSell()
	self.armedSell = nil
	self.sellList  = nil
	self.sellIndex = nil
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
function BS:SellStart()
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
	local list = self.sellList
	if not list then return end

	self.sellIndex = (self.sellIndex or 0) + 1

	while list[self.sellIndex] do
		if self:ArmSell(list[self.sellIndex]) then return end
		-- that one could not be loaded; go past it rather than stalling
		self.sellIndex = self.sellIndex + 1
	end

	local n = self.sellPosted or 0
	self.sellList, self.sellIndex = nil, nil
	self:SetStatus(format("Finished: %d auction%s posted.", n, n == 1 and "" or "s"))
	self:Print(format("Finished posting: %d auction%s.", n, n == 1 and "" or "s"))
	self:UpdateUI()
end

-- pass on the item currently on the button and load the next one
function BS:SellSkip()
	if not self.armedSell then return end
	local g = self.armedSell
	self.armedSell = nil
	ClearCursor()
	self:Print("Skipped " .. (g.link or g.name or "?") .. ".")
	self:SellArmNext()
end

-- printed version, for checking the plan without opening the panel
function BS:PrintSellPlan()
	local queue, skipped = self:SellQueue()

	self:Print(format("%s: %d thing%s to post.", self:SellRangeText(),
		#queue, #queue == 1 and "" or "s"))

	local total = 0
	for _, g in ipairs(queue) do
		local worth = g.buyout * #g.slots
		total = total + worth
		self:Print(format("   %d x %s  at %s each  =  %s",
			#g.slots, g.link or g.name, BS.Money(g.buyout), BS.Money(worth)))
	end
	if #queue > 0 then
		self:Print(format("Asking |cffffd100%s|r in all, undercutting by %d%%.",
			BS.Money(total), s.undercut))
	end

	if skipped.bound > 0 then
		self:Print(format("|cff888888%d soulbound - those cannot be auctioned.|r",
			skipped.bound))
	end
	if skipped.priced > 0 then
		self:Print(format("|cffff8800%d have no Auctionator price|r - left alone rather "
			.. "than guessed at.", skipped.priced))
	end
end
