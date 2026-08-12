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
	catBtn.Refresh = function() catBtn:SetText(BS:CategoryLabel(BS.db.category)) end

	-- a menu opened on demand, rather than an inline dropdown widget whose
	-- size is not ours to control
	local catMenu = CreateFrame("Frame", "BidSniperCategoryMenu", f, "UIDropDownMenuTemplate")
	catMenu:Hide()
	UIDropDownMenu_Initialize(catMenu, function()
		local info = UIDropDownMenu_CreateInfo()
		info.text  = "All categories"
		info.func  = function() BS.db.category = 0 catBtn.Refresh() BS:UpdateUI() end
		info.checked = (BS.db.category == 0)
		UIDropDownMenu_AddButton(info)

		local names = BS:CategoryNames()
		if names then
			for i, name in ipairs(names) do
				local entry   = UIDropDownMenu_CreateInfo()
				entry.text    = name
				entry.checked = (BS.db.category == i)
				entry.func    = function()
					BS.db.category = i
					catBtn.Refresh()
					BS:UpdateUI()
				end
				UIDropDownMenu_AddButton(entry)
			end
		end
	end, "MENU")
	catBtn:SetScript("OnClick", function(self)
		if not BS:CategoryNames() then
			BS:Print("Open the auction house once so the category list loads.")
			return
		end
		ToggleDropDownMenu(1, nil, catMenu, self, 0, 0)
	end)
	Tip(catBtn, "Limit the scan to one category",
		"Scanning a single category is far quicker than the whole auction house. "
		.. "GetAll cannot be filtered, so choosing a category always scans page by "
		.. "page.")

	local wishBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	wishBtn:SetPoint("TOPLEFT", COL[3], FIELD2_Y)
	wishBtn:SetWidth(120)
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
	wishScanBtn:SetPoint("TOPLEFT", COL[3] + 130, FIELD2_Y)
	wishScanBtn:SetWidth(140)
	wishScanBtn:SetHeight(22)
	wishScanBtn:SetText("Scan wishlist")
	wishScanBtn:SetScript("OnClick", function() BS:StartScan(false, "wishlist") end)
	Tip(wishScanBtn, "Scan only the wishlist",
		"Searches for each item on your wishlist in turn and applies the same "
		.. "filters. Much quicker than a full scan.")
	f.wishScanBtn = wishScanBtn

	local rebidBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	rebidBtn:SetPoint("TOPLEFT", 616, FIELD_Y - 1)
	rebidBtn:SetWidth(96)
	rebidBtn:SetHeight(24)
	rebidBtn:SetText("Re-bid")
	rebidBtn:SetScript("OnClick", function() BS:RebidOutbid() end)
	Tip(rebidBtn, "Re-bid where you were outbid",
		"Asks the server which of your bids have been beaten and queues them all up "
		.. "for the BID button. Needs no scan - it works straight off your bid list. "
		.. "Auctions that have climbed past your Max bid, or past their own buyout, "
		.. "are left alone and reported.")
	f.rebidBtn = rebidBtn

	local scanBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	scanBtn:SetPoint("TOPRIGHT", -18, FIELD_Y - 1)
	scanBtn:SetWidth(104)
	scanBtn:SetHeight(24)
	scanBtn:SetText("Scan AH")
	scanBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	scanBtn:SetScript("OnClick", function(self, button)
		if BS.scanning then
			BS:StopScan("Scan cancelled.")
			return
		end
		-- a resume point is used unless you deliberately ask for a fresh scan
		local fresh = (button == "RightButton") or IsShiftKeyDown()
		BS:StartScan(not fresh)
	end)
	Tip(scanBtn, "Scan the auction house",
		"Reads the auction house cheapest bid first and stops once bids pass your "
		.. "Max bid. If a scan was interrupted this reads Resume scan and carries on "
		.. "from where it stopped, keeping what it already found. Right-click or "
		.. "shift-click to throw that away and start a fresh scan.")

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
		row.check:SetScript("OnClick", function(self)
			local r = row.result
			if r then r.selected = self:GetChecked() and true or false end
			BS:UpdateUI()
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
			if r.profit then
				GameTooltip:AddDoubleLine("Market value", BS.Money(r.market), 0.8, 0.8, 0.8)
				GameTooltip:AddDoubleLine("Profit over bid", BS.Money(r.profit), 0.2, 1, 0.2)
				GameTooltip:AddDoubleLine("After 5% AH cut", BS.Money(r.market * 0.95 - r.bid), 0.6, 0.6, 0.6)
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
				GameTooltip:AddLine("You have already bid on this one.", 0.2, 1, 0.2)
			end
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
	hint:SetText("tick = select    click = bid    ctrl-click = arm the BID button")

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

	f.refreshers = { ratioEdit, maxBidEdit, minBuyEdit, qualityBtn, catBtn,
	                 cbNoBids, cbSoon, cbOwn, cbAuto }
	f.scanBtn = scanBtn

	-- /snipe debug prints where these actually ended up on screen
	f.debug = {
		{ "lbl ratio",   lblRatio   }, { "box ratio",   ratioEdit  },
		{ "lbl maxbid",  lblMaxBid  }, { "box maxbid",  maxBidEdit },
		{ "lbl minbuy",  lblMinBuy  }, { "box minbuy",  minBuyEdit },
		{ "lbl quality", lblQuality }, { "btn quality", qualityBtn },
		{ "btn scan",    scanBtn    },
	}

	f:SetScript("OnShow", function() BS:RefreshControls() BS:UpdateUI() end)

	self.frame = f
	self:RefreshControls()
	self:SetStatus("Open the auction house and press Scan AH.")
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
--  refreshing
--=============================================================================

function BS:RefreshControls()
	local f = self.frame
	if not f then return end
	for _, w in ipairs(f.refreshers) do
		if w.Refresh then w.Refresh() end
	end
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
	if not f then return end

	if self.scanning then
		f.scanBtn:SetText("Stop")
	elseif self.db.resume then
		f.scanBtn:SetText("Resume scan")
	else
		f.scanBtn:SetText("Scan AH")
	end

	local selected, available, selTotal = self:CountSelected()

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
		f.selCount:SetText(format("%d of %d selected  -  %s",
			selected, available, BS.Money(selTotal)))
	elseif available > 0 then
		f.selCount:SetText(format("|cff888888none of %d selected|r", available))
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

			row.result = r
			row.icon:SetTexture(r.texture)
			row.check:SetChecked(r.selected and true or false)

			local expired = BS.Expired(r)
			local color = ITEM_QUALITY_COLORS[r.quality] or ITEM_QUALITY_COLORS[1]
			local label = (expired and "|cff777777" or (color and color.hex or ""))
			              .. r.name .. "|r"
			if r.count > 1 then label = label .. " |cffaaaaaax" .. r.count .. "|r" end
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
			row.result = nil
			row:Hide()
		end
	end

	-- last: clamping the scrollbar here can call us again with a valid offset
	FauxScrollFrame_Update(f.scroll, #results, NUM_ROWS, ROW_HEIGHT)
end
