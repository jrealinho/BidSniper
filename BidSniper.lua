--[[--------------------------------------------------------------------------
	BidSniper - core scan engine

	Finds auctions where the current bid is far below the buyout, e.g.
	1s bid / 15g buyout.  Written for WoW 3.3.5a (WotLK / Warmane).
----------------------------------------------------------------------------]]

BidSniper = {}
local BS = BidSniper

local ITEMS_PER_PAGE   = 50		-- NUM_AUCTION_ITEMS_PER_PAGE, hardcoded so we
					-- don't depend on Blizzard_AuctionUI being loaded
local MAX_RESULTS_HARD = 2000		-- safety cap on stored matches
local MAX_PAGES        = 2000		-- safety cap on paged scans
local QUERY_TIMEOUT    = 15		-- seconds before a query is considered lost

BS.defaults = {
	minRatio    = 10,		-- buyout / bid must be at least this
	maxBid      = 500000,		-- copper; 0 = no limit  (default 50g)
	minBuyout   = 10000,		-- copper; ignore junk    (default 1g)
	minQuality  = 0,		-- 0 = poor and up
	hideOwn     = true,		-- hide my own auctions / auctions I lead
	onlyNoBids  = false,		-- only auctions nobody has bid on yet
	endingSoon  = false,		-- only time left Short or Medium
	autoShow    = true,		-- open the window with the auction house
	scanMethod  = "auto",		-- auto | paged | getall
	category    = 0,		-- 0 = every category, else an auction class index
	wishlist    = {},		-- item names to check on a wishlist scan
	priceCache  = {},		-- item name -> { v = unit price, t = when }
	knownChars  = {},		-- every character of yours that has logged in
	sortKey     = "ratio",
	sortDesc    = true,
	point       = nil,		-- window position
}

BS.results  = {}
BS.scanning = false
BS.atAH     = false

--=============================================================================
--  helpers
--=============================================================================

local floor, format, sort = math.floor, string.format, table.sort

function BS:Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99BidSniper|r: " .. tostring(msg))
end

-- 1234567 -> "1,234,567"
function BS.Comma(n)
	local s = tostring(floor(n))
	local k
	repeat
		s, k = string.gsub(s, "^(-?%d+)(%d%d%d)", "%1,%2")
	until k == 0
	return s
end

-- compact coloured money string, e.g. "15g 23s" / "1s 50c" / "34c"
function BS.Money(c)
	c = floor(tonumber(c) or 0)
	local sign = ""
	if c < 0 then sign, c = "-", -c end
	local g = floor(c / 10000)
	local s = floor((c % 10000) / 100)
	local cc = c % 100
	if g > 0 then
		return format("%s|cffffd700%s|rg |cffc7c7cf%d|rs", sign, BS.Comma(g), s)
	elseif s > 0 then
		return format("%s|cffc7c7cf%d|rs |cffeda55f%d|rc", sign, s, cc)
	end
	return format("%s|cffeda55f%d|rc", sign, cc)
end

-- plain, exactly re-parseable money text for edit boxes: "15g", "1g23s45c"
function BS.MoneyPlain(c)
	c = floor(tonumber(c) or 0)
	if c == 0 then return "0" end
	local sign = ""
	if c < 0 then sign, c = "-", -c end
	local g  = floor(c / 10000)
	local s  = floor((c % 10000) / 100)
	local cc = c % 100
	local out = sign
	if g > 0  then out = out .. BS.Comma(g) .. "g" end
	if s > 0  then out = out .. s .. "s" end
	if cc > 0 then out = out .. cc .. "c" end
	return out
end

-- "15g", "1s50c", "250" -> copper.  Plain numbers are read as gold.
function BS.ParseMoney(text)
	if not text then return nil end
	text = string.lower(string.gsub(text, "[%s,]", ""))
	if text == "" then return 0 end

	if string.find(text, "[gsc]") then
		local copper = 0
		local matched = false
		for amount, unit in string.gmatch(text, "(%d+%.?%d*)([gsc])") do
			amount = tonumber(amount) or 0
			if unit == "g" then copper = copper + amount * 10000
			elseif unit == "s" then copper = copper + amount * 100
			else copper = copper + amount end
			matched = true
		end
		if not matched then return nil end
		return floor(copper)
	end

	local gold = tonumber(text)
	if not gold then return nil end
	return floor(gold * 10000)
end

BS.timeLeftText = { "|cffff5555<30m|r", "|cffffcc00<2h|r", "<12h", ">12h" }

-- Longest an auction with that time-left bracket can still be around for.
-- Once a result is older than its bracket the auction has certainly ended,
-- whether it sold, was bought out, or was cancelled.
local MAX_LIFE = { 30 * 60, 2 * 3600, 12 * 3600, 48 * 3600 }

function BS.Expired(r)
	if not r.seen then return false end		-- scanned before we recorded ages
	return (time() - r.seen) > (MAX_LIFE[r.timeLeft or 4] or MAX_LIFE[4])
end

-- How stale a row is, as a fraction of its remaining life. Used to warn about
-- rows that are probably gone without claiming they certainly are.
function BS.Doubtful(r)
	if not r.seen then return false end
	return (time() - r.seen) > (MAX_LIFE[r.timeLeft or 4] or MAX_LIFE[4]) * 0.5
end

-- Auctionator's price database, if the user has it loaded
function BS.MarketValue(link)
	if not link or type(Atr_GetAuctionBuyout) ~= "function" then return nil end
	local ok, value = pcall(Atr_GetAuctionBuyout, link)
	if ok and type(value) == "number" and value > 0 then return value end
	return nil
end

--[[
	Prices are cached by item name in saved variables. Two reasons: the Profit
	column fills in the moment a saved scan loads instead of asking Auctionator
	for every row again, and an item whose price we learned last week still
	reads sensibly if Auctionator's own data is not loaded yet.

	Entries carry a timestamp and are thrown away after a day, so the cache
	cannot quietly serve prices from a different market.
]]
local PRICE_TTL = 24 * 3600
local NO_PRICE_TTL = 10 * 60	-- "no price known" expires fast: Auctionator's
				-- own database may fill in at any moment

local function CacheTTL(entry)
	return (entry.v and entry.v > 0) and PRICE_TTL or NO_PRICE_TTL
end

function BS:PrunePriceCache()
	local cache = self.db.priceCache
	if not cache then self.db.priceCache = {} return end

	local now = time()
	for name, entry in pairs(cache) do
		if type(entry) ~= "table" or not entry.t or (now - entry.t) > CacheTTL(entry) then
			cache[name] = nil
		end
	end
end

-- forget every cached price and recompute; for after an Auctionator scan
function BS:ClearPriceCache()
	self.db.priceCache = {}
	for _, r in ipairs(self.results) do r.market, r.profit = nil, nil end
	self:Print("Cleared cached prices - the Profit column will rebuild.")
	self:UpdateUI()
end

-- unit price for an item, from the cache when it is fresh enough
function BS:CachedUnitPrice(r)
	local key = r.name
	if not key then return nil end

	local cache = self.db.priceCache
	if not cache then cache = {} self.db.priceCache = cache end

	local entry = cache[key]
	local now   = time()
	if entry and entry.t and (now - entry.t) <= CacheTTL(entry) then
		return (entry.v > 0) and entry.v or nil
	end

	local unit = BS.MarketValue(r.link or key)
	cache[key] = { v = unit or 0, t = now }
	return unit
end

-- market value of the whole stack, and what you would make over the bid.
-- Both stay nil when there is no price: an unknown item must not read as a
-- huge loss, and it must not read as a huge win either.
function BS:FillValue(r)
	if r.market ~= nil then return end
	local unit = self:CachedUnitPrice(r)
	if unit then
		r.market = unit * r.count
		r.profit = r.market - r.bid
	else
		r.market = 0
		r.profit = nil
	end
end

function BS:FillAllValues()
	for _, r in ipairs(self.results) do self:FillValue(r) end
end

--=============================================================================
--  wishlist
--=============================================================================

-- Accepts a typed name or a pasted/shift-clicked item link, from which the
-- name inside the brackets is taken.
function BS.CleanItemName(text)
	if not text then return nil end
	local name = string.match(text, "|h%[(.-)%]|h") or text
	name = string.gsub(name, "^%s*(.-)%s*$", "%1")
	if name == "" then return nil end
	return name
end

function BS:WishlistAdd(text)
	local name = BS.CleanItemName(text)
	if not name then
		self:Print("Type an item name, or shift-click an item to paste its link.")
		return false
	end

	local lower = string.lower(name)
	for _, existing in ipairs(self.db.wishlist) do
		if string.lower(existing) == lower then
			self:Print("\"" .. name .. "\" is already on your wishlist.")
			return false
		end
	end

	table.insert(self.db.wishlist, name)
	sort(self.db.wishlist, function(a, b) return string.lower(a) < string.lower(b) end)
	self:Print("Added \"" .. name .. "\" to your wishlist.")
	self:RefreshWishlist()
	return true
end

function BS:WishlistRemove(index)
	local name = self.db.wishlist[index]
	if not name then return end
	table.remove(self.db.wishlist, index)
	self:Print("Removed \"" .. name .. "\" from your wishlist.")
	self:RefreshWishlist()
end

--=============================================================================
--  scanning
--=============================================================================

local ev = CreateFrame("Frame", "BidSniperEventFrame")

-- keep the saved copy pointing at the live table
function BS:SetResults(t)
	self.results = t
	if BidSniperDB then BidSniperDB.lastResults = t end
end

-- Ask the server to sort the browse list by current bid, cheapest first.
-- SortAuctionItems toggles, so we may have to call it twice (same trick TSM uses).
function BS:ApplyBidSort()
	if type(SortAuctionItems) ~= "function" then return false end
	if not pcall(SortAuctionItems, "list", "bid") then return false end

	if type(IsAuctionSortReversed) == "function" then
		if IsAuctionSortReversed("list", "bid") then
			if not pcall(SortAuctionItems, "list", "bid") then return false end
		end
		return not IsAuctionSortReversed("list", "bid")
	end
	return true
end

-- The auction house's own category list, fetched once it is available.
function BS:CategoryNames()
	if not self.categoryNames then
		local ok, t = pcall(function() return { GetAuctionItemClasses() } end)
		if ok and t and #t > 0 then self.categoryNames = t end
	end
	return self.categoryNames
end

function BS:CategoryLabel(index)
	if not index or index == 0 then return "All categories" end
	local names = self:CategoryNames()
	return (names and names[index]) or ("Category " .. index)
end

-- A scan is a queue of queries. Normally one ("everything", or one category),
-- but a wishlist scan is one query per item on the list.
function BS:BuildQueries(mode)
	local list = {}

	if mode == "wishlist" then
		for _, name in ipairs(self.db.wishlist) do
			if name and name ~= "" then
				list[#list + 1] = { name = name, label = name }
			end
		end
	else
		local c = self.db.category or 0
		list[1] = {
			name       = "",
			classIndex = (c > 0) and c or nil,
			label      = self:CategoryLabel(c),
		}
	end

	return list
end

local FILTER_KEYS = { "minRatio", "maxBid", "minBuyout", "minQuality",
                      "hideOwn", "onlyNoBids", "endingSoon", "category" }

-- Remember where an interrupted scan got to, so it can pick up rather than
-- start the whole auction house again. Only paged scans have a position worth
-- keeping: a GetAll is one request, there is no halfway through it.
function BS:SaveResume()
	local partway = (self.page and self.page > 0) or ((self.queryIndex or 1) > 1)
	if self.useGetAll or not partway then
		self.db.resume = nil
		return
	end

	local filters = {}
	for _, k in ipairs(FILTER_KEYS) do filters[k] = self.db[k] end

	self.db.resume = {
		page       = self.page,
		queryIndex = self.queryIndex or 1,
		queryLabel = (self.queries and self.queries[self.queryIndex or 1]
		              and self.queries[self.queryIndex or 1].label) or nil,
		mode       = self.scanMode,
		scanned    = self.scannedCount or 0,
		total      = self.totalAuctions or 0,
		matches    = #self.results,
		time       = time(),
		filters    = filters,
	}
end

function BS:ResumeInfo()
	local res = self.db and self.db.resume
	if not res then return nil end
	local pages = res.total > 0 and math.ceil(res.total / ITEMS_PER_PAGE) or 0
	return res, res.page + 1, pages
end

local function FiltersChanged(saved, db)
	if not saved then return false end
	for _, k in ipairs(FILTER_KEYS) do
		if saved[k] ~= db[k] then return true end
	end
	return false
end

function BS:StartScan(resume, mode)
	if self.scanning then return end
	if not self.atAH then
		self:Print("Open the auction house first.")
		return
	end

	local canQuery, canQueryAll = CanSendAuctionQuery("list")

	local res = resume and self.db.resume or nil
	mode = res and res.mode or mode or "normal"

	self.scanMode  = mode
	self.queries   = self:BuildQueries(mode)
	self.queryIndex = 1

	if #self.queries == 0 then
		self:Print("Your wishlist is empty - add some items to it first.")
		return
	end

	if res then
		self.queryIndex = math.min(res.queryIndex or 1, #self.queries)
		self.page       = res.page

		-- the wishlist may have been edited since; if this slot no longer
		-- holds what it did, start that item from its first page
		local q = self.queries[self.queryIndex]
		if res.queryLabel and q and q.label ~= res.queryLabel then
			self:Print("The list being scanned changed since that scan stopped, "
				.. "so \"" .. q.label .. "\" restarts from the beginning.")
			self.page = 0
		end

		if FiltersChanged(res.filters, self.db) then
			self:Print("Note: your filters changed since that scan stopped, so the "
				.. "older results were matched against different settings.")
		end
		self.scannedCount = res.scanned or 0
		self:Print(format("Resuming at page %d, keeping %d result%s already found.",
			res.page + 1, #self.results, #self.results == 1 and "" or "s"))
	else
		self:SetResults({})
		self.page         = 0
		self.scannedCount = 0
	end
	self.db.resume      = nil
	self.totalAuctions  = 0
	self.totalPages     = nil
	self.lastPageSig    = nil
	self.dupRetries     = 0
	self.truncated      = false
	self.stoppedEarly   = false
	self.retries        = 0
	self.throttle       = 0
	self.scanning       = true
	self.queryPending   = true
	self.awaitingResults= false
	self.processing     = false
	self.scanStart      = GetTime()

	-- GetAll ignores every filter and returns the whole house, so it is only
	-- any use for an unfiltered scan. A resume stays paged too, or it would
	-- throw away the pages already read.
	local method = self.db.scanMethod
	local getAllUsable = not res and mode == "normal" and (self.db.category or 0) == 0
	self.useGetAll = getAllUsable and ((method == "getall") or (method == "auto" and canQueryAll))
	if self.useGetAll and not canQueryAll then
		self.useGetAll = false
		self:Print("GetAll is not available right now (server or 15 minute cooldown) - scanning page by page.")
	end

	-- A GetAll dump comes back unsorted, so sorting only makes sense per page.
	-- Cheapest bid first means the auctions you care about arrive first, and
	-- once bids pass your max bid there is nothing left worth reading.
	self.sorted = false
	if self.useGetAll then
		SortAuctionClearSort("list")
	else
		self.sorted = self:ApplyBidSort()
		if not self.sorted then SortAuctionClearSort("list") end
	end

	self:UpdateUI()
	self:SetStatus(self.useGetAll and "Requesting full auction list..."
		or self:ScanStatusText())
end

function BS:StopScan(reason)
	if not self.scanning then return end
	self.scanning     = false
	self.queryPending = false
	self.awaitingResults = false
	self.processing   = false

	self:SaveResume()
	local res, nextPage, pages = self:ResumeInfo()

	if res then
		self:SetStatus(format("%s  |cffffd100Stopped at page %d%s - press Resume scan.|r",
			reason or "Scan stopped.", nextPage,
			pages > 0 and (" of " .. pages) or ""))
	else
		self:SetStatus(reason or "Scan cancelled.")
	end
	self:UpdateUI()
end

function BS:FinishScan()
	self.scanning     = false
	self.queryPending = false
	self.awaitingResults = false
	self.processing   = false

	self:SortResults()

	self.db.lastScanTime = time()
	self.db.resume       = nil		-- finished: nothing left to resume

	local secs = GetTime() - (self.scanStart or GetTime())
	self:SetStatus(format("%d match%s in %s auctions  (%.0fs)%s%s",
		#self.results,
		#self.results == 1 and "" or "es",
		BS.Comma(self.scannedCount),
		secs,
		self.stoppedEarly and "  |cff00ff00[stopped at your max bid]|r" or "",
		self.truncated and "  |cffff5555[capped]|r" or ""))
	self:UpdateUI()

	if #self.results == 0 then
		self:Print("No auctions matched your filters. Try lowering the ratio or raising the max bid.")
	end
end

-- reads one auction row and stores it if it passes the filters
function BS:Evaluate(index)
	local name, texture, count, quality, canUse, level, minBid, minIncrement,
	      buyoutPrice, bidAmount, highBidder, owner = GetAuctionItemInfo("list", index)

	if not name or not buyoutPrice or buyoutPrice <= 0 then return end

	count        = count or 1
	bidAmount    = bidAmount or 0
	minIncrement = minIncrement or 0
	minBid       = minBid or 0

	-- what you would actually have to pay to be the high bidder right now
	local bid = (bidAmount > 0) and (bidAmount + minIncrement) or minBid
	if bid <= 0 or bid >= buyoutPrice then return end

	local cfg = self.db
	if cfg.onlyNoBids and bidAmount > 0 then return end
	if cfg.hideOwn then
		if highBidder then return end
		-- every character of yours that has logged in, not just this one:
		-- bidding on your own alt's auction is the same mistake
		if owner and cfg.knownChars and cfg.knownChars[owner] then return end
	end
	if quality and quality < cfg.minQuality then return end
	if buyoutPrice < cfg.minBuyout then return end
	if cfg.maxBid > 0 and bid > cfg.maxBid then return end

	local timeLeft = GetAuctionItemTimeLeft("list", index) or 4
	if cfg.endingSoon and timeLeft > 2 then return end

	local ratio = buyoutPrice / bid
	if ratio < cfg.minRatio then return end

	if #self.results >= MAX_RESULTS_HARD then
		self.truncated = true
		return
	end

	self.results[#self.results + 1] = {
		link     = GetAuctionItemLink("list", index),
		name     = name,
		texture  = texture,
		count    = count,
		quality  = quality or 1,
		level    = level,
		bid      = bid,
		buyout   = buyoutPrice,
		ratio    = ratio,
		timeLeft = timeLeft,
		owner    = owner,
		hasBid   = bidAmount > 0,
		seen     = time(),
	}
end

-- Cheap fingerprint of the loaded page. Auctions being posted and bought
-- while we page through can make the server hand back a page we have already
-- read; re-asking is better than counting it twice.
function BS:PageSignature()
	local n = GetNumAuctionItems("list") or 0
	if n == 0 then return "empty" end

	local parts = { n }
	for _, i in ipairs({ 1, math.ceil(n / 2), n }) do
		local name, _, count, _, _, _, minBid, _, buyout, bidAmount =
			GetAuctionItemInfo("list", i)
		parts[#parts + 1] = table.concat({
			tostring(name), tostring(count), tostring(minBid),
			tostring(buyout), tostring(bidAmount),
		}, ":")
	end
	return table.concat(parts, "|")
end

function BS:ScanStatusText()
	local q = self.queries and self.queries[self.queryIndex]
	local where
	if not q then
		where = format("page %d", (self.page or 0) + 1)
	elseif #self.queries > 1 then
		where = format("%s (%d/%d), page %d",
			q.label, self.queryIndex, #self.queries, self.page + 1)
	elseif self.totalPages and self.totalPages > 0 then
		where = format("page %d/%d", self.page + 1, self.totalPages)
	else
		where = format("page %d", self.page + 1)
	end
	return format("Scanning %s  -  %d match%s", where, #self.results,
		#self.results == 1 and "" or "es")
end

-- read the current batch a slice at a time so the client doesn't freeze
function BS:ProcessChunk()
	local chunk = self.useGetAll and 1000 or ITEMS_PER_PAGE
	local last  = math.min(self.readIndex + chunk - 1, self.batchCount)

	for i = self.readIndex, last do
		self:Evaluate(i)
	end
	self.readIndex = last + 1

	if self.readIndex > self.batchCount then
		self.processing   = false
		self.scannedCount = self.scannedCount + self.batchCount

		if self.useGetAll then
			self:FinishScan()
			return
		end

		local queryDone = false

		-- Sorted cheapest-bid-first: the last row on the page is the dearest we
		-- have seen, so once it clears the max bid every later page does too.
		if self.sorted and self.db.maxBid > 0 and self.batchCount > 0 then
			local _, _, _, _, _, _, minBid, _, _, bidAmount =
				GetAuctionItemInfo("list", self.batchCount)
			local sortBid = (bidAmount and bidAmount > 0) and bidAmount or (minBid or 0)
			if sortBid > self.db.maxBid then
				self.stoppedEarly = true
				queryDone = true
			end
		end

		if not queryDone then
			self.totalPages = math.ceil(self.totalAuctions / ITEMS_PER_PAGE)
			self.page = self.page + 1
			if self.batchCount == 0 or self.page >= self.totalPages
			   or self.page >= MAX_PAGES then
				queryDone = true
			end
		end

		-- finished this query: move on to the next one in the queue
		if queryDone then
			self.queryIndex  = self.queryIndex + 1
			self.page        = 0
			self.totalPages  = nil		-- belongs to the query just finished
			self.lastPageSig = nil
			self.dupRetries  = 0
			if self.queryIndex > #self.queries then
				self:FinishScan()
				return
			end
		end

		self.queryPending = true
		self:SetStatus(self:ScanStatusText())
	elseif self.useGetAll then
		self:SetStatus(format("Processing %s/%s auctions...",
			BS.Comma(self.readIndex - 1), BS.Comma(self.batchCount)))
	end
end

ev:SetScript("OnUpdate", function(self, elapsed)
	-- looking up a single auction so we can bid on it
	if BS.bidQueryPending then
		BS.bidThrottle = BS.bidThrottle + elapsed
		-- never sit waiting for a send slot forever
		if BS.bidThrottle > QUERY_TIMEOUT * 2 then
			local inBatch = BS.batch ~= nil
			BS:CancelBidSearch("The server would not take the lookup - skipped.")
			if inBatch then BS:BatchStep("gone") end
			return
		end
		-- give a bid a moment to land before firing the next query at the
		-- server, so the two cannot race over which auction list is current
		if BS.bidThrottle >= 0.15
		   and GetTime() >= (BS.bidQueryEarliest or 0)
		   and CanSendAuctionQuery("list") then
			BS.bidThrottle       = 0
			BS.bidQueryPending   = false
			BS.bidAwaiting       = true
			BS.bidQueryTime      = GetTime()
			-- loadedQueryName is set when the results actually arrive, not
			-- here: a query that never answers must not leave us believing
			-- the list holds this item.
			QueryAuctionItems(BS.bidSearch.result.name, nil, nil, nil, nil, nil,
				BS.bidSearch.page, nil, nil)
		end
		return
	elseif BS.bidAwaiting then
		if GetTime() - (BS.bidQueryTime or 0) > QUERY_TIMEOUT then
			local inBatch = BS.batch ~= nil
			BS:CancelBidSearch("Lookup timed out.")
			-- a batch carries on rather than stalling on one bad item
			if inBatch then BS:BatchStep("gone") end
		end
		return
	end

	if BS.processing then
		BS:ProcessChunk()
		return
	end
	if not BS.scanning then return end

	if BS.queryPending then
		BS.throttle = BS.throttle + elapsed
		if BS.throttle < 0.15 then return end

		local canQuery, canQueryAll = CanSendAuctionQuery("list")
		if not canQuery then return end

		if BS.useGetAll and not canQueryAll then
			BS.useGetAll = false
			BS:Print("GetAll is on cooldown, falling back to a page-by-page scan.")
		end

		BS.throttle        = 0
		BS.queryPending    = false
		BS.awaitingResults = true
		BS.queryTime       = GetTime()

		-- a scan replaces the auction list, so no bid lookup can rely on it
		BS.loadedQueryName = nil

		if BS.useGetAll then
			QueryAuctionItems("", nil, nil, 0, 0, 0, 0, 0, 0, true)
		else
			local q = BS.queries[BS.queryIndex] or { name = "" }
			QueryAuctionItems(q.name or "", nil, nil, nil,
				q.classIndex, q.subclassIndex, BS.page, nil, nil)
		end

	elseif BS.awaitingResults then
		if GetTime() - (BS.queryTime or 0) > QUERY_TIMEOUT then
			if BS.useGetAll then
				-- plenty of private servers simply ignore GetAll: start over paged
				BS.useGetAll       = false
				BS.page            = 0
				BS.queryIndex      = 1
				BS.totalPages      = nil
				BS.scannedCount    = 0
				BS.awaitingResults = false
				BS.queryPending    = true
				BS:SetResults({})
				BS.sorted = BS:ApplyBidSort()
				if not BS.sorted then SortAuctionClearSort("list") end
				BS:Print("No answer to the GetAll request - switching to a page-by-page scan.")
				BS:SetStatus("Scanning page 1...")
			else
				BS.retries = BS.retries + 1
				if BS.retries > 3 then
					BS:StopScan("Scan aborted: the server stopped answering.")
				else
					BS.awaitingResults = false
					BS.queryPending    = true
				end
			end
		end
	end
end)

--=============================================================================
--  bidding
--=============================================================================

StaticPopupDialogs["BIDSNIPER_CONFIRM_BID"] = {
	text = "Place a bid of %s on\n%s ?",
	button1 = YES,
	button2 = NO,
	OnAccept = function(self)
		BidSniper:VerifyAndBid(self.data)
	end,
	timeout = 30,
	whileDead = 1,
	hideOnEscape = 1,
	showAlert = 1,
	preferredIndex = 3,
}

StaticPopupDialogs["BIDSNIPER_CONFIRM_BATCH"] = {
	text = "Bid on %s auctions for up to %s total?",
	button1 = YES,
	button2 = NO,
	OnAccept = function(self)
		BidSniper:RunBatch(self.data)
	end,
	timeout = 30,
	whileDead = 1,
	hideOnEscape = 1,
	showAlert = 1,
	preferredIndex = 3,
}

local BID_SEARCH_MAX_PAGES = 20

-- step 1: re-query the auction house for this item so we get a live index.
-- auto = place the bid as soon as we find it, no confirmation box.
function BS:BidOn(result, auto)
	if not self.atAH then
		self:Print("You need to be at the auction house.")
		return
	end
	if self.scanning then
		self:Print("Wait for the scan to finish first.")
		return
	end
	if self.bidSearch then return end
	if self.batch and not auto then
		self:Print("A batch is running - stop it first.")
		return
	end

	-- The auction house already has this item's results loaded from the last
	-- lookup, so the next few bids on the same item need no server round trip
	-- at all. That is what makes clicking through a batch quick.
	if self.loadedQueryName == result.name then
		self.bidSearch = { result = result, page = self.loadedQueryPage or 0, auto = auto }
		self:LocatePendingBid()
		return
	end

	-- cheapest bid first, so the auction we scanned lands on the first page
	self:ApplyBidSort()

	self.bidSearch       = { result = result, page = 0, auto = auto }
	self.bidQueryPending = true
	self.bidThrottle     = 0
	self:SetStatus("Looking up " .. (result.link or result.name) .. "...")
end

function BS:CancelBidSearch(reason)
	self.bidSearch       = nil
	self.bidQueryPending = false
	self.bidAwaiting     = false
	if reason then self:SetStatus(reason) end
end

-- Does auction `index` look like the one we scanned?
-- Deliberately does NOT compare the bid (that is what moves) and does NOT
-- compare the seller: GetAuctionItemInfo hands back a nil owner often enough
-- that matching on it loses auctions that are still perfectly biddable.
local function SameAuction(index, r)
	local name, _, count, _, _, _, _, _, buyout = GetAuctionItemInfo("list", index)
	if name ~= r.name or count ~= r.count or buyout ~= r.buyout then return false end
	if r.link then
		local link = GetAuctionItemLink("list", index)
		if link and link ~= r.link then return false end
	end
	return true
end

-- step 2: results came back - find our auction again
function BS:LocatePendingBid()
	local search = self.bidSearch
	if not search then return end
	local r = search.result

	local numBatch, total = GetNumAuctionItems("list")
	total = total or 0

	-- several identical auctions can be up at once; take the cheapest bid
	local best, bestBid
	local used = self.usedIndices or {}
	for i = 1, numBatch do
		-- our own earlier bid on this page has not been reflected back yet,
		-- so never offer the same row twice from one set of results
		if not used[i] and SameAuction(i, r) then
			local _, _, _, _, _, _, minBid, minIncrement, buyout, bidAmount =
				GetAuctionItemInfo("list", i)
			local bid = (bidAmount and bidAmount > 0) and (bidAmount + minIncrement) or minBid
			if bid and bid > 0 and bid < buyout and (not bestBid or bid < bestBid) then
				best, bestBid = i, bid
			end
		end
	end

	if best then
		local auto = search.auto
		self:CancelBidSearch()
		self:OfferBid(best, bestBid, r, auto)
		return
	end

	-- common item names span several pages, keep looking
	local nextPage = search.page + 1
	if nextPage * ITEMS_PER_PAGE < total and nextPage < BID_SEARCH_MAX_PAGES then
		search.page          = nextPage
		self.bidQueryPending = true
		self:SetStatus(format("Looking up %s (page %d)...", r.name, nextPage + 1))
		return
	end

	local inBatch = self.batch ~= nil
	self:CancelBidSearch("Auction no longer available.")
	if not inBatch then
		self:Print("That auction is gone - rescan to refresh.")
	end
	self:BatchStep("gone")
end

-- step 3: confirm (or, in auto mode, go straight to the bid)
function BS:OfferBid(index, bid, r, auto)
	local link = GetAuctionItemLink("list", index)
	local name = GetAuctionItemInfo("list", index)

	if GetMoney() < bid then
		self:Print("You cannot afford that bid (" .. BS.Money(bid) .. ").")
		self:SetStatus("Not enough gold for that bid.")
		if self.batch then self:EndBatch("Batch stopped: out of gold.") end
		return
	end

	local data = {
		index = index, bid = bid, link = link, name = name,
		count = r.count, buyout = r.buyout, result = r,
	}

	if auto then
		-- never quietly pay more than the price the row was showing
		if bid > r.bid then
			self:Print("Skipped " .. (link or r.name) .. ": bid rose from "
				.. BS.Money(r.bid) .. " to " .. BS.Money(bid) .. ".")
			self:BatchStep("outbid")
			return
		end
		self:ArmBid(data)
		return
	end

	if bid > r.bid then
		self:Print("Heads up: someone has bid since the scan - it now costs "
			.. BS.Money(bid) .. " instead of " .. BS.Money(r.bid) .. ".")
	end

	local dialog = StaticPopup_Show("BIDSNIPER_CONFIRM_BID", BS.Money(bid), link or r.name)
	if dialog then
		dialog.data = data
		self:SetStatus("Confirm the bid to place it.")
	end
end

--[[
	PlaceAuctionBid is a protected function: the client only lets it through
	while it is handling a mouse click or a key press. Called from a timer or
	an event handler it is silently blocked and the client prints "Interface
	action failed because of an AddOn" - which is exactly why every batched bid
	looked sent and never arrived.

	So a bid is prepared here (query, locate, price check) and then parked as
	"armed". The actual PlaceAuctionBid only ever happens in FireArmedBid,
	which is wired straight to a button's OnClick. One click, one bid: there is
	no way around that, and anything claiming otherwise is not placing bids.
]]
function BS:ArmBid(data)
	self.armed = data
	self:SetStatus(format("Ready: %s for %s  -  press BID",
		data.link or data.name, BS.Money(data.bid)))
	self:UpdateUI()
end

function BS:ClearArmed()
	self.armed = nil
	self:UpdateUI()
end

-- Pass on the auction currently on the button and move to the next one.
-- Also cancels a lookup that is still running, so a slow or stuck one cannot
-- hold up the rest of the queue.
function BS:SkipArmed()
	if self.armed then
		local r = self.armed.result
		self.armed = nil
		if r then
			r.selected = false
			self:Print("Skipped " .. (r.link or r.name) .. ".")
		end
	elseif self.bidSearch then
		local r = self.bidSearch.result
		self:CancelBidSearch()
		if r then
			r.selected = false
			self:Print("Skipped " .. (r.link or r.name) .. " (lookup cancelled).")
		end
	elseif not self.batch then
		return
	end

	self:UpdateUI()

	if self.batch then
		self:BatchStep("skipped")
	else
		self:SetStatus("Skipped.")
	end
end

-- MUST be reached from a real click. Do not call from OnUpdate or an event.
function BS:FireArmedBid()
	local data = self.armed
	if not data then return end
	self.armed = nil

	local placed = self:VerifyAndBid(data)
	if self.batch then
		self:BatchStep(placed and "done" or "failed")
	else
		self:UpdateUI()
	end
end

-- step 4: re-check the row right before spending, in case the list moved
function BS:VerifyAndBid(data)
	if not data or not self.atAH then return false end

	local listType = data.listType or "list"
	local name, _, count, _, _, _, minBid, minIncrement, buyout, bidAmount =
		GetAuctionItemInfo(listType, data.index)
	local link = GetAuctionItemLink(listType, data.index)
	local bid  = (bidAmount and bidAmount > 0) and (bidAmount + minIncrement) or minBid

	if name ~= data.name or count ~= data.count or buyout ~= data.buyout
	   or bid ~= data.bid or (data.link and link and link ~= data.link) then
		self:Print("The auction list changed - bid cancelled for safety. Please try again.")
		self:SetStatus("Bid cancelled: auction list changed.")
		return false
	end

	if GetMoney() < bid then
		self:Print("You cannot afford that bid.")
		return false
	end

	-- PlaceAuctionBid returns nothing and the server rejects silently, so note
	-- what we tried; UI_ERROR_MESSAGE just after this tells us if it refused.
	self.lastBidTime       = GetTime()
	self.lastBidResult     = data.result
	self.lastBidAmount     = bid
	self.lastBidLink       = link or name
	self.bidQueryEarliest  = GetTime() + 1
	self.usedIndices       = self.usedIndices or {}
	self.usedIndices[data.index] = true
	if listType == "bidder" then
		self.rebidUsed = self.rebidUsed or {}
		self.rebidUsed[data.index] = true
	end

	PlaceAuctionBid(listType, data.index, bid)

	-- Sent is not placed. The row is only marked once the server confirms via
	-- AUCTION_BIDDER_LIST_UPDATE; until then it is pending, and a refusal or a
	-- silence clears it again.
	if data.result then
		data.result.bidPending = true
		data.result.selected   = false
		self.bidSpent = (self.bidSpent or 0) + bid
	end
	self:Print("Sent bid " .. BS.Money(bid) .. " on " .. (link or name) .. ".")
	self:SetStatus("Bid sent for " .. (link or name) .. ".")
	self:UpdateUI()
	return true
end

-- the server refused the bid we just sent: undo our optimistic bookkeeping
function BS:BidRefused(reason)
	local r = self.lastBidResult
	if r then
		r.bidPlaced  = nil
		r.bidPending = nil
		self.bidSpent = math.max(0, (self.bidSpent or 0) - (self.lastBidAmount or 0))
	end
	self.lastBidTime = nil
	self:Print("|cffff4444Server refused that bid:|r " .. tostring(reason))
	self:SetStatus("Bid refused: " .. tostring(reason))
	self:UpdateUI()
	if self.batch then self:EndBatch("Batch stopped: the server refused a bid.") end
end

-- Bid on one auction of whatever the auction house currently has loaded,
-- printing every input and the raw call result. No scan, no re-query, no
-- lookup - just the API call, so a failure here is the API and not us.
function BS:TryBid(index, useSelect)
	if not self.atAH then
		self:Print("Open the auction house first.")
		return
	end

	local n = GetNumAuctionItems("list") or 0
	index = tonumber(index)
	if not index or index < 1 or index > n then
		self:Print(format("Usage: /snipe try <1-%d>. Search something in the Browse tab "
			.. "first; this uses whatever is on screen there.", n))
		return
	end

	local name, _, count, _, _, _, minBid, minInc, buyout, bidAmount, highBidder, owner =
		GetAuctionItemInfo("list", index)
	local link = GetAuctionItemLink("list", index)
	local bid  = (bidAmount and bidAmount > 0) and (bidAmount + minInc) or minBid

	self:Print("--- test bid on index " .. index .. " of " .. n .. " ---")
	self:Print("item: " .. tostring(link or name))
	self:Print(format("minBid=%s  minIncrement=%s  bidAmount=%s  buyout=%s",
		tostring(minBid), tostring(minInc), tostring(bidAmount), tostring(buyout)))
	self:Print(format("owner=%s  highBidder=%s  count=%s",
		tostring(owner), tostring(highBidder), tostring(count)))
	self:Print("your money: " .. BS.Money(GetMoney()) .. "   sending bid: " .. BS.Money(bid or 0))

	if not bid or bid <= 0 then
		self:Print("|cffff4444No usable bid amount - stopping.|r")
		return
	end

	if useSelect then
		if type(SetSelectedAuctionItem) == "function" then
			local ok, err = pcall(SetSelectedAuctionItem, "list", index)
			self:Print("SetSelectedAuctionItem ok=" .. tostring(ok) .. " err=" .. tostring(err))
		else
			self:Print("SetSelectedAuctionItem does not exist on this client.")
		end
	end

	self.lastBidTime   = GetTime()
	self.lastBidResult = nil
	self.lastBidAmount = bid
	self.lastBidLink   = link or name

	local ok, err = pcall(PlaceAuctionBid, "list", index, bid)
	self:Print("PlaceAuctionBid ok=" .. tostring(ok) .. "  err=" .. tostring(err))
	self:Print("Watch for an accept/refuse line, then run /snipe bids.")
end

function BS:PrintMyBids()
	local n = GetNumAuctionItems("bidder") or 0
	self:SetStatus("")
	self:Print(format("You are on %d auction%s:", n, n == 1 and "" or "s"))
	for i = 1, n do
		local name, _, count, _, _, _, _, _, _, bidAmount, highBidder =
			GetAuctionItemInfo("bidder", i)
		self:Print(format("   %s x%d  -  %s  %s",
			tostring(name), count or 1, BS.Money(bidAmount or 0),
			highBidder and "|cff00ff00winning|r" or "|cffff8800outbid|r"))
	end
	if n == 0 then
		self:Print("   (nothing - no bids of yours reached the server)")
	end
end

-- what the server says you have actually bid on
function BS:ShowMyBids()
	if not self.atAH then
		self:Print("Open the auction house first.")
		return
	end
	self:WithBidderList("wantBidList", self.PrintMyBids)
end

-- Rebuild the "already bid" marks from the server's own bidder list rather
-- than from what this addon believed happened. Anything we optimistically
-- marked that never actually reached the server gets released.
function BS:SyncBids()
	if not self.atAH then
		self:Print("Open the auction house first.")
		return
	end
	self:WithBidderList("wantBidSync", self.ApplyBidSync)
end

function BS:ApplyBidSync()
	local mine = {}
	local n = GetNumAuctionItems("bidder") or 0
	for i = 1, n do
		local name, _, count, _, _, _, _, _, buyout = GetAuctionItemInfo("bidder", i)
		if name then
			mine[tostring(name) .. "|" .. tostring(count or 1) .. "|" .. tostring(buyout or 0)] = true
		end
	end

	local kept, released = 0, 0
	for _, r in ipairs(self.results) do
		local key = tostring(r.name) .. "|" .. tostring(r.count) .. "|" .. tostring(r.buyout)
		r.bidPending = nil
		if mine[key] then
			if not r.bidPlaced then r.bidPlaced = true end
			kept = kept + 1
		elseif r.bidPlaced then
			r.bidPlaced = nil
			released = released + 1
		end
	end

	self:Print(format("Checked %d of your live bids against the list: %d row%s marked, "
		.. "|cff00ff00%d released|r that were never actually bid on.",
		n, kept, kept == 1 and "" or "s", released))
	self:UpdateUI()
end

-- blunt version: drop every mark, no server check
function BS:ClearMarks()
	local n = 0
	for _, r in ipairs(self.results) do
		if r.bidPlaced or r.bidPending then n = n + 1 end
		r.bidPlaced, r.bidPending = nil, nil
	end
	self:Print(format("Cleared %d 'already bid' mark%s.", n, n == 1 and "" or "s"))
	self:UpdateUI()
end

--=============================================================================
--  batch bidding
--=============================================================================

-- ticked rows (whatever their state), and how many Select all would tick
function BS:CountSelected()
	local selected, selectable, total = 0, 0, 0
	for _, r in ipairs(self.results) do
		if not r.bidPlaced and not BS.Expired(r) then selectable = selectable + 1 end
		if r.selected then
			selected = selected + 1
			total = total + r.bid
		end
	end
	return selected, selectable, total
end

-- one button for both directions: tick everything, or clear everything.
-- Select all skips rows already bid on, but you can still tick those by hand -
-- a mark this addon got wrong must never lock a row away from you.
function BS:ToggleSelectAll()
	local selected, selectable = self:CountSelected()
	local want = (selected < selectable)
	for _, r in ipairs(self.results) do
		if want then
			-- never bulk-tick something already bid on or certainly ended
			if not r.bidPlaced and not BS.Expired(r) then r.selected = true end
		else
			r.selected = false
		end
	end
	self:UpdateUI()
end

--=============================================================================
--  re-bidding auctions you have been outbid on
--=============================================================================

StaticPopupDialogs["BIDSNIPER_CONFIRM_REBID"] = {
	text = "Re-bid on %s auctions you have been outbid on, for up to %s total?",
	button1 = YES,
	button2 = NO,
	OnAccept = function(self)
		BidSniper:RunBatch(self.data)
	end,
	timeout = 30,
	whileDead = 1,
	hideOnEscape = 1,
	showAlert = 1,
	preferredIndex = 3,
}

-- The Bids tab leaves its data in the client. If it is already there, use it
-- and skip the round trip entirely.
function BS:BidderListReady()
	return (GetNumAuctionItems("bidder") or 0) > 0
end

-- run `what` against the bidder list, fetching it only if we have to
function BS:WithBidderList(flag, what)
	if self:BidderListReady() then
		what(self)
		return
	end
	self[flag] = true
	self:SetStatus("Fetching your bids...")
	GetBidderAuctionItems()
end

function BS:RebidOutbid()
	if self.batch then
		self:Print("Finish or stop the current batch first.")
		return
	end
	if not self.atAH then
		self:Print("Open the auction house first.")
		return
	end
	self:WithBidderList("wantRebid", self.BuildRebidQueue)
end

-- The bidder list is already loaded, so these need no per-item lookup at all.
function BS:BuildRebidQueue()
	local list, total, tooDear, noBuyout = {}, 0, 0, 0
	local n = GetNumAuctionItems("bidder") or 0

	for i = 1, n do
		local name, texture, count, quality, _, level, minBid, minIncrement,
		      buyout, bidAmount, highBidder = GetAuctionItemInfo("bidder", i)

		if name and not highBidder then		-- not highBidder = outbid
			local bid = (bidAmount and bidAmount > 0) and (bidAmount + minIncrement) or minBid
			if bid and bid > 0 then
				if buyout > 0 and bid >= buyout then
					noBuyout = noBuyout + 1		-- cheaper to just buy it
				elseif self.db.maxBid > 0 and bid > self.db.maxBid then
					tooDear = tooDear + 1
				else
					list[#list + 1] = {
						source  = "bidder",
						link    = GetAuctionItemLink("bidder", i),
						name    = name,
						texture = texture,
						count   = count or 1,
						quality = quality or 1,
						level   = level,
						bid     = bid,
						buyout  = buyout,
					}
					total = total + bid
				end
			end
		end
	end

	self:SetStatus("")

	if tooDear > 0 then
		self:Print(format("%d outbid auction%s now cost more than your max bid of %s - left alone.",
			tooDear, tooDear == 1 and "" or "s", BS.Money(self.db.maxBid)))
	end
	if noBuyout > 0 then
		self:Print(format("%d outbid auction%s would now cost more than the buyout - left alone.",
			noBuyout, noBuyout == 1 and "" or "s"))
	end

	if #list == 0 then
		self:Print("Nothing to re-bid on: you are winning everything you can afford to chase.")
		self:SetStatus("No outbid auctions worth re-bidding.")
		return
	end

	local dialog = StaticPopup_Show("BIDSNIPER_CONFIRM_REBID", BS.Comma(#list), BS.Money(total))
	if dialog then dialog.data = { list = list, total = total } end
end

-- Find this auction in the bidder list as it stands now, rather than trusting
-- an index from before the last bid. Entries we are already winning are
-- skipped, so a re-bid that succeeded cannot be offered twice.
function BS:FindBidderIndex(r)
	local n = GetNumAuctionItems("bidder") or 0
	local used = self.rebidUsed or {}
	for i = 1, n do
		local name, _, count, _, _, _, _, _, buyout, _, highBidder =
			GetAuctionItemInfo("bidder", i)
		-- our own re-bid this session may not be reflected back yet, so an
		-- index we already bid on is off limits until the list refreshes
		if not used[i] and not highBidder
		   and name == r.name and count == r.count and buyout == r.buyout then
			if not r.link then return i end
			local link = GetAuctionItemLink("bidder", i)
			if not link or link == r.link then return i end
		end
	end
	return nil
end

function BS:PrepareBidderBid(r)
	local index = self:FindBidderIndex(r)
	if not index then
		self:BatchStep("gone")
		return
	end

	local name, _, count, _, _, _, minBid, minIncrement, buyout, bidAmount =
		GetAuctionItemInfo("bidder", index)
	local bid = (bidAmount and bidAmount > 0) and (bidAmount + minIncrement) or minBid

	if not bid or bid <= 0 then
		self:BatchStep("gone")
		return
	end
	if bid > r.bid then
		self:Print("Skipped " .. (r.link or r.name) .. ": outbid again, now "
			.. BS.Money(bid) .. ".")
		self:BatchStep("outbid")
		return
	end
	if GetMoney() < bid then
		self:EndBatch("Batch stopped: out of gold.")
		return
	end

	self:ArmBid({
		listType = "bidder",
		index    = index,
		bid      = bid,
		link     = GetAuctionItemLink("bidder", index),
		name     = name,
		count    = count,
		buyout   = buyout,
		result   = r,
	})
end

function BS:StartBatchBid()
	if self.batch then
		self:EndBatch("Batch stopped.")
		return
	end
	if not self.atAH then
		self:Print("You need to be at the auction house.")
		return
	end
	if self.scanning or self.bidSearch then
		self:Print("Wait for the current scan or lookup to finish.")
		return
	end

	local list, total = {}, 0
	for _, r in ipairs(self.results) do
		if r.selected then
			list[#list + 1] = r
			total = total + r.bid
		end
	end

	if #list == 0 then
		self:Print("Nothing selected - tick the boxes on the rows you want, or press Select all.")
		return
	end
	if GetMoney() < total then
		self:Print("Careful: the whole list costs " .. BS.Money(total)
			.. " and you have " .. BS.Money(GetMoney()) .. ". It will stop when you run out.")
	end

	local dialog = StaticPopup_Show("BIDSNIPER_CONFIRM_BATCH", BS.Comma(#list), BS.Money(total))
	if dialog then dialog.data = { list = list, total = total } end
end

function BS:RunBatch(data)
	if not data or not data.list then return end

	-- group by item so runs of the same item reuse one loaded page of results
	-- (re-bids come straight from the bidder list, so order does not matter)
	if not data.list[1] or data.list[1].source ~= "bidder" then
		sort(data.list, function(a, b)
			if a.name == b.name then return a.bid < b.bid end
			return a.name < b.name
		end)
	end

	self.batch      = data.list
	self.batchIndex = 1
	self.batchDone  = 0
	self.batchSkipped = 0
	self.batchBudget  = data.total
	self.bidSpent   = 0
	self:UpdateUI()
	self:BatchNext()
end

function BS:BatchNext()
	if not self.batch then return end

	if not self.atAH then
		self:EndBatch("Batch stopped: auction house closed.")
		return
	end

	-- A ticked row is honoured even if marked: if you really are already the
	-- high bidder the price guard in OfferBid catches it and skips, so this
	-- cannot bid you up against yourself.
	local r = self.batch[self.batchIndex]

	if not r then
		self:EndBatch(format("Batch finished: %d bid, %d skipped, %s spent.",
			self.batchDone, self.batchSkipped, BS.Money(self.bidSpent or 0)))
		return
	end
	self.batchIndex = self.batchIndex + 1

	if (self.bidSpent or 0) + r.bid > self.batchBudget then
		self:EndBatch("Batch stopped: that would go over the total you approved.")
		return
	end
	if GetMoney() < r.bid then
		self:EndBatch("Batch stopped: out of gold.")
		return
	end

	self:SetStatus(format("Batch %d/%d: %s", self.batchIndex - 1, #self.batch,
		r.link or r.name))

	if r.source == "bidder" then
		self:PrepareBidderBid(r)
	else
		self:BidOn(r, true)
	end
end

-- called after each queue entry resolves, however it resolved
function BS:BatchStep(outcome)
	if not self.batch then return end
	if outcome == "done" then
		self.batchDone = self.batchDone + 1
	elseif outcome ~= "skip" then
		self.batchSkipped = self.batchSkipped + 1
	end
	self:BatchNext()
end

function BS:EndBatch(reason)
	self.batch = nil
	self.armed = nil
	self.rebidUsed = {}
	self:CancelBidSearch()
	if reason then
		self:SetStatus(reason)
		self:Print(reason)
	end
	self:UpdateUI()
end

--=============================================================================
--  sorting
--=============================================================================

local NO_VALUE = -1e12		-- sorts unpriced items to the bottom of a profit sort

local sortFields = {
	name   = function(a, b) return a.name, b.name end,
	bid    = function(a, b) return a.bid, b.bid end,
	buyout = function(a, b) return a.buyout, b.buyout end,
	ratio  = function(a, b) return a.ratio, b.ratio end,
	time   = function(a, b) return a.timeLeft, b.timeLeft end,
	owner  = function(a, b) return a.owner or "", b.owner or "" end,
	market = function(a, b) return a.market or 0, b.market or 0 end,
	-- items with no known price sink to the bottom either way round
	profit = function(a, b) return a.profit or NO_VALUE, b.profit or NO_VALUE end,
}

function BS:SortResults()
	local key  = sortFields[self.db.sortKey] and self.db.sortKey or "ratio"
	local get  = sortFields[key]
	local desc = self.db.sortDesc

	if key == "market" or key == "profit" then self:FillAllValues() end

	sort(self.results, function(a, b)
		local av, bv = get(a, b)
		if av == bv then return a.name < b.name end
		if desc then return av > bv end
		return av < bv
	end)
end

function BS:SetSort(key)
	if self.db.sortKey == key then
		self.db.sortDesc = not self.db.sortDesc
	else
		self.db.sortKey  = key
		self.db.sortDesc = (key ~= "name" and key ~= "owner")
	end
	self:SortResults()
	self:UpdateUI()
end

--=============================================================================
--  events
--=============================================================================

ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("AUCTION_HOUSE_SHOW")
ev:RegisterEvent("AUCTION_HOUSE_CLOSED")
ev:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
ev:RegisterEvent("AUCTION_BIDDER_LIST_UPDATE")
ev:RegisterEvent("UI_ERROR_MESSAGE")

ev:SetScript("OnEvent", function(self, event, arg1)
	if event == "ADDON_LOADED" then
		if arg1 ~= "BidSniper" then return end

		BidSniperDB = BidSniperDB or {}
		for k, v in pairs(BS.defaults) do
			if BidSniperDB[k] == nil then
				-- copy table defaults: sharing the table would let saved data
				-- write back into the defaults themselves
				if type(v) == "table" then
					local copy = {}
					for k2, v2 in pairs(v) do copy[k2] = v2 end
					BidSniperDB[k] = copy
				else
					BidSniperDB[k] = v
				end
			end
		end
		-- tables a saved file from an older version will not have
		BidSniperDB.wishlist   = BidSniperDB.wishlist   or {}
		BidSniperDB.priceCache = BidSniperDB.priceCache or {}
		BidSniperDB.knownChars = BidSniperDB.knownChars or {}
		BS.db = BidSniperDB

		-- results are saved, so a /reload or a relog does not cost you a scan
		BidSniperDB.lastResults = BidSniperDB.lastResults or {}
		BS.results = BidSniperDB.lastResults

		-- prices saved with an old scan may be out of date by now
		for _, r in ipairs(BS.results) do
			r.market, r.profit = nil, nil
		end

		-- drop auctions that cannot possibly still be running
		local dropped = 0
		for i = #BS.results, 1, -1 do
			if BS.Expired(BS.results[i]) then
				table.remove(BS.results, i)
				dropped = dropped + 1
			end
		end
		if dropped > 0 then
			BS:Print(format("Dropped %d saved auction%s that have since ended.",
				dropped, dropped == 1 and "" or "s"))
		end

		BS:PrunePriceCache()

		BS:BuildUI()
		if #BS.results > 0 then
			BS:SortResults()
			BS:UpdateUI()

			local res, nextPage, pages = BS:ResumeInfo()
			if res then
				BS:SetStatus(format("%d result%s so far - scan stopped at page %d%s, "
					.. "press Resume scan.", #BS.results, #BS.results == 1 and "" or "s",
					nextPage, pages > 0 and (" of " .. pages) or ""))
			else
				BS:SetStatus(format("%d result%s from your last scan.",
					#BS.results, #BS.results == 1 and "" or "s"))
			end
		end

	elseif event == "PLAYER_LOGIN" then
		local me = UnitName("player")
		if me and BS.db then BS.db.knownChars[me] = true end

	elseif event == "AUCTION_HOUSE_SHOW" then
		BS.atAH = true
		if BS.db.autoShow and BS.frame then BS.frame:Show() end

	elseif event == "AUCTION_HOUSE_CLOSED" then
		BS.atAH = false
		if BS.scanning then BS:StopScan("Scan stopped: auction house closed.") end
		if BS.batch then BS:EndBatch("Batch stopped: auction house closed.") end
		BS:CancelBidSearch()
		-- an armed bid points at a list that no longer exists
		BS.armed           = nil
		BS.loadedQueryName = nil
		BS.usedIndices     = {}
		BS.rebidUsed       = {}
		if BS.frame then BS.frame:Hide() end

	elseif event == "UI_ERROR_MESSAGE" then
		-- anything the UI complains about within a moment of a bid is the
		-- server's answer to that bid
		if BS.lastBidTime and (GetTime() - BS.lastBidTime) < 3 then
			BS:BidRefused(arg1)
		end

	elseif event == "AUCTION_BIDDER_LIST_UPDATE" then
		if BS.lastBidTime and (GetTime() - BS.lastBidTime) < 3 then
			BS:Print("|cff00ff00Server accepted the bid.|r")
			BS.lastBidTime = nil
			local r = BS.lastBidResult
			if r then
				r.bidPending = nil
				r.bidPlaced  = true
				BS:UpdateUI()
			end
		end

		-- fresh list: indices are renumbered and anything we won back now
		-- reports us as high bidder, so the skip list has done its job
		BS.rebidUsed = {}

		if BS.wantRebid then
			BS.wantRebid = false
			BS:BuildRebidQueue()
		end

		if BS.wantBidSync then
			BS.wantBidSync = false
			BS:ApplyBidSync()
		end

		if BS.wantBidList then
			BS.wantBidList = false
			BS:PrintMyBids()
		end

	elseif event == "AUCTION_ITEM_LIST_UPDATE" then
		if BS.bidSearch and BS.bidAwaiting then
			BS.bidAwaiting = false
			-- results are really here now, so the list genuinely holds this
			-- item and nothing on the page has been bid on yet
			BS.loadedQueryName = BS.bidSearch.result.name
			BS.loadedQueryPage = BS.bidSearch.page
			BS.usedIndices     = {}
			BS:LocatePendingBid()
			return
		end
		if not BS.scanning or not BS.awaitingResults then return end

		local numBatch, total = GetNumAuctionItems("list")
		total = total or 0

		-- a GetAll result arrives in pieces; wait until the client has it all
		if BS.useGetAll and numBatch < total then return end

		-- the same page served twice: ask again rather than double-count it
		if not BS.useGetAll then
			local sig = BS:PageSignature()
			if BS.lastPageSig and sig == BS.lastPageSig then
				BS.dupRetries = (BS.dupRetries or 0) + 1
				if BS.dupRetries <= 3 then
					BS.awaitingResults = false
					BS.queryPending    = true
					return
				end
			end
			BS.dupRetries  = 0
			BS.lastPageSig = sig
		end

		BS.awaitingResults = false
		BS.retries         = 0
		BS.batchCount      = numBatch
		BS.totalAuctions   = total
		BS.readIndex       = 1
		BS.processing      = true
	end
end)

--=============================================================================
--  diagnostics
--=============================================================================

-- Answers "why did it walk the pages instead of pulling the lot in one go?"
function BS:DumpScanInfo()
	self:Print("scan method setting: |cffffffff" .. tostring(self.db.scanMethod) .. "|r")
	self:Print(format("saved results: |cffffffff%d|r%s", #self.results,
		self.db.lastScanTime
			and ("   last scan: " .. date("%d %b %H:%M", self.db.lastScanTime))
			or ""))

	local res, nextPage, pages = self:ResumeInfo()
	if res then
		self:Print(format("resume point: |cffffffffpage %d%s|r, %s auctions read, saved %s",
			nextPage, pages > 0 and (" of " .. pages) or "",
			BS.Comma(res.scanned or 0), date("%d %b %H:%M", res.time or 0)))
	else
		self:Print("resume point: none - the last scan finished or was never started")
	end

	if not self.atAH then
		self:Print("Open an auction house and run this again to test GetAll.")
		return
	end

	local canQuery, canQueryAll = CanSendAuctionQuery("list")
	self:Print(format("CanSendAuctionQuery -> query=|cffffffff%s|r  getAll=|cffffffff%s|r",
		tostring(canQuery), tostring(canQueryAll)))

	if canQueryAll then
		self:Print("GetAll is offered right now. If a scan still walks pages, the realm "
			.. "accepted the request but never answered it.")
	else
		self:Print("GetAll is not on offer: either the 15 minute client cooldown has not "
			.. "expired, or this realm does not allow it at all.")
	end
end

--=============================================================================
--  slash command
--=============================================================================

SLASH_BIDSNIPER1 = "/bidsniper"
SLASH_BIDSNIPER2 = "/snipe"
SlashCmdList["BIDSNIPER"] = function(msg)
	msg = string.lower(string.gsub(msg or "", "^%s*(.-)%s*$", "%1"))

	local cmd, rest = string.match(msg, "^(%S+)%s*(.*)$")

	if cmd == "try" then
		BS:TryBid(rest, false)
		return
	elseif cmd == "trysel" then
		BS:TryBid(rest, true)
		return
	end

	if msg == "scan" then
		if BS.frame then BS.frame:Show() end
		BS:StartScan(true)
	elseif msg == "newscan" then
		if BS.frame then BS.frame:Show() end
		BS:StartScan(false)
	elseif msg == "paged" then
		BS.db.scanMethod = "paged"
		BS:Print("Scan method: page by page (slow but always works).")
	elseif msg == "getall" then
		BS.db.scanMethod = "getall"
		BS:Print("Scan method: GetAll (fast, needs server support, 15 min cooldown).")
	elseif msg == "auto" then
		BS.db.scanMethod = "auto"
		BS:Print("Scan method: auto (GetAll when available, otherwise paged).")
	elseif msg == "bids" then
		BS:ShowMyBids()
	elseif msg == "syncbids" then
		BS:SyncBids()
	elseif msg == "clearmarks" then
		BS:ClearMarks()
	elseif msg == "prices" then
		BS:ClearPriceCache()
	elseif msg == "debug" then
		BS:DumpScanInfo()
	elseif msg == "layout" then
		BS:DumpLayout()
	elseif msg == "reset" then
		BidSniperDB = nil
		ReloadUI()
	elseif msg == "help" then
		BS:Print("/snipe - toggle the window")
		BS:Print("/snipe scan - start, or continue an interrupted scan")
		BS:Print("/snipe newscan - always start a fresh scan")
		BS:Print("/snipe auto | paged | getall - choose the scan method")
		BS:Print("/snipe bids - ask the server what you have actually bid on")
		BS:Print("/snipe syncbids - fix the 'already bid' marks from the server's list")
		BS:Print("/snipe clearmarks - drop every 'already bid' mark")
		BS:Print("/snipe prices - forget cached prices and rebuild the Profit column")
		BS:Print("/snipe try <n> - test-bid row n of the Browse list, showing everything")
		BS:Print("/snipe trysel <n> - same, but select the row first")
		BS:Print("/snipe debug - scan method, saved results, GetAll availability")
		BS:Print("/snipe layout - print where the filter boxes actually are")
		BS:Print("/snipe reset - restore defaults and reload")
	else
		if BS.frame then
			if BS.frame:IsShown() then BS.frame:Hide() else BS.frame:Show() end
		end
	end
end
