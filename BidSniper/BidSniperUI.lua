--[[--------------------------------------------------------------------------
	BidSniper - window, filters and result list
----------------------------------------------------------------------------]]

local BS = BidSniper
local format = string.format

local ROW_HEIGHT = 20
local NUM_ROWS   = 15
local ROW_WIDTH  = 796

-- column layout: x offset inside a row, width, alignment, sort key
local COLS = {
	{ key = "name",   text = "Item",   x = 40,  w = 190, justify = "LEFT"   },
	{ key = "bid",    text = "Bid",    x = 232, w = 92,  justify = "RIGHT"  },
	{ key = "buyout", text = "Buyout", x = 326, w = 92,  justify = "RIGHT"  },
	{ key = "ratio",  text = "Ratio",  x = 420, w = 46,  justify = "RIGHT"  },
	{ key = "market", text = "Market", x = 468, w = 92,  justify = "RIGHT"  },
	{ key = "profit", text = "Profit", x = 562, w = 100, justify = "RIGHT"  },
	{ key = "time",   text = "Left",   x = 664, w = 44,  justify = "CENTER" },
	{ key = "owner",  text = "Seller", x = 710, w = 72,  justify = "LEFT"   },
}

--=============================================================================
--  small widget helpers
--=============================================================================

-- Every piece of text in this window gets an explicit font at an explicit
-- size. Inheriting a font object means another addon reassigning the global
-- fonts later (ElvUI does exactly that on login) silently resizes our text and
-- wrecks the layout. SetFont breaks that link, so what we measure is what we
-- get. Grab the path from Blizzard's own object, which is still untouched at
-- addon-load time.
local FONT_PATH = GameFontNormal:GetFont() or "Fonts\\FRIZQT__.TTF"

local function Font(obj, size, r, g, b)
	obj:SetFont(FONT_PATH, size or 11)
	if r then obj:SetTextColor(r, g, b) end
	return obj
end

-- Our own edit box rather than InputBoxTemplate: no $parent-named textures on
-- an unnamed frame, no inherited font, and nothing for a skinning addon to
-- resize behind our back.
local function MakeEditBox(parent, x, y, width)
	local eb = CreateFrame("EditBox", nil, parent)
	eb:SetPoint("TOPLEFT", x, y)
	eb:SetWidth(width)
	eb:SetHeight(20)
	eb:SetAutoFocus(false)
	eb:SetTextInsets(6, 6, 0, 0)
	eb:SetBackdrop({
		bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 10,
		insets = { left = 2, right = 2, top = 2, bottom = 2 },
	})
	eb:SetBackdropColor(0, 0, 0, 0.65)
	eb:SetBackdropBorderColor(0.45, 0.45, 0.45, 1)
	Font(eb, 11, 1, 1, 1)
	return eb
end

local function Tip(frame, title, body)
	frame:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(title, 1, 1, 1)
		if body then GameTooltip:AddLine(body, 0.8, 0.8, 0.8, true) end
		GameTooltip:Show()
	end)
	frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function MakeLabel(parent, text, x, y)
	local fs = parent:CreateFontString(nil, "ARTWORK")
	Font(fs, 11, 1, 0.82, 0)
	fs:SetPoint("TOPLEFT", x, y)
	fs:SetText(text)
	return fs
end

-- money edit box: shows/accepts "15g", "50s", or a plain number meaning gold
local function MakeMoneyEdit(parent, x, y, width, get, set, tipTitle, tipBody)
	local eb = MakeEditBox(parent, x, y, width)
	eb:SetMaxLetters(12)

	eb.Refresh = function() eb:SetText(BS.MoneyPlain(get())) end

	local function commit()
		local copper = BS.ParseMoney(eb:GetText())
		if copper then set(copper) else BS:Print("Could not read that amount. Use e.g. 50, 50g or 1s50c.") end
		eb.Refresh()
		eb:ClearFocus()
		BS:UpdateUI()
	end

	eb:SetScript("OnEnterPressed", commit)
	eb:SetScript("OnEditFocusLost", commit)
	eb:SetScript("OnEscapePressed", function() eb.Refresh() eb:ClearFocus() end)
	Tip(eb, tipTitle, tipBody)
	return eb
end

local function MakeCheck(parent, label, x, y, get, set, tipTitle, tipBody)
	local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	cb:SetPoint("TOPLEFT", x, y)
	cb:SetWidth(22)
	cb:SetHeight(22)

	local fs = parent:CreateFontString(nil, "ARTWORK")
	Font(fs, 11, 1, 1, 1)
	fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
	fs:SetText(label)

	cb.Refresh = function() cb:SetChecked(get()) end
	cb:SetScript("OnClick", function(self)
		set(self:GetChecked() and true or false)
		BS:UpdateUI()
	end)
	Tip(cb, tipTitle, tipBody)
	return cb
end

--=============================================================================
--  the window
--=============================================================================

function BS:BuildUI()
	if self.frame then return end

	local f = CreateFrame("Frame", "BidSniperFrame", UIParent)
	f:SetWidth(ROW_WIDTH + 46)
	f:SetHeight(566)
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:SetBackdrop({
		bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(self) self:StartMoving() end)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, rel, x, y = self:GetPoint()
		BS.db.point = { point, rel, x, y }
	end)
	f:Hide()

	if self.db.point then
		f:SetPoint(self.db.point[1], UIParent, self.db.point[2], self.db.point[3], self.db.point[4])
	else
		f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
	end
	tinsert(UISpecialFrames, "BidSniperFrame")

	local title = f:CreateFontString(nil, "ARTWORK")
	Font(title, 13, 1, 0.82, 0)
	title:SetPoint("TOP", 0, -14)
	title:SetText("BidSniper  |cff888888- low bid, high buyout|r")

	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)

	--------------------------------------------------------------- filters --
	-- Labels sit ABOVE their control, in fixed columns. Other addons (ElvUI in
	-- particular) swap the default fonts, so nothing here may depend on how
	-- wide a piece of text happens to render.
	local COL      = { 16, 176, 336, 496 }
	local LABEL_Y  = -38
	local FIELD_Y  = -56
	local LABEL2_Y = -84
	local FIELD2_Y = -102
	local CHECK_Y  = -134

	local lblRatio = MakeLabel(f, "Min ratio", COL[1], LABEL_Y)
	local ratioEdit = MakeEditBox(f, COL[1], FIELD_Y, 60)
	ratioEdit:SetMaxLetters(6)
	ratioEdit.Refresh = function() ratioEdit:SetText(tostring(BS.db.minRatio)) end
	local function commitRatio()
		-- extra parentheses: gsub also returns a count, which tonumber would read as a base
		local v = tonumber((string.gsub(ratioEdit:GetText() or "", "[xX%s]", "")))
		if v and v >= 1 then BS.db.minRatio = v else BS:Print("Min ratio must be a number of at least 1.") end
		ratioEdit.Refresh()
		ratioEdit:ClearFocus()
		BS:UpdateUI()
	end
	ratioEdit:SetScript("OnEnterPressed", commitRatio)
	ratioEdit:SetScript("OnEditFocusLost", commitRatio)
	ratioEdit:SetScript("OnEscapePressed", function() ratioEdit.Refresh() ratioEdit:ClearFocus() end)
	Tip(ratioEdit, "Minimum ratio",
		"How many times bigger the buyout must be than the bid. 10 means a 1g bid with at least a 10g buyout.")

	local lblMaxBid = MakeLabel(f, "Max bid", COL[2], LABEL_Y)
	local maxBidEdit = MakeMoneyEdit(f, COL[2], FIELD_Y, 100,
		function() return BS.db.maxBid end,
		function(v) BS.db.maxBid = v end,
		"Maximum bid", "Hide anything that costs more than this to bid on. 0 = no limit.")

	local lblMinBuy = MakeLabel(f, "Min buyout", COL[3], LABEL_Y)
	local minBuyEdit = MakeMoneyEdit(f, COL[3], FIELD_Y, 100,
		function() return BS.db.minBuyout end,
		function(v) BS.db.minBuyout = v end,
		"Minimum buyout", "Skip cheap junk. An auction must have at least this buyout to show up.")

	local function QualityText(q)
		local color = ITEM_QUALITY_COLORS[q]
		local name  = _G["ITEM_QUALITY" .. q .. "_DESC"] or tostring(q)
		return (color and color.hex or "") .. name .. "|r"
	end

	--[[
		Min profit governs which rows a bulk tick will take, not what a scan
		keeps. Profit depends on Auctionator's prices, which can arrive after
		a scan has already run, so filtering results on it would throw away
		auctions that turn out to be the good ones.
	]]
	local PROFIT_X = 616
	local lblMinProfit = MakeLabel(f, "Min profit", PROFIT_X, LABEL_Y)
	local minProfitEdit = MakeMoneyEdit(f, PROFIT_X, FIELD_Y, 96,
		function() return BS.db.minProfit end,
		function(v) BS.db.minProfit = v end,
		"Minimum profit to tick",
		"Select all, shift-click ranges and dragging across the boxes skip anything "
		.. "worth less than this over its bid. 0 = tick everything.\n\n"
		.. "It compares against the figure in the Profit column, which counts the "
		.. "whole row - a row of eight worth 20g each clears a 100g bar.\n\n"
		.. "Items Auctionator has no price for are skipped too: this is where gold "
		.. "actually gets spent, and an unknown value is not a reason to bid.\n\n"
		.. "It never hides a row, and never stops you ticking one by hand.")

	-- a plain button rather than a dropdown: predictable size, nothing to skin
	local lblQuality = MakeLabel(f, "Min quality", COL[4], LABEL_Y)
	local qualityBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	qualityBtn:SetPoint("TOPLEFT", COL[4], FIELD_Y - 1)
	qualityBtn:SetWidth(110)
	qualityBtn:SetHeight(20)
	qualityBtn.Refresh = function() qualityBtn:SetText(QualityText(BS.db.minQuality)) end
	qualityBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	qualityBtn:SetScript("OnClick", function(self, button)
		local q = BS.db.minQuality + (button == "RightButton" and -1 or 1)
		if q > 5 then q = 0 elseif q < 0 then q = 5 end
		BS.db.minQuality = q
		self.Refresh()
		BS:UpdateUI()
	end)
	Tip(qualityBtn, "Minimum quality",
		"Only show items of at least this quality. Click to step up, right-click to step back.")

	------------------------------------------------- category and wishlist --
	MakeLabel(f, "Category", COL[1], LABEL2_Y)
	local catBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	catBtn:SetPoint("TOPLEFT", COL[1], FIELD2_Y)
	catBtn:SetWidth(260)
	catBtn:SetHeight(22)
	catBtn.Refresh = function() catBtn:SetText(BS:CategorySummary()) end
	catBtn:SetScript("OnClick", function()
		if BS.catFrame:IsShown() then BS.catFrame:Hide() else BS.catFrame:Show() end
	end)
	Tip(catBtn, "Limit the scan to certain categories",
		"Tick as many as you like - each one is scanned in turn, which is far "
		.. "quicker than reading the whole auction house. Tick none to scan "
		.. "everything. GetAll cannot be filtered, so choosing categories always "
		.. "scans page by page.")
	f.catBtn = catBtn

	-- This row is packed to the frame edge, so the widths below are chosen to
	-- add up rather than by eye: 282 + 96 + 124 + 96 + 92 + 100 and the gaps
	-- between them land the last button 36px inside a 842-wide window.
	local wishBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	wishBtn:SetPoint("TOPLEFT", 282, FIELD2_Y)
	wishBtn:SetWidth(96)
	wishBtn:SetHeight(22)
	wishBtn:SetText("Wishlist")
	wishBtn:SetScript("OnClick", function()
		if BS.wishFrame:IsShown() then BS.wishFrame:Hide() else BS.wishFrame:Show() end
	end)
	Tip(wishBtn, "Items you want to watch",
		"Keep a list of items you check often, then scan just those instead of the "
		.. "whole auction house.")
	f.wishBtn = wishBtn

	local wishScanBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	wishScanBtn:SetPoint("TOPLEFT", 382, FIELD2_Y)
	wishScanBtn:SetWidth(124)
	wishScanBtn:SetHeight(22)
	wishScanBtn:SetText("Scan wishlist")
	wishScanBtn:SetScript("OnClick", function() BS:StartScan(false, "wishlist") end)
	Tip(wishScanBtn, "Scan only the wishlist",
		"Searches for each item on your wishlist in turn and applies the same "
		.. "filters. Much quicker than a full scan.")
	f.wishScanBtn = wishScanBtn

	local craftBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	craftBtn:SetPoint("TOPLEFT", 510, FIELD2_Y)
	craftBtn:SetWidth(96)
	craftBtn:SetHeight(22)
	craftBtn:SetText("Craft")
	craftBtn:SetScript("OnClick", function()
		if not BS.craftFrame then return end
		if BS.craftFrame:IsShown() then BS.craftFrame:Hide() else BS.craftFrame:Show() end
	end)
	Tip(craftBtn, "What your flasks and elixirs cost to make",
		"Costs every flask and elixir you can make against the reagent prices from "
		.. "your last scan, and says what it would earn.\n\n"
		.. "The prices come out of a scan you were running anyway - each row is "
		.. "checked against your reagents on its way past, so this costs no extra "
		.. "queries and no extra waiting.\n\n"
		.. "Open your alchemy window once and press Read recipes to fill it in.")
	f.craftBtn = craftBtn

	local rebidBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	rebidBtn:SetPoint("TOPLEFT", 610, FIELD2_Y)
	rebidBtn:SetWidth(92)
	rebidBtn:SetHeight(22)
	rebidBtn:SetText("Re-bid")
	rebidBtn:SetScript("OnClick", function() BS:RebidOutbid() end)
	Tip(rebidBtn, "Re-bid where you were outbid",
		"Asks the server which of your bids have been beaten and queues them all up "
		.. "for the BID button. Needs no scan - it works straight off your bid list. "
		.. "Auctions that have climbed past your Max bid, or past their own buyout, "
		.. "are left alone and reported.")
	f.rebidBtn = rebidBtn

	local myBidsBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	myBidsBtn:SetPoint("TOPLEFT", 706, FIELD2_Y)
	myBidsBtn:SetWidth(100)
	myBidsBtn:SetHeight(22)
	myBidsBtn:SetText("My bids")
	myBidsBtn:SetScript("OnClick", function()
		if not BS.ledgerFrame then BS:NoLedger() return end
		if BS.ledgerFrame:IsShown() then BS.ledgerFrame:Hide() else BS.ledgerFrame:Show() end
	end)
	Tip(myBidsBtn, "Every bid you have placed",
		"Kept through logging out, which the auction house itself does not do: the "
		.. "Bids tab only ever shows auctions you are currently winning, so anything "
		.. "you were outbid on while away vanishes from it without trace. This list "
		.. "remembers, and tells you which ones you won, which you lost, and which "
		.. "are still sitting there waiting to be bid on again.")
	f.myBidsBtn = myBidsBtn

	local scanBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	scanBtn:SetPoint("TOPRIGHT", -18, FIELD_Y - 1)
	scanBtn:SetWidth(104)
	scanBtn:SetHeight(24)
	scanBtn:SetText("Scan AH")
	scanBtn:SetScript("OnClick", function()
		if BS.scanning then BS:StopScan("Scan cancelled.") else BS:StartScan(false) end
	end)
	Tip(scanBtn, "Scan the auction house",
		"Always starts a complete new scan, throwing away any earlier results. "
		.. "Uses GetAll when the realm allows it - the whole house in one request, "
		.. "categories included. Otherwise it pages through cheapest bid first and "
		.. "stops once bids pass your Max bid.")
	f.scanBtn = scanBtn

	-- only offered when there is genuinely something to carry on from
	local resumeBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	resumeBtn:SetPoint("TOPRIGHT", -130, FIELD_Y - 1)
	resumeBtn:SetWidth(96)
	resumeBtn:SetHeight(24)
	resumeBtn:SetText("Resume")
	resumeBtn:SetScript("OnClick", function() BS:StartScan(true) end)
	Tip(resumeBtn, "Carry on where the last scan stopped",
		"Picks up from the page an interrupted scan reached, keeping what it "
		.. "already found. Scan AH beside it always starts over instead.")
	resumeBtn:Hide()
	f.resumeBtn = resumeBtn

	local cbNoBids = MakeCheck(f, "Only unbid", COL[1] - 2, CHECK_Y,
		function() return BS.db.onlyNoBids end,
		function(v) BS.db.onlyNoBids = v end,
		"Only auctions with no bids",
		"Hide auctions someone has already bid on, so the starting bid is the price you pay.")

	local cbSoon = MakeCheck(f, "Ending < 2h", COL[2] - 2, CHECK_Y,
		function() return BS.db.endingSoon end,
		function(v) BS.db.endingSoon = v end,
		"Ending soon",
		"Only show auctions with Short or Medium time left - the ones worth sniping now.")

	local cbOwn = MakeCheck(f, "Hide mine", COL[3] - 2, CHECK_Y,
		function() return BS.db.hideOwn end,
		function(v) BS.db.hideOwn = v end,
		"Hide my auctions",
		"Skip your own auctions and any auction where you are already the top bidder.")

	local cbAuto = MakeCheck(f, "Open with AH", COL[4] - 2, CHECK_Y,
		function() return BS.db.autoShow end,
		function(v) BS.db.autoShow = v end,
		"Open automatically",
		"Show this window whenever you open the auction house.")

	------------------------------------------------------- column headers --
	local headers = {}
	for i, col in ipairs(COLS) do
		local h = CreateFrame("Button", nil, f)
		h:SetPoint("TOPLEFT", 16 + col.x, -168)
		h:SetWidth(col.w)
		h:SetHeight(18)
		local fs = h:CreateFontString(nil, "ARTWORK")
		Font(fs, 11, 1, 0.82, 0)
		fs:SetAllPoints()
		fs:SetJustifyH(col.justify)
		h.label = fs
		h.key   = col.key
		h.col   = col
		h:SetScript("OnClick", function(self) BS:SetSort(self.key) end)
		headers[i] = h
	end
	f.headers = headers

	local line = f:CreateTexture(nil, "ARTWORK")
	line:SetTexture("Interface\\Buttons\\WHITE8X8")
	line:SetVertexColor(0.5, 0.5, 0.5, 0.5)
	line:SetPoint("TOPLEFT", 16, -186)
	line:SetWidth(ROW_WIDTH)
	line:SetHeight(1)

	------------------------------------------------------------ the list --
	local scroll = CreateFrame("ScrollFrame", "BidSniperScrollFrame", f, "FauxScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 16, -190)
	scroll:SetWidth(ROW_WIDTH)
	scroll:SetHeight(NUM_ROWS * ROW_HEIGHT)
	scroll:SetScript("OnVerticalScroll", function(self, offset)
		FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, function() BS:UpdateUI() end)
	end)
	f.scroll = scroll

	f.rows = {}
	for i = 1, NUM_ROWS do
		local row = CreateFrame("Button", nil, f)
		row:SetWidth(ROW_WIDTH)
		row:SetHeight(ROW_HEIGHT)
		if i == 1 then
			row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
		else
			row:SetPoint("TOPLEFT", f.rows[i - 1], "BOTTOMLEFT", 0, 0)
		end
		row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")

		-- a child CheckButton eats its own clicks, so ticking a row does not
		-- also fire the row's bid handler
		row.check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
		row.check:SetWidth(18)
		row.check:SetHeight(18)
		row.check:SetPoint("LEFT", 2, 0)
		-- fire on press, not release, so the press can begin a drag
		row.check:RegisterForClicks("LeftButtonDown")
		row.check:SetScript("OnClick", function(self)
			local r, idx = row.result, row.resultIndex
			if not r or not idx then return end

			local state = self:GetChecked() and true or false

			if IsShiftKeyDown() and BS.lastTickIndex and BS.lastTickIndex ~= idx then
				local n = BS:SelectRange(BS.lastTickIndex, idx, state)
				BS:SetStatus(format("%s %d row%s.", state and "Ticked" or "Unticked",
					n, n == 1 and "" or "s"))
			else
				BS:ApplySelect(r, state)
				BS.lastTickIndex = idx
			end

			-- keep painting the same state onto whatever we drag across
			BS.dragging  = true
			BS.dragState = state
			BS:UpdateUI()
		end)
		row.check:SetScript("OnEnter", function(self)
			if BS.dragging and row.result then
				-- dragging paints rows you have not looked at, so it is bulk
				BS:ApplySelect(row.result, BS.dragState, true)
				BS.lastTickIndex = row.resultIndex or BS.lastTickIndex
				BS:UpdateUI()
			end
		end)

		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetWidth(16)
		row.icon:SetHeight(16)
		row.icon:SetPoint("LEFT", 22, 0)

		row.cells = {}
		for c, col in ipairs(COLS) do
			local fs = row:CreateFontString(nil, "ARTWORK")
			Font(fs, 11, 1, 1, 1)
			fs:SetPoint("LEFT", col.x, 0)
			fs:SetWidth(col.w)
			fs:SetHeight(ROW_HEIGHT)
			fs:SetJustifyH(col.justify)
			row.cells[c] = fs
		end

		row:SetScript("OnClick", function(self, button)
			local r = self.result
			if not r then return end
			if IsShiftKeyDown() and r.link then
				HandleModifiedItemClick(r.link)
			elseif button == "RightButton" then
				BS:SearchInBrowse(r)
			else
				-- ctrl-click bids straight away, no confirmation box
				BS:BidOn(r, IsControlKeyDown())
			end
		end)
		row:SetScript("OnEnter", function(self)
			local r = self.result
			if not r then return end
			BS:FillValue(r)		-- the breakdown below needs the per-auction figures
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			if r.link then
				GameTooltip:SetHyperlink(r.link)
			else
				GameTooltip:AddLine(r.name, 1, 1, 1)
			end
			GameTooltip:AddLine(" ")
			GameTooltip:AddDoubleLine("Bid", BS.Money(r.bid), 1, 1, 1)
			GameTooltip:AddDoubleLine("Buyout", BS.Money(r.buyout), 1, 1, 1)
			if r.count > 1 then
				GameTooltip:AddDoubleLine("Bid per item", BS.Money(r.bid / r.count), 0.8, 0.8, 0.8)
			end
			local left = BS:CopiesLeft(r)
			if (r.copies or 1) > 1 or r.counted then
				GameTooltip:AddDoubleLine(r.counted and "Up right now" or "Identical auctions up",
					format("%d  (%s the lot)", left, BS.Money(r.bid * left)), 1, 0.82, 0)
			end
			if r.profit then
				-- the columns carry the whole row; here is the arithmetic behind
				-- them, one auction at a time when there is more than one
				if left > 1 then
					GameTooltip:AddDoubleLine("Market value, each",
						BS.Money(r.unitMarket or 0), 0.8, 0.8, 0.8)
					GameTooltip:AddDoubleLine("Profit over bid, each",
						BS.Money(r.unitProfit or 0), 0.6, 0.9, 0.6)
					GameTooltip:AddDoubleLine(format("All %d together", left),
						BS.Money(r.profit), 0.2, 1, 0.2)
				else
					GameTooltip:AddDoubleLine("Market value", BS.Money(r.market), 0.8, 0.8, 0.8)
					GameTooltip:AddDoubleLine("Profit over bid", BS.Money(r.profit), 0.2, 1, 0.2)
				end
				GameTooltip:AddDoubleLine("After 5% AH cut",
					BS.Money(r.market * 0.95 - r.bid * left), 0.6, 0.6, 0.6)
			else
				GameTooltip:AddLine("Auctionator has no price for this item -", 1, 0.5, 0.2)
				GameTooltip:AddLine("the buyout alone proves nothing.", 1, 0.5, 0.2)
			end
			GameTooltip:AddLine(" ")
			if BS.Expired(r) then
				GameTooltip:AddLine("This auction has run out since the scan -", 0.6, 0.6, 0.6)
				GameTooltip:AddLine("it sold, was bought, or was cancelled.", 0.6, 0.6, 0.6)
			elseif BS.Doubtful(r) then
				GameTooltip:AddLine("Scanned a while ago - may already be gone.", 1, 0.5, 0.2)
			end
			if r.bidPlaced then
				if (r.copies or 1) > 1 then
					GameTooltip:AddLine(format("You have bid on %d of these %d.",
						r.bidsDone or 0, r.copies), 0.2, 1, 0.2)
				else
					GameTooltip:AddLine("You have already bid on this one.", 0.2, 1, 0.2)
				end
			end
			if (r.copies or 1) > 1 then
				GameTooltip:AddLine("Ticking this row bids on every copy still up;", 0.6, 0.9, 1)
				GameTooltip:AddLine("clicking it bids on one of them.", 0.6, 0.9, 1)
			end
			GameTooltip:AddLine("Tick box: drag to paint, shift-tick for a range", 0.6, 0.9, 1)
			GameTooltip:AddLine("Click: bid " .. BS.Money(r.bid) .. " (asks to confirm)", 0.6, 0.9, 1)
			GameTooltip:AddLine("Ctrl-click: load it onto the BID button", 1, 0.6, 0.3)
			GameTooltip:AddLine("Right-click: search this item in Browse", 0.6, 0.9, 1)
			GameTooltip:AddLine("Shift-click: link in chat", 0.6, 0.9, 1)
			GameTooltip:Show()
		end)
		row:SetScript("OnLeave", function() GameTooltip:Hide() end)
		row:Hide()

		f.rows[i] = row
	end

	------------------------------------------------------------- status --
	local hint = f:CreateFontString(nil, "ARTWORK")
	Font(hint, 10, 0.5, 0.5, 0.5)
	hint:SetPoint("BOTTOMLEFT", 18, 46)
	hint:SetText("drag the boxes, or shift-tick for a range    click a row = bid")

	local status = f:CreateFontString(nil, "ARTWORK")
	Font(status, 11, 1, 1, 1)
	status:SetPoint("BOTTOMLEFT", 18, 20)
	status:SetJustifyH("LEFT")
	status:SetWidth(420)
	f.status = status

	local selCount = f:CreateFontString(nil, "ARTWORK")
	Font(selCount, 11, 1, 0.82, 0)
	selCount:SetPoint("BOTTOMRIGHT", -18, 46)
	selCount:SetJustifyH("RIGHT")
	f.selCount = selCount

	local selectBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	selectBtn:SetPoint("BOTTOMRIGHT", -224, 16)
	selectBtn:SetWidth(110)
	selectBtn:SetHeight(24)
	selectBtn:SetText("Select all")
	selectBtn:SetScript("OnClick", function()
		if BS.batch then BS:EndBatch("Batch stopped.") else BS:ToggleSelectAll() end
	end)
	Tip(selectBtn, "Select all / none",
		"Ticks every row at once. Press again to clear them all. Untick the few you "
		.. "do not want, then press Bid selected. While a batch is running this "
		.. "button stops it.")
	f.selectBtn = selectBtn

	local skipBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	skipBtn:SetPoint("BOTTOMRIGHT", -152, 16)
	skipBtn:SetWidth(66)
	skipBtn:SetHeight(24)
	skipBtn:SetText("Skip")
	skipBtn:SetScript("OnClick", function() BS:SkipArmed() end)
	Tip(skipBtn, "Skip this one",
		"Passes on the auction currently on the BID button and lines up the next. "
		.. "Also cancels a lookup that is taking too long, so one awkward item cannot "
		.. "hold up the rest of the queue.")
	skipBtn:Hide()
	f.skipBtn = skipBtn

	-- The bid itself happens in this OnClick and nowhere else. PlaceAuctionBid
	-- is protected and the client only honours it while handling a real click,
	-- so this button cannot be pressed on your behalf.
	local batchBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	batchBtn:SetPoint("BOTTOMRIGHT", -18, 16)
	batchBtn:SetWidth(128)
	batchBtn:SetHeight(24)
	batchBtn:SetText("Bid selected")
	batchBtn:SetScript("OnClick", function()
		if BS.armed then
			BS:FireArmedBid()
		elseif not BS.batch then
			BS:StartBatchBid()
		end
	end)
	Tip(batchBtn, "Bid on the ticked rows",
		"WoW only lets an addon place a bid while you are actually clicking, so this "
		.. "is one click per auction. Each press bids the auction shown on the button "
		.. "and lines up the next one, so you keep clicking the same spot. It skips "
		.. "anything whose price has risen and stops when the gold runs out.")
	f.batchBtn = batchBtn

	self:BuildWishlistUI(f)
	self:BuildCategoryUI(f)
	self:BuildLedgerUI(f)
	self:BuildCraftUI(f)

	f.refreshers = { ratioEdit, maxBidEdit, minBuyEdit, minProfitEdit, qualityBtn,
	                 catBtn, cbNoBids, cbSoon, cbOwn, cbAuto }

	-- /snipe debug prints where these actually ended up on screen
	f.debug = {
		{ "lbl ratio",   lblRatio   }, { "box ratio",   ratioEdit  },
		{ "lbl maxbid",  lblMaxBid  }, { "box maxbid",  maxBidEdit },
		{ "lbl minbuy",  lblMinBuy  }, { "box minbuy",  minBuyEdit },
		{ "lbl profit",  lblMinProfit }, { "box profit", minProfitEdit },
		{ "lbl quality", lblQuality }, { "btn quality", qualityBtn },
		{ "btn scan",    scanBtn    },
	}

	f:SetScript("OnShow", function() BS:RefreshControls() BS:UpdateUI() end)

	self.frame = f
	self:RefreshControls()
	self:SetStatus("Open the auction house and press Scan AH.")
end

--=============================================================================
--  category panel
--=============================================================================

local CAT_ROWS, CAT_ROW_H = 15, 22

function BS:BuildCategoryUI(parent)
	local c = CreateFrame("Frame", "BidSniperCategoryFrame", parent)
	c:SetWidth(320)
	c:SetHeight(140 + CAT_ROWS * CAT_ROW_H)
	c:SetPoint("TOPLEFT", parent, "TOPRIGHT", 4, 0)
	c:SetFrameStrata("HIGH")
	c:SetToplevel(true)
	c:SetBackdrop({
		bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	c:EnableMouse(true)
	c:Hide()

	-- only one side panel at a time, they share the same spot
	c:SetScript("OnShow", function()
		if BS.wishFrame   then BS.wishFrame:Hide()   end
		if BS.ledgerFrame then BS.ledgerFrame:Hide() end
		if BS.craftFrame  then BS.craftFrame:Hide()  end
		BS:RefreshCategories()
	end)

	local title = c:CreateFontString(nil, "ARTWORK")
	Font(title, 12, 1, 0.82, 0)
	title:SetPoint("TOP", 0, -14)
	title:SetText("Categories")

	local close = CreateFrame("Button", nil, c, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)

	local help = c:CreateFontString(nil, "ARTWORK")
	Font(help, 10, 0.6, 0.6, 0.6)
	help:SetPoint("TOPLEFT", 18, -38)
	help:SetWidth(300)
	help:SetJustifyH("LEFT")
	help:SetText("Tick a category, or open it with [+] and tick individual "
		.. "subcategories. Nothing ticked scans everything.")
	help:SetHeight(26)

	local scroll = CreateFrame("ScrollFrame", "BidSniperCatScroll", c, "FauxScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 18, -74)
	scroll:SetWidth(258)
	scroll:SetHeight(CAT_ROWS * CAT_ROW_H)
	scroll:SetScript("OnVerticalScroll", function(self, offset)
		FauxScrollFrame_OnVerticalScroll(self, offset, CAT_ROW_H,
			function() BS:RefreshCategories() end)
	end)
	c.scroll = scroll

	c.rows = {}
	for i = 1, CAT_ROWS do
		local row = CreateFrame("Frame", nil, c)
		row:SetWidth(258)
		row:SetHeight(CAT_ROW_H)
		if i == 1 then
			row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
		else
			row:SetPoint("TOPLEFT", c.rows[i - 1], "BOTTOMLEFT", 0, 0)
		end

		-- [+] / [-] for classes that have subcategories
		local expand = CreateFrame("Button", nil, row)
		expand:SetWidth(16)
		expand:SetHeight(16)
		expand:SetPoint("LEFT", 0, 0)
		local etext = expand:CreateFontString(nil, "ARTWORK")
		Font(etext, 12, 1, 0.82, 0)
		etext:SetAllPoints()
		expand.label = etext
		expand:SetScript("OnClick", function(self)
			if not self.class then return end
			BS.db.catExpanded[self.class] = (not BS.db.catExpanded[self.class]) or nil
			BS:RefreshCategories()
		end)
		row.expand = expand

		local cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
		cb:SetWidth(20)
		cb:SetHeight(20)
		row.check = cb

		local text = row:CreateFontString(nil, "ARTWORK")
		Font(text, 11, 1, 1, 1)
		text:SetJustifyH("LEFT")
		row.text = text

		cb:SetScript("OnClick", function(self)
			local entry = row.entry
			if not entry then return end
			local on = self:GetChecked() and true or false

			if entry.sub then
				local set = BS.db.subcats[entry.class]
				if not set then set = {} BS.db.subcats[entry.class] = set end
				set[entry.sub] = on or nil
				-- picking subcategories means "only these", not the whole class
				if on then BS.db.categories[entry.class] = nil end
			else
				BS.db.categories[entry.class] = on or nil
				-- a whole class supersedes any subcategory picks under it
				if on then BS.db.subcats[entry.class] = nil end
			end

			BS:RefreshCategories()
			BS:RefreshControls()
			BS:UpdateUI()
		end)

		row:Hide()
		c.rows[i] = row
	end

	local allBtn = CreateFrame("Button", nil, c, "UIPanelButtonTemplate")
	allBtn:SetPoint("BOTTOMLEFT", 18, 18)
	allBtn:SetWidth(84)
	allBtn:SetHeight(22)
	allBtn:SetText("Tick all")
	allBtn:SetScript("OnClick", function()
		local names = BS:CategoryNames()
		if not names then return end
		for i = 1, #names do BS.db.categories[i] = true end
		BS.db.subcats = {}
		BS:RefreshCategories()
		BS:RefreshControls()
		BS:UpdateUI()
	end)

	local noneBtn = CreateFrame("Button", nil, c, "UIPanelButtonTemplate")
	noneBtn:SetPoint("BOTTOMLEFT", 108, 18)
	noneBtn:SetWidth(84)
	noneBtn:SetHeight(22)
	noneBtn:SetText("Clear")
	noneBtn:SetScript("OnClick", function()
		BS.db.categories = {}
		BS.db.subcats    = {}
		BS:RefreshCategories()
		BS:RefreshControls()
		BS:UpdateUI()
	end)

	local count = c:CreateFontString(nil, "ARTWORK")
	Font(count, 11, 0.7, 0.7, 0.7)
	count:SetPoint("BOTTOMRIGHT", -18, 24)
	c.count = count

	self.catFrame = c
end

-- classes, with the subclasses of any opened class folded in beneath them
function BS:CategoryTree()
	local tree  = {}
	local names = self:CategoryNames()
	if not names then return tree end

	for i, name in ipairs(names) do
		local subs = self:SubCategoryNames(i)
		tree[#tree + 1] = { class = i, name = name, hasSubs = subs ~= nil }
		if subs and self.db.catExpanded[i] then
			for j, subName in ipairs(subs) do
				tree[#tree + 1] = { class = i, sub = j, name = subName }
			end
		end
	end
	return tree
end

function BS:RefreshCategories()
	local c = self.catFrame
	if not c then return end

	local tree   = self:CategoryTree()
	local offset = FauxScrollFrame_GetOffset(c.scroll) or 0

	for i = 1, CAT_ROWS do
		local row   = c.rows[i]
		local entry = tree[offset + i]

		if entry then
			row.entry = entry
			local indent = entry.sub and 18 or 0

			if entry.sub then
				row.expand:Hide()
				row.check:SetChecked(self.db.subcats[entry.class]
					and self.db.subcats[entry.class][entry.sub] and true or false)
				row.text:SetTextColor(0.85, 0.85, 0.85)
			else
				row.expand.class = entry.hasSubs and entry.class or nil
				row.expand.label:SetText(entry.hasSubs
					and (self.db.catExpanded[entry.class] and "-" or "+") or "")
				if entry.hasSubs then row.expand:Show() else row.expand:Hide() end
				row.check:SetChecked(self.db.categories[entry.class] and true or false)
				row.text:SetTextColor(1, 1, 1)
			end

			row.check:SetPoint("LEFT", 16 + indent, 0)
			row.text:SetPoint("LEFT", 38 + indent, 0)
			row.text:SetWidth(216 - indent)

			-- a class with subcategories picked reads as partly chosen
			local label = entry.name
			if not entry.sub then
				local picked = #self:SelectedSubCategories(entry.class)
				if picked > 0 then
					label = label .. format(" |cffffd100(%d)|r", picked)
				end
			end
			row.text:SetText(label)
			row:Show()
		else
			row.entry = nil
			row:Hide()
		end
	end

	local names = self:CategoryNames()
	if not names then
		c.count:SetText("|cffff8800open the auction house first|r")
	else
		local classes = self:ActiveClasses()
		c.count:SetText(#classes == 0 and "scanning everything"
			or format("%d of %d categories", #classes, #names))
	end

	FauxScrollFrame_Update(c.scroll, #tree, CAT_ROWS, CAT_ROW_H)
end

--=============================================================================
--  wishlist panel
--=============================================================================

local WISH_ROWS = 10

function BS:BuildWishlistUI(parent)
	local w = CreateFrame("Frame", "BidSniperWishlistFrame", parent)
	w:SetWidth(300)
	w:SetHeight(360)
	w:SetPoint("TOPLEFT", parent, "TOPRIGHT", 4, 0)
	w:SetFrameStrata("HIGH")
	w:SetToplevel(true)
	w:SetBackdrop({
		bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	w:EnableMouse(true)
	w:Hide()
	w:SetScript("OnShow", function()
		if BS.catFrame    then BS.catFrame:Hide()    end
		if BS.ledgerFrame then BS.ledgerFrame:Hide() end
		if BS.craftFrame  then BS.craftFrame:Hide()  end
		BS:RefreshWishlist()
	end)

	local title = w:CreateFontString(nil, "ARTWORK")
	Font(title, 12, 1, 0.82, 0)
	title:SetPoint("TOP", 0, -14)
	title:SetText("Wishlist")

	local close = CreateFrame("Button", nil, w, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)

	local help = w:CreateFontString(nil, "ARTWORK")
	Font(help, 10, 0.6, 0.6, 0.6)
	help:SetPoint("TOPLEFT", 18, -38)
	help:SetWidth(264)
	help:SetJustifyH("LEFT")
	help:SetText("Type a name or shift-click an item into the box.")

	local entry = MakeEditBox(w, 18, -58, 200)
	entry:SetMaxLetters(64)
	local function commitEntry()
		if BS:WishlistAdd(entry:GetText()) then entry:SetText("") end
		entry:ClearFocus()
	end
	entry:SetScript("OnEnterPressed", commitEntry)
	entry:SetScript("OnEscapePressed", function(self) self:SetText("") self:ClearFocus() end)
	w.entry = entry

	local addBtn = CreateFrame("Button", nil, w, "UIPanelButtonTemplate")
	addBtn:SetPoint("TOPLEFT", 224, -59)
	addBtn:SetWidth(58)
	addBtn:SetHeight(22)
	addBtn:SetText("Add")
	addBtn:SetScript("OnClick", commitEntry)

	local scroll = CreateFrame("ScrollFrame", "BidSniperWishScroll", w, "FauxScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 18, -90)
	scroll:SetWidth(240)
	scroll:SetHeight(WISH_ROWS * 20)
	scroll:SetScript("OnVerticalScroll", function(self, offset)
		FauxScrollFrame_OnVerticalScroll(self, offset, 20, function() BS:RefreshWishlist() end)
	end)
	w.scroll = scroll

	w.rows = {}
	for i = 1, WISH_ROWS do
		local row = CreateFrame("Frame", nil, w)
		row:SetWidth(240)
		row:SetHeight(20)
		if i == 1 then
			row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
		else
			row:SetPoint("TOPLEFT", w.rows[i - 1], "BOTTOMLEFT", 0, 0)
		end

		local text = row:CreateFontString(nil, "ARTWORK")
		Font(text, 11, 1, 1, 1)
		text:SetPoint("LEFT", 2, 0)
		text:SetWidth(206)
		text:SetJustifyH("LEFT")
		row.text = text

		local del = CreateFrame("Button", nil, row, "UIPanelCloseButton")
		del:SetWidth(22)
		del:SetHeight(22)
		del:SetPoint("RIGHT", 0, 0)
		del:SetScript("OnClick", function() BS:WishlistRemove(row.index) end)
		row.del = del

		row:Hide()
		w.rows[i] = row
	end

	local scanBtn = CreateFrame("Button", nil, w, "UIPanelButtonTemplate")
	scanBtn:SetPoint("BOTTOMLEFT", 18, 18)
	scanBtn:SetWidth(140)
	scanBtn:SetHeight(24)
	scanBtn:SetText("Scan wishlist")
	scanBtn:SetScript("OnClick", function() BS:StartScan(false, "wishlist") end)

	local count = w:CreateFontString(nil, "ARTWORK")
	Font(count, 11, 0.7, 0.7, 0.7)
	count:SetPoint("BOTTOMRIGHT", -18, 24)
	w.count = count

	self.wishFrame = w
	self:RefreshWishlist()
end

function BS:RefreshWishlist()
	local w = self.wishFrame
	if not w then return end

	local list   = self.db.wishlist
	local offset = FauxScrollFrame_GetOffset(w.scroll) or 0

	for i = 1, WISH_ROWS do
		local row  = w.rows[i]
		local idx  = offset + i
		local name = list[idx]
		if name then
			row.index = idx
			row.text:SetText(name)
			row:Show()
		else
			row.index = nil
			row:Hide()
		end
	end

	w.count:SetText(format("%d item%s", #list, #list == 1 and "" or "s"))
	FauxScrollFrame_Update(w.scroll, #list, WISH_ROWS, 20)
end

--=============================================================================
--  bid ledger panel
--=============================================================================

local LEDGER_ROWS, LEDGER_ROW_H = 12, 22

-- outbid first: it is the only state you can still do something about
local STATE_ORDER = {
	outbid = 1, missing = 2, pending = 3, leading = 4, won = 5, lost = 6, ended = 7,
}

function BS:BuildLedgerUI(parent)
	-- no ledger loaded, no panel: the My bids button explains why instead
	if not self:HasLedger() then return end

	local g = CreateFrame("Frame", "BidSniperLedgerFrame", parent)
	g:SetWidth(460)
	g:SetHeight(400)
	g:SetPoint("TOPLEFT", parent, "TOPRIGHT", 4, 0)
	g:SetFrameStrata("HIGH")
	g:SetToplevel(true)
	g:SetBackdrop({
		bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	g:EnableMouse(true)
	g:Hide()
	g:SetScript("OnShow", function()
		if BS.catFrame  then BS.catFrame:Hide()  end
		if BS.wishFrame then BS.wishFrame:Hide() end
		if BS.craftFrame then BS.craftFrame:Hide() end
		BS:RefreshLedger()
	end)

	local title = g:CreateFontString(nil, "ARTWORK")
	Font(title, 12, 1, 0.82, 0)
	title:SetPoint("TOP", 0, -14)
	title:SetText("My bids")

	local close = CreateFrame("Button", nil, g, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)

	local help = g:CreateFontString(nil, "ARTWORK")
	Font(help, 10, 0.6, 0.6, 0.6)
	help:SetPoint("TOPLEFT", 18, -36)
	help:SetWidth(420)
	help:SetJustifyH("LEFT")
	help:SetText("Every bid you place is kept here through logging out. "
		.. "Click a row to look the auction up in Browse.")

	-- column headers
	local heads = { { "", 2, 56 }, { "Item", 60, 170 }, { "You bid", 232, 84 },
	                { "Costs now", 320, 84 }, { "", 408, 20 } }
	for _, h in ipairs(heads) do
		if h[1] ~= "" then
			local fs = g:CreateFontString(nil, "ARTWORK")
			Font(fs, 10, 0.8, 0.8, 0.8)
			fs:SetPoint("TOPLEFT", 18 + h[2], -66)
			fs:SetWidth(h[3])
			fs:SetJustifyH(h[2] >= 232 and "RIGHT" or "LEFT")
			fs:SetText(h[1])
		end
	end

	local scroll = CreateFrame("ScrollFrame", "BidSniperLedgerScroll", g, "FauxScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 18, -80)
	scroll:SetWidth(404)
	scroll:SetHeight(LEDGER_ROWS * LEDGER_ROW_H)
	scroll:SetScript("OnVerticalScroll", function(self, offset)
		FauxScrollFrame_OnVerticalScroll(self, offset, LEDGER_ROW_H, function() BS:RefreshLedger() end)
	end)
	g.scroll = scroll

	g.rows = {}
	for i = 1, LEDGER_ROWS do
		local row = CreateFrame("Button", nil, g)
		row:SetWidth(404)
		row:SetHeight(LEDGER_ROW_H)
		if i == 1 then
			row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
		else
			row:SetPoint("TOPLEFT", g.rows[i - 1], "BOTTOMLEFT", 0, 0)
		end

		row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")

		row.cells = {}
		local layout = { { 2, 56, "LEFT" }, { 60, 170, "LEFT" },
		                 { 232, 84, "RIGHT" }, { 320, 84, "RIGHT" } }
		for c, l in ipairs(layout) do
			local fs = row:CreateFontString(nil, "ARTWORK")
			Font(fs, 11, 1, 1, 1)
			fs:SetPoint("LEFT", l[1], 0)
			fs:SetWidth(l[2])
			fs:SetJustifyH(l[3])
			row.cells[c] = fs
		end

		row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		row:SetScript("OnClick", function(self, button)
			if not self.entry then return end
			if button == "RightButton" then
				BS:LedgerForget(self.entry)
			else
				BS:SearchInBrowse(self.entry)
			end
		end)
		row:SetScript("OnEnter", function(self)
			if not self.entry then return end
			local e = self.entry
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(e.link or e.name, 1, 1, 1)
			GameTooltip:AddLine(e.note or "", 0.8, 0.8, 0.8, true)
			GameTooltip:AddLine(" ")
			GameTooltip:AddDoubleLine("Seller", e.owner or "unknown", 0.7, 0.7, 0.7, 1, 1, 1)
			GameTooltip:AddDoubleLine("Starting bid", BS.Money(e.minBid), 0.7, 0.7, 0.7, 1, 1, 1)
			GameTooltip:AddDoubleLine("Buyout", BS.Money(e.buyout), 0.7, 0.7, 0.7, 1, 1, 1)
			GameTooltip:AddDoubleLine("You bid", BS.Money(e.myBid), 0.7, 0.7, 0.7, 1, 1, 1)
			if (e.copies or 1) > 1 then
				-- identical auctions share a key, so they share an entry; what
				-- left your bags is that bid times this many
				GameTooltip:AddDoubleLine("Identical auctions bid on",
					format("%d  (%s in all)", e.copies, BS.Money(e.myBid * e.copies)),
					0.7, 0.7, 0.7, 1, 0.82, 0)
			end
			if e.placed then
				GameTooltip:AddDoubleLine("Bid placed", BS.Ago(e.placed), 0.7, 0.7, 0.7, 1, 1, 1)
			end
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("Click to search for it in Browse.", 0.5, 0.8, 1)
			GameTooltip:AddLine("Right-click to remove it from this list.", 0.5, 0.8, 1)
			GameTooltip:Show()
		end)
		row:SetScript("OnLeave", function() GameTooltip:Hide() end)

		row:Hide()
		g.rows[i] = row
	end

	local checkBtn = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
	checkBtn:SetPoint("BOTTOMLEFT", 18, 18)
	checkBtn:SetWidth(110)
	checkBtn:SetHeight(24)
	checkBtn:SetText("Check now")
	checkBtn:SetScript("OnClick", function() BS:CheckBids(false) end)
	Tip(checkBtn, "The fast check",
		"Reads your Bids tab and your mail, and asks the auction house for nothing at "
		.. "all - so it answers immediately. Your mail is the useful part: being "
		.. "outbid puts your gold straight back in the post, and that mail sits there "
		.. "for thirty days whether you log out or not.")

	local findBtn = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
	findBtn:SetPoint("BOTTOMLEFT", 134, 18)
	findBtn:SetWidth(110)
	findBtn:SetHeight(24)
	findBtn:SetText("Find on AH")
	findBtn:SetScript("OnClick", function() BS:StartLedgerSweep(false) end)
	Tip(findBtn, "The slow check",
		"Searches the auction house for each bid still unaccounted for, one item name "
		.. "at a time. It is the only way to be certain, and it is slow - a full scan "
		.. "settles the same bids for nothing on its way past, so try Scan AH first.")

	local clearBtn = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
	clearBtn:SetPoint("BOTTOMLEFT", 250, 18)
	clearBtn:SetWidth(110)
	clearBtn:SetHeight(24)
	clearBtn:SetText("Clear settled")
	clearBtn:SetScript("OnClick", function() BS:ClearSettledBids() end)
	Tip(clearBtn, "Tidy up", "Removes everything that has been won, lost or ended. "
		.. "Settled bids are cleared on their own after a fortnight anyway.")

	local count = g:CreateFontString(nil, "ARTWORK")
	Font(count, 11, 0.7, 0.7, 0.7)
	count:SetPoint("BOTTOMRIGHT", -18, 24)
	g.count = count

	self.ledgerFrame = g
end

function BS:ShowLedger()
	if not self.frame then return end
	self.frame:Show()
	local g = self.ledgerFrame
	if not g then return end
	if g:IsShown() then g:Hide() else g:Show() end
end

--=============================================================================
--  what your flasks and elixirs cost to make
--=============================================================================

local CRAFT_ROWS  = 11
local CRAFT_ROW_H = 22
local DETAIL_ROWS = 7
local DETAIL_ROW_H = 15

--[[
	The panel answers two questions that want different shapes.

	"Which of these is worth making?" is a sorted list, and it is the top half.

	"So what do I actually have to buy?" is a breakdown, and it is the bottom
	half - either the reagents of whichever recipe you clicked, or, once you
	have typed quantities against a few of them, the whole shopping list with
	your bags already deducted.
]]
function BS:BuildCraftUI(parent)
	local g = CreateFrame("Frame", "BidSniperCraftFrame", parent)
	g:SetWidth(540)
	g:SetHeight(560)
	g:SetPoint("TOPLEFT", parent, "TOPRIGHT", 4, 0)
	g:SetFrameStrata("HIGH")
	g:SetToplevel(true)
	g:SetBackdrop({
		bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	g:EnableMouse(true)
	g:Hide()
	g:SetScript("OnShow", function()
		if BS.catFrame    then BS.catFrame:Hide()    end
		if BS.wishFrame   then BS.wishFrame:Hide()   end
		if BS.ledgerFrame then BS.ledgerFrame:Hide() end
		-- opening it is a request for the current answer, and both Auctionator's
		-- database and your bags may have moved since it was last up
		BS.craftCosted = nil
		BS:RefreshCraft()
	end)

	local title = g:CreateFontString(nil, "ARTWORK")
	Font(title, 12, 1, 0.82, 0)
	title:SetPoint("TOP", 0, -14)
	title:SetText("Flasks and elixirs")

	local close = CreateFrame("Button", nil, g, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)

	local help = g:CreateFontString(nil, "ARTWORK")
	Font(help, 10, 0.6, 0.6, 0.6)
	help:SetPoint("TOPLEFT", 18, -36)
	help:SetWidth(500)
	help:SetJustifyH("LEFT")
	help:SetText("Priced from the last scan, at no extra cost. Orange means an estimate. "
		.. "Click a row for its reagents; type how many you want to make and the "
		.. "shopping list works out the rest.")

	local heads = { { "Recipe", 2, 150, "LEFT" }, { "Can make", 156, 56, "RIGHT" },
	                { "Want", 218, 40, "CENTER" }, { "Reagents", 264, 78, "RIGHT" },
	                { "Profit", 346, 86, "RIGHT" } }
	for _, h in ipairs(heads) do
		local fs = g:CreateFontString(nil, "ARTWORK")
		Font(fs, 10, 0.8, 0.8, 0.8)
		fs:SetPoint("TOPLEFT", 18 + h[2], -78)
		fs:SetWidth(h[3])
		fs:SetJustifyH(h[4])
		fs:SetText(h[1])
	end

	local scroll = CreateFrame("ScrollFrame", "BidSniperCraftScroll", g, "FauxScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 18, -92)
	scroll:SetWidth(462)
	scroll:SetHeight(CRAFT_ROWS * CRAFT_ROW_H)
	scroll:SetScript("OnVerticalScroll", function(self, offset)
		FauxScrollFrame_OnVerticalScroll(self, offset, CRAFT_ROW_H, function() BS:RefreshCraft() end)
	end)
	g.scroll = scroll

	g.rows = {}
	for i = 1, CRAFT_ROWS do
		local row = CreateFrame("Button", nil, g)
		row:SetWidth(440)
		row:SetHeight(CRAFT_ROW_H)
		if i == 1 then
			row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
		else
			row:SetPoint("TOPLEFT", g.rows[i - 1], "BOTTOMLEFT", 0, 0)
		end
		row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")

		row.cells = {}
		local layout = { { 2, 150, "LEFT" }, { 156, 56, "RIGHT" },
		                 { 264, 78, "RIGHT" }, { 346, 86, "RIGHT" } }
		for c, l in ipairs(layout) do
			local fs = row:CreateFontString(nil, "ARTWORK")
			Font(fs, 11, 1, 1, 1)
			fs:SetPoint("LEFT", l[1], 0)
			fs:SetWidth(l[2])
			fs:SetJustifyH(l[3])
			row.cells[c] = fs
		end

		--[[
			How many to make, typed straight onto the row.

			These boxes are reused as the list scrolls, so the recipe a box
			belongs to changes underneath it. That is the whole difficulty, and
			it is why a box carries `owner` - the name of the recipe it is
			currently standing for - and why every write goes to that name and
			never to whatever happens to be in the row slot at the time.

			It also commits on each keystroke rather than waiting for Enter or
			for focus to move. Anything held back is something a scroll can
			carry onto the wrong recipe: clear a number, scroll, and the pending
			edit lands on whichever item scrolled into that slot. Committing as
			you type means there is never anything pending to misplace.
		]]
		local want = CreateFrame("EditBox", nil, row)
		want:SetPoint("LEFT", 218, 0)
		want:SetWidth(40)
		want:SetHeight(18)
		want:SetAutoFocus(false)
		want:SetNumeric(true)
		want:SetMaxLetters(4)
		want:SetJustifyH("CENTER")
		want:SetTextInsets(2, 2, 0, 0)
		want:SetBackdrop({
			bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 10,
			insets = { left = 2, right = 2, top = 2, bottom = 2 },
		})
		want:SetBackdropColor(0, 0, 0, 0.65)
		want:SetBackdropBorderColor(0.45, 0.45, 0.45, 1)
		Font(want, 11, 1, 1, 1)

		-- `painting` marks the addon writing into the box, so putting the saved
		-- number back does not read as the user typing it
		local function commit(self)
			if self.painting or not self.owner then return end
			BS:SetWant(self.owner, self:GetText())
		end
		want:SetScript("OnTextChanged", commit)
		want:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
		want:SetScript("OnEditFocusLost", commit)
		want:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
		row.want = want

		row:SetScript("OnClick", function(self)
			if not self.costed then return end
			-- clicking the row you are already looking at puts the shopping
			-- list back, so one control does both directions
			if BS.craftPick == self.costed.name and BS.craftView == "recipe" then
				BS.craftView = "shopping"
			else
				BS.craftPick = self.costed.name
				BS.craftView = "recipe"
			end
			BS:RefreshCraft()
		end)

		row:SetScript("OnEnter", function(self)
			local c = self.costed
			if not c then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			if c.link then GameTooltip:SetHyperlink(c.link)
			else GameTooltip:SetText(c.name, 1, 1, 1) end

			GameTooltip:AddLine(" ")
			for _, line in ipairs(c.lines) do
				local left = format("%dx %s", line.need, line.name)
				if line.vendor then
					GameTooltip:AddDoubleLine(left, "vendor, not costed",
						0.9, 0.9, 0.9, 0.6, 0.8, 1)
				elseif not line.unit then
					GameTooltip:AddDoubleLine(left, "none for sale", 0.9, 0.9, 0.9, 1, 0.3, 0.3)
				elseif line.src == "scan" then
					GameTooltip:AddDoubleLine(left, BS.Money(line.total),
						0.9, 0.9, 0.9, 1, 1, 1)
				else
					GameTooltip:AddDoubleLine(left,
						BS.Money(line.total) .. (line.src == "auctionator" and " (Atr)" or " (old)"),
						0.9, 0.9, 0.9, 1, 0.6, 0.2)
				end
			end

			GameTooltip:AddLine(" ")
			GameTooltip:AddDoubleLine("Costs to make", BS.Money(c.cost), 1, 1, 1)
			if c.yield > 1 then
				GameTooltip:AddDoubleLine("Makes", format("%g", c.yield), 0.8, 0.8, 0.8)
			end
			if c.sellUnit then
				GameTooltip:AddDoubleLine("Sells for", BS.Money(c.revenue), 1, 1, 1)
			end
			if c.profit then
				GameTooltip:AddDoubleLine("Profit", BS.Money(c.profit),
					1, 1, 1, c.profit >= 0 and 0.2 or 1, c.profit >= 0 and 1 or 0.3, 0.2)
				GameTooltip:AddDoubleLine("After 5% AH cut", BS.Money(c.afterCut), 0.6, 0.6, 0.6)
			end
			GameTooltip:AddDoubleLine("From what is in your bags",
				format("%d", c.canMake or 0), 0.8, 0.8, 0.8, 1, 0.82, 0)

			if not c.exact then
				GameTooltip:AddLine(" ")
				GameTooltip:AddLine("This is an estimate:", 1, 0.6, 0.2)
				for _, why in ipairs(c.doubts) do
					GameTooltip:AddLine("  " .. why, 1, 0.6, 0.2, true)
				end
			end

			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("Click for its reagents and what you hold.", 0.5, 0.8, 1)
			GameTooltip:Show()
		end)
		row:SetScript("OnLeave", function() GameTooltip:Hide() end)

		row:Hide()
		g.rows[i] = row
	end

	------------------------------------------------------------- breakdown --
	local divider = g:CreateTexture(nil, "ARTWORK")
	divider:SetTexture("Interface\\Tooltips\\UI-Tooltip-Border")
	divider:SetPoint("TOPLEFT", 18, -92 - CRAFT_ROWS * CRAFT_ROW_H - 6)
	divider:SetWidth(500)
	divider:SetHeight(2)
	divider:SetVertexColor(0.4, 0.4, 0.4, 0.8)

	local detailTitle = g:CreateFontString(nil, "ARTWORK")
	Font(detailTitle, 11, 1, 0.82, 0)
	detailTitle:SetPoint("TOPLEFT", 18, -92 - CRAFT_ROWS * CRAFT_ROW_H - 14)
	detailTitle:SetWidth(500)
	detailTitle:SetJustifyH("LEFT")
	g.detailTitle = detailTitle

	local detailScroll = CreateFrame("ScrollFrame", "BidSniperCraftDetailScroll", g,
		"FauxScrollFrameTemplate")
	detailScroll:SetPoint("TOPLEFT", 18, -92 - CRAFT_ROWS * CRAFT_ROW_H - 30)
	detailScroll:SetWidth(462)
	detailScroll:SetHeight(DETAIL_ROWS * DETAIL_ROW_H)
	detailScroll:SetScript("OnVerticalScroll", function(self, offset)
		FauxScrollFrame_OnVerticalScroll(self, offset, DETAIL_ROW_H, function() BS:RefreshCraft() end)
	end)
	g.detailScroll = detailScroll

	g.detailRows = {}
	for i = 1, DETAIL_ROWS do
		local fs = g:CreateFontString(nil, "ARTWORK")
		Font(fs, 10, 0.9, 0.9, 0.9)
		fs:SetPoint("TOPLEFT", detailScroll, "TOPLEFT", 0, -(i - 1) * DETAIL_ROW_H)
		fs:SetWidth(462)
		fs:SetJustifyH("LEFT")
		g.detailRows[i] = fs
	end

	local detailFoot = g:CreateFontString(nil, "ARTWORK")
	Font(detailFoot, 10, 0.7, 0.7, 0.7)
	detailFoot:SetPoint("TOPLEFT", 18, -92 - CRAFT_ROWS * CRAFT_ROW_H - 34 - DETAIL_ROWS * DETAIL_ROW_H)
	detailFoot:SetWidth(500)
	detailFoot:SetJustifyH("LEFT")
	g.detailFoot = detailFoot

	--------------------------------------------------------------- buttons --
	local readBtn = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
	readBtn:SetPoint("BOTTOMLEFT", 18, 18)
	readBtn:SetWidth(112)
	readBtn:SetHeight(24)
	readBtn:SetText("Read recipes")
	readBtn:SetScript("OnClick", function() BS:HarvestRecipes(false) end)
	Tip(readBtn, "Read your alchemy window",
		"The client will not say what a character can make unless the tradeskill "
		.. "window is open. It is read automatically whenever you open alchemy, so "
		.. "this is only here for when you want to force it.\n\n"
		.. "It merges rather than replaces, so a search box or a 'have materials' "
		.. "tick cannot wipe out recipes it could not see.")

	local listBtn = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
	listBtn:SetPoint("BOTTOMLEFT", 136, 18)
	listBtn:SetWidth(112)
	listBtn:SetHeight(24)
	listBtn:SetText("Shopping list")
	listBtn:SetScript("OnClick", function()
		BS.craftView = "shopping"
		BS:RefreshCraft()
	end)
	Tip(listBtn, "What to go and buy",
		"Adds up the reagents for everything you have put a number against, takes "
		.. "off what is in your bags, and prices what is left.\n\n"
		.. "Bags only. What is in the bank is mentioned in grey beside anything you "
		.. "are short of, but never deducted - it may be there on purpose, and that "
		.. "is your call rather than an assumption made for you.\n\n"
		.. "Vials are listed on their own. They come off a vendor, so they are not "
		.. "part of any cost here - but you still need to know how many to pick up.")

	local recalcBtn = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
	recalcBtn:SetPoint("BOTTOMLEFT", 254, 18)
	recalcBtn:SetWidth(100)
	recalcBtn:SetHeight(24)
	recalcBtn:SetText("Recalculate")
	recalcBtn:SetScript("OnClick", function()
		BS.craftCosted = nil		-- drop the costing and work it out again
		BS:RefreshCraft()
	end)
	Tip(recalcBtn, "Do the sums again",
		"Costs everything out again from the prices and bag contents on hand. Free "
		.. "and instant - it asks the auction house for nothing.\n\n"
		.. "Worth pressing after an Auctionator scan, and after you buy or use mats.")

	local clearBtn = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
	clearBtn:SetPoint("BOTTOMLEFT", 360, 18)
	clearBtn:SetWidth(90)
	clearBtn:SetHeight(24)
	clearBtn:SetText("Clear plan")
	clearBtn:SetScript("OnClick", function() BS:ClearWants() end)
	Tip(clearBtn, "Forget the quantities",
		"Empties every number in the Want column. The recipes themselves stay.")

	local forgetBtn = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
	forgetBtn:SetPoint("BOTTOMLEFT", 456, 18)
	forgetBtn:SetWidth(66)
	forgetBtn:SetHeight(24)
	forgetBtn:SetText("Forget")
	forgetBtn:SetScript("OnClick", function() BS:ForgetRecipes() end)
	Tip(forgetBtn, "Empty the recipe list",
		"For when you have unlearned something, or read the wrong tradeskill in. "
		.. "Open alchemy to build it again.")

	local count = g:CreateFontString(nil, "ARTWORK")
	Font(count, 11, 0.7, 0.7, 0.7)
	count:SetPoint("BOTTOMRIGHT", -18, 48)
	g.count = count

	self.craftFrame = g
	self.craftView  = self.craftView or "shopping"
end

--=============================================================================
--  painting it
--=============================================================================

-- Writing the stored number back into a box, flagged so the box's own
-- OnTextChanged knows this was us and not somebody typing.
local function SetWantText(box, want)
	box.painting = true
	box:SetText((want and want > 0) and tostring(want) or "")
	box.painting = nil
end

-- "have / need", green once you are holding enough
local function HaveText(have, need)
	local colour = (have >= need) and "|cff00ff00" or "|cffff8800"
	return format("%s%d|r/%d", colour, have, need)
end

local function PaintRecipeDetail(g, name)
	local r = BS:Recipes()[name]
	if not r then
		g.detailTitle:SetText("|cff888888that recipe is no longer on the list|r")
		return {}, ""
	end

	local c = BS:CostRecipe(r)
	g.detailTitle:SetText(format("|cffffffff%s|r  -  you can make |cffffd100%d|r "
		.. "from what you hold", name, c.canMake or 0))

	local lines, banked = {}, 0
	for _, line in ipairs(c.lines) do
		local note = line.vendor and "  |cff88bbffvendor|r"
			or (line.unit and ("  " .. BS.Money(line.unit) .. " each") or "  |cffff5555none up|r")
		local short = math.max(0, line.need - line.have)
		if (line.bank or 0) > 0 then banked = banked + 1 end

		lines[#lines + 1] = format("%s  %s%s%s%s", HaveText(line.have, line.need),
			line.name, note,
			short > 0 and format("   |cffff8800need %d more|r", short) or "",
			-- grey and last: a reminder, not part of the sum
			(line.bank or 0) > 0 and format("   |cff777777%d in bank|r", line.bank) or "")
	end

	return lines, format("Counting your bags only. Costs %s to make one, and you are "
		.. "carrying enough for %d.%s",
		BS.Money(c.cost), c.canMake or 0,
		banked > 0 and "  Some of it is in the bank - see the grey notes." or "")
end

local function PaintShoppingList(g)
	local buy, vendor, cost, exact = BS:ShoppingList()

	if #buy == 0 and #vendor == 0 then
		g.detailTitle:SetText("|cffffffffShopping list|r  -  "
			.. "|cff888888type a number in Want against anything you plan to make|r")
		return {}, ""
	end

	g.detailTitle:SetText(format("|cffffffffShopping list|r  -  buy %s%s",
		BS.Money(cost), exact and "" or "  |cffff8800(estimate)|r"))

	-- grey, last on the line, and never part of the arithmetic
	local function bankNote(e)
		if (e.inBank or 0) <= 0 then return "" end
		return format("   |cff777777%d of those are in your bank|r", e.inBank)
	end

	local lines, banked = {}, 0
	for _, e in ipairs(buy) do
		if (e.inBank or 0) > 0 then banked = banked + 1 end
		if e.short > 0 then
			lines[#lines + 1] = format("|cffffffff%d|r %s   %s%s%s",
				e.short, e.name,
				e.unit and BS.Money(e.unit * e.short) or "|cffff5555no price|r",
				e.have > 0 and format("   |cff888888(need %d, have %d)|r", e.total, e.have) or "",
				bankNote(e))
		else
			lines[#lines + 1] = format("|cff00ff00have all %d|r %s", e.total, e.name)
		end
	end

	for _, e in ipairs(vendor) do
		if (e.inBank or 0) > 0 then banked = banked + 1 end
		lines[#lines + 1] = format("|cff88bbff%d|r %s   |cff88bbfffrom the vendor|r%s%s",
			e.short, e.name,
			e.have > 0 and format("   |cff888888(need %d, have %d)|r", e.total, e.have) or "",
			bankNote(e))
	end

	local extras = ""
	if #vendor > 0 then
		local n = 0
		for _, e in ipairs(vendor) do n = n + e.short end
		extras = format("  Plus %d vial%s off a vendor, not counted in that total.",
			n, n == 1 and "" or "s")
	end
	if banked > 0 then
		extras = extras .. format("  |cff777777%d of these you also have in the bank, "
			.. "not deducted.|r", banked)
	end

	return lines, format("What you are short after your bags. The bank is never "
		.. "deducted.%s", extras)
end

function BS:RefreshCraft()
	local g = self.craftFrame
	if not g or not g:IsShown() then return end

	--[[
		Painting moves focus off boxes whose row has changed hands, and losing
		focus commits, and committing asks for a repaint - so this can be called
		from inside itself. Re-entering half way through would paint rows from
		one list and the breakdown from another. Instead the inner call just
		notes that something moved, and the outer one goes round again once it
		has finished.
	]]
	if self.craftPainting then
		self.craftDirty = true
		return
	end
	self.craftPainting = true

	--[[
		Painted from the last costing rather than costed afresh, because this
		also runs on every tick of the scroll wheel and the fallback price
		lookups reach into Auctionator. The costing is thrown away whenever
		something that feeds it moves - a scan, a harvest, a quantity, or the
		panel being opened - so it can never show figures older than the prices
		and bags behind them.
	]]
	local list = self.craftCosted or self:CostAll()

	local offset = FauxScrollFrame_GetOffset(g.scroll) or 0
	for i = 1, CRAFT_ROWS do
		local row = g.rows[i]
		local c   = list[offset + i]
		if c then
			row.costed = c

			local colour = c.exact and "|cffffffff" or "|cffff8800"
			local picked = (self.craftView == "recipe" and self.craftPick == c.name)
			row.cells[1]:SetText((picked and "|cffffd100> |r" or "") .. colour .. c.name .. "|r")
			row.cells[2]:SetText((c.canMake or 0) > 0
				and ("|cff00ff00" .. c.canMake .. "|r") or "|cff6666660|r")
			row.cells[3]:SetText(BS.Money(c.cost))

			if c.profit then
				row.cells[4]:SetText(c.profit >= 0
					and ("|cff00ff00+" .. BS.MoneyPlain(c.profit) .. "|r")
					or  ("|cffff4444-" .. BS.MoneyPlain(-c.profit) .. "|r"))
			else
				row.cells[4]:SetText("|cff666666?|r")
			end

			--[[
				Rebind the box when the slot changes hands. Focus goes with the
				recipe that is leaving: a cursor sitting in a box that now
				stands for something else is how a number ends up typed against
				the wrong item.
			]]
			local box = row.want
			if box.owner ~= c.name then
				if box:HasFocus() then box:ClearFocus() end
				box.owner = c.name
				SetWantText(box, c.want)
			elseif not box:HasFocus() then
				-- same recipe, and nobody is typing: show what is stored
				SetWantText(box, c.want)
			end
			box:Show()
			row:Show()
		else
			row.costed = nil
			row.want.owner = nil
			SetWantText(row.want, nil)
			row.want:Hide()
			row:Hide()
		end
	end
	FauxScrollFrame_Update(g.scroll, #list, CRAFT_ROWS, CRAFT_ROW_H)

	----------------------------------------------------------- breakdown --
	local lines, foot
	if self.craftView == "recipe" and self.craftPick then
		lines, foot = PaintRecipeDetail(g, self.craftPick)
	else
		lines, foot = PaintShoppingList(g)
	end

	local dOffset = FauxScrollFrame_GetOffset(g.detailScroll) or 0
	for i = 1, DETAIL_ROWS do
		g.detailRows[i]:SetText(lines[dOffset + i] or "")
	end
	FauxScrollFrame_Update(g.detailScroll, #lines, DETAIL_ROWS, DETAIL_ROW_H)
	g.detailFoot:SetText(foot or "")

	--------------------------------------------------------------- count --
	local exact, planned = 0, 0
	for _, c in ipairs(list) do
		if c.exact then exact = exact + 1 end
		if (c.want or 0) > 0 then planned = planned + 1 end
	end

	if #list == 0 then
		g.count:SetText("|cffff8800no recipes - open your alchemy window|r")
	else
		g.count:SetText(format("%d recipe%s%s%s", #list, #list == 1 and "" or "s",
			exact < #list and format("  -  |cffff8800%d estimated|r", #list - exact) or "",
			planned > 0 and format("  -  |cffffd100%d planned|r", planned) or ""))
	end

	self.craftPainting = nil
	if self.craftDirty then
		self.craftDirty = nil
		self:RefreshCraft()
	end
end

function BS:ShowCraft()
	if not self.frame then return end
	self.frame:Show()
	local g = self.craftFrame
	if not g then return end
	if g:IsShown() then g:Hide() else g:Show() end
end

function BS:ClearSettledBids()
	if not self:HasLedger() then self:NoLedger() return end
	local log, removed = self:Ledger(), 0
	for i = #log, 1, -1 do
		if BS.LedgerClosed(log[i]) then
			table.remove(log, i)
			removed = removed + 1
		end
	end
	self:Print(format("Cleared %d settled bid%s.", removed, removed == 1 and "" or "s"))
	self:RefreshLedger()
end

--[[
	Sorted so the states you can act on sit at the top: an auction you were
	outbid on is still there to be won, and that is the whole point of keeping
	this record.
]]
function BS:LedgerSorted()
	local list = {}
	if not self:HasLedger() then return list end
	local who = BS.LedgerOwner()
	for _, e in ipairs(self:Ledger()) do
		if e.char == who then list[#list + 1] = e end
	end
	table.sort(list, function(a, b)
		local oa = STATE_ORDER[a.state] or 9
		local ob = STATE_ORDER[b.state] or 9
		if oa ~= ob then return oa < ob end
		return (a.stateAt or a.placed or 0) > (b.stateAt or b.placed or 0)
	end)
	return list
end

function BS:RefreshLedger()
	local g = self.ledgerFrame
	if not g or not g:IsShown() then return end

	local list   = self:LedgerSorted()
	local offset = FauxScrollFrame_GetOffset(g.scroll) or 0

	for i = 1, LEDGER_ROWS do
		local row = g.rows[i]
		local e   = list[offset + i]
		if e then
			row.entry = e
			local color = ITEM_QUALITY_COLORS[e.quality] or ITEM_QUALITY_COLORS[1]
			local label = (color and color.hex or "") .. e.name .. "|r"
			if e.count > 1 then label = label .. " |cffaaaaaax" .. e.count .. "|r" end
			if (e.copies or 1) > 1 then
				label = label .. format("  |cffffd100(%d of them)|r", e.copies)
			end

			row.cells[1]:SetText(BS.ledgerStateText[e.state] or e.state)
			row.cells[2]:SetText(label)
			row.cells[3]:SetText(BS.Money(e.myBid))
			-- what it would cost to take the lead back, when we know it
			if e.state == "outbid" and e.nextBid and e.nextBid > 0 then
				row.cells[4]:SetText("|cffff8800" .. BS.Money(e.nextBid) .. "|r")
			elseif e.state == "leading" then
				row.cells[4]:SetText("|cff00ff00ahead|r")
			else
				row.cells[4]:SetText("|cff666666-|r")
			end
			row:Show()
		else
			row.entry = nil
			row:Hide()
		end
	end

	local counts = self:LedgerSummary()
	g.count:SetText(format("%d winning, %d outbid, %d on file",
		counts.leading or 0, counts.outbid or 0, #list))

	FauxScrollFrame_Update(g.scroll, #list, LEDGER_ROWS, LEDGER_ROW_H)
end

--=============================================================================
--  refreshing
--=============================================================================

function BS:RefreshControls()
	local f = self.frame
	if not f then return end
	for _, w in ipairs(f.refreshers) do
		if w.Refresh then w.Refresh() end
	end
	if self.catFrame and self.catFrame:IsShown() then self:RefreshCategories() end
end

function BS:SetStatus(text)
	if self.frame then self.frame.status:SetText(text or "") end
end

-- Reports where every filter control really landed, so a layout problem can be
-- read off numbers instead of guessed at.
function BS:DumpLayout()
	local f = self.frame
	if not f then self:Print("Window not built yet.") return end
	if not f:IsShown() then
		f:Show()
		self:Print("Window was hidden - showing it so positions resolve.")
	end

	self:Print(string.format("frame %.0f x %.0f, scale %.2f, font %s",
		f:GetWidth(), f:GetHeight(), f:GetEffectiveScale(), tostring(FONT_PATH)))

	local base = f:GetLeft()
	if not base then self:Print("No position yet, try again once it is on screen.") return end

	for _, entry in ipairs(f.debug) do
		local name, w = entry[1], entry[2]
		local l, r, t, b = w:GetLeft(), w:GetRight(), w:GetTop(), w:GetBottom()
		local size
		if w.GetFont then
			local _, s = w:GetFont()
			size = s
		elseif w.GetFontString and w:GetFontString() then
			local _, s = w:GetFontString():GetFont()
			size = s
		end
		if l and r then
			self:Print(string.format("%-12s x %3.0f to %3.0f (w %3.0f)  h %2.0f  font %s",
				name, l - base, r - base, r - l, (t and b) and (t - b) or 0,
				size and string.format("%.0f", size) or "?"))
		else
			self:Print(name .. ": not positioned")
		end
	end
end

function BS:SearchInBrowse(r)
	if self.scanning then
		self:Print("Wait for the scan to finish first.")
		return
	end
	if not (AuctionFrame and AuctionFrame:IsShown() and BrowseName and BrowseSearchButton) then
		self:Print("The auction house Browse tab is not available.")
		return
	end
	if AuctionFrameTab1 then AuctionFrameTab1:Click() end
	BrowseName:SetText(r.name)
	BrowseSearchButton:Click()
end

-- "?" when Auctionator has no price for the item. That is a different thing
-- from a bad deal, and it is the case you most need to see: a 100g buyout on
-- something nobody has ever sold tells you nothing.
local function ProfitText(profit)
	if profit == nil then return "|cff666666?|r" end
	if profit >= 0 then
		return "|cff00ff00+" .. BS.MoneyPlain(profit) .. "|r"
	end
	return "|cffff4444-" .. BS.MoneyPlain(-profit) .. "|r"
end

local function RatioText(ratio)
	if ratio >= 1000 then
		return string.format("|cffff44ff%sx|r", BS.Comma(ratio))
	elseif ratio >= 100 then
		return string.format("|cffff8800%.0fx|r", ratio)
	elseif ratio >= 25 then
		return string.format("|cffffff00%.0fx|r", ratio)
	end
	return string.format("%.1fx", ratio)
end

function BS:UpdateUI()
	local f = self.frame
	-- Nothing here does anything but paint, and OnShow repaints from scratch,
	-- so a closed window is work with nowhere to land. The ledger pane already
	-- bows out the same way.
	if not f or not f:IsShown() then return end

	f.scanBtn:SetText(self.scanning and "Stop" or "Scan AH")

	-- Resume only appears when a scan was actually interrupted, and never
	-- replaces Scan AH: a full scan must always be one click away.
	local res, nextPage = self:ResumeInfo()
	if res and not self.scanning then
		f.resumeBtn:SetText("Resume p" .. nextPage)
		f.resumeBtn:Show()
	else
		f.resumeBtn:Hide()
	end

	local selected, available, selTotal, selAuctions = self:CountSelected()

	if self.armed then
		-- one click, one bid: the button shows exactly what it is about to spend
		f.batchBtn:SetText("BID " .. BS.MoneyPlain(self.armed.bid))
		f.batchBtn:Enable()
	elseif self.batch then
		f.batchBtn:SetText("preparing...")
		f.batchBtn:Disable()
	else
		f.batchBtn:SetText("Bid selected")
		f.batchBtn:Enable()
	end

	-- Skip is only meaningful while something is armed or being looked up
	if self.armed or self.batch or self.bidSearch then
		f.skipBtn:Show()
	else
		f.skipBtn:Hide()
	end

	f.selectBtn:SetText(self.batch and "Stop batch"
		or (selected >= available and available > 0 and "Select none" or "Select all"))

	if self.batch then
		f.selCount:SetText(format("|cffffd100click BID  -  %d of %d done|r",
			self.batchDone or 0, #self.batch))
	elseif selected > 0 then
		-- ticked rows and the auctions behind them are different numbers as soon
		-- as one deal has copies, so show both rather than a figure that looks
		-- wrong against the total
		local rows = (selAuctions > selected)
			and format("%d of %d selected (%d auctions)", selected, available, selAuctions)
			or  format("%d of %d selected", selected, available)
		f.selCount:SetText(format("%s  -  %s", rows, BS.Money(selTotal)))
	elseif available > 0 then
		f.selCount:SetText(format("|cff888888none of %d selected|r", available))
	elseif #self.results > 0 and (self.db.minProfit or 0) > 0 then
		-- nothing tickable and rows on screen: say which filter did it, or the
		-- Select all button looks broken
		f.selCount:SetText(format("|cffff8800none clear %s profit|r",
			BS.MoneyPlain(self.db.minProfit)))
	else
		f.selCount:SetText("")
	end

	-- header arrows
	for _, h in ipairs(f.headers) do
		if h.key == self.db.sortKey then
			h.label:SetText("|cffffd100" .. h.col.text .. (self.db.sortDesc and " v" or " ^") .. "|r")
		else
			h.label:SetText(h.col.text)
		end
	end

	local results = self.results
	local offset  = FauxScrollFrame_GetOffset(f.scroll) or 0

	for i = 1, NUM_ROWS do
		local row = f.rows[i]
		local r   = results[offset + i]

		if r then
			BS:FillValue(r)

			row.result      = r
			row.resultIndex = offset + i
			row.icon:SetTexture(r.texture)
			row.check:SetChecked(r.selected and true or false)

			local expired = BS.Expired(r)
			local color = ITEM_QUALITY_COLORS[r.quality] or ITEM_QUALITY_COLORS[1]
			local label = (expired and "|cff777777" or (color and color.hex or ""))
			              .. r.name .. "|r"
			if r.count > 1 then label = label .. " |cffaaaaaax" .. r.count .. "|r" end
			-- x20 is the stack, "4 up" is how many identical auctions there are:
			-- one row stands for the lot, so say so rather than listing it four
			-- times and leaving you to wonder which is which
			local copies, done = r.copies or 1, r.bidsDone or 0
			if r.counted and copies - done <= 0 then
				-- a counted row with nothing left is either finished or taken,
				-- and which of the two is worth saying
				label = label .. (done > 0
					and format("  |cff00ff00(all %d bid)|r", done)
					or  "  |cff888888(none left)|r")
			elseif copies > 1 then
				label = label .. (done > 0
					and format("  |cffffd100(%d of %d up bid)|r", done, copies)
					or  format("  |cffffd100(%d up)|r", copies))
			end
			if r.bidPlaced then
				label = "|cff00ff00*|r " .. label
			elseif r.bidPending then
				label = "|cffffcc00?|r " .. label
			end
			row.icon:SetDesaturated(expired)
			row.icon:SetAlpha(expired and 0.4 or 1)

			row.cells[1]:SetText(label)
			row.cells[2]:SetText(BS.Money(r.bid))
			row.cells[3]:SetText(BS.Money(r.buyout))
			row.cells[4]:SetText(RatioText(r.ratio))
			row.cells[5]:SetText(r.market > 0 and BS.Money(r.market) or "|cff666666-|r")
			row.cells[6]:SetText(ProfitText(r.profit))
			row.cells[7]:SetText(expired and "|cff777777gone|r"
				or (BS.Doubtful(r) and "|cffff8800stale|r")
				or BS.timeLeftText[r.timeLeft] or "?")
			row.cells[8]:SetText(r.owner or "|cff666666?|r")
			row:Show()
		else
			row.result      = nil
			row.resultIndex = nil
			row:Hide()
		end
	end

	-- last: clamping the scrollbar here can call us again with a valid offset
	FauxScrollFrame_Update(f.scroll, #results, NUM_ROWS, ROW_HEIGHT)
end
