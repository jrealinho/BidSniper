--[[--------------------------------------------------------------------------
	BidSniper - window, filters and result list
----------------------------------------------------------------------------]]

local BS = BidSniper
local format = string.format

local ROW_HEIGHT = 20
local NUM_ROWS   = 17
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

--[[
	Blizzard's dialog background is a half-transparent tile, which over the
	auction house leaves the rows behind ours showing through the numbers in
	front. This lays a solid panel over that tile and under everything else.

	Created after SetBackdrop on purpose: within one draw layer the order is the
	order things were made in, so this sits above the backdrop's own background
	and below the border and every piece of text. No sublevel argument, which
	not every build of this client honours.
]]
local function Solid(frame, alpha)
	local t = frame:CreateTexture(nil, "BACKGROUND")
	t:SetTexture(0.05, 0.05, 0.07, alpha or 0.72)
	t:SetPoint("TOPLEFT", 11, -12)
	t:SetPoint("BOTTOMRIGHT", -12, 11)
	return t
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

--[[
	One look for every button that spends money, and it is worth being strict
	about because the alternative already cost somebody a second load of
	reagents.

	Three buttons here commit gold - bid, buy, post - and all three work the
	same way: the addon lines a thing up, and the press is yours, because the
	client will not let it be otherwise. That makes the button the only place
	the difference between "about to spend" and "already spent" can be shown,
	and for a long time it was shown by changing a number on an otherwise
	identical grey button. Press it twice out of habit and the second press
	bought another lot.

	So the states are made to look nothing like each other:

	  * ARMED is orange, shouts, and names the exact figure this one press
	    commits. It is the only state that ever spends anything.
	  * DONE is green, past tense, and the button is dead. Nothing about it
	    invites a press.
	  * BUSY is grey and dead: something is in flight, wait.
	  * Ready-to-start is ordinary text, because it starts a process rather
	    than spending.

	Colour alone would not be enough - the wording changes with it, so the
	states are still distinguishable to anyone who cannot tell orange from
	green, and the button being disabled does the real work of preventing the
	accident.
]]
local ARMED_COLOUR = "|cffff7020"
local DONE_COLOUR  = "|cff40ff40"
local BUSY_COLOUR  = "|cff999999"

-- "this press spends exactly this much"
local function ArmedText(verb, money)
	return format("%s>> %s %s|r", ARMED_COLOUR, verb, money)
end

-- "it happened, and here is what it was"
local function DoneText(text)
	return DONE_COLOUR .. text .. "|r"
end

local function BusyText(text)
	return BUSY_COLOUR .. text .. "|r"
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
	f:SetHeight(628)
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:SetBackdrop({
		bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	Solid(f)
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
	--[[
		Pushed right rather than centred, because the tab row grew.

		Five tabs reach a third of the way across an 842-wide window and a centred
		title starts a little before that, so the two met - and the title is what
		gives way. Right-aligned it clears the close button and cannot collide with
		the row however many tabs get built, which a centred one could only promise
		until the next page was added.
	]]
	title:SetPoint("TOPRIGHT", -44, -14)
	title:SetText("BidSniper  |cff888888- low bid, high buyout|r")
	f.title = title

	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)

	--[[
		Two jobs, two tabs. Sniping wants a wide table of auctions; costing out
		flasks wants a list and a breakdown under it. Sharing one window meant
		the crafting side lived in a narrow panel hanging off the edge, which
		is a poor use of a window that is already 800 pixels wide.

		Plain buttons rather than Blizzard's tab template: that template hangs
		named textures off its parent, and everything in this file avoids those
		so a skinning addon has nothing of ours to reach into and resize.
	]]
	f.tabs = {}
	local function MakeTab(key, text, x, width)
		local t = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
		-- level with the title, which is centred, so the left edge is free
		t:SetPoint("TOPLEFT", x, -10)
		t:SetWidth(width)
		t:SetHeight(20)
		t:SetText(text)
		t:SetScript("OnClick", function() BS:SetTab(key) end)
		t.key = key
		f.tabs[#f.tabs + 1] = t
		return t
	end
	-- narrower than they were: a fourth tab has to fit between the left edge
	-- and the centred title, and the title is what gives way last
	-- Laid out one after another rather than at fixed offsets, so a tab that is
	-- not built leaves no hole where it would have been.
	local tabX = 16
	local function AddTab(key, text, width)
		MakeTab(key, text, tabX, width)
		tabX = tabX + width + 4
	end
	--[[
		Two families, with a gap drawn between them.

		Auctions, Buy and Sell are the auction house itself: what is for sale, how
		to buy it, how to sell yours. The crafting pages are a different job - what
		to do with what you bought - so they sit apart rather than in the same run,
		and the gap is there to be seen rather than inferred.

		No Buy tab when the file behind it is not loaded: a page that can only give
		you errors is worse than a page that is not offered. PLAYER_LOGIN says why,
		once, rather than leaving you to wonder where it went.
	]]
	AddTab("snipe", "Auctions", 74)
	if self:HasBuy() then AddTab("buy", "Buy", 54) end
	AddTab("sell", "Sell", 54)

	tabX = tabX + 14		-- the seam between the two families

	--[[
		One tab per mode, not per profession. Which profession a mode is showing is
		chosen on the page itself, so a dozen professions still cost two tabs - and
		a profession offered in both modes gets a page in each without either tab
		knowing anything about it.
	]]
	for _, m in ipairs(BS.ModeOrder) do AddTab(m.tab, m.label, m.tabWidth) end

	--------------------------------------------------------------- filters --
	-- Labels sit ABOVE their control, in fixed columns. Other addons (ElvUI in
	-- particular) swap the default fonts, so nothing here may depend on how
	-- wide a piece of text happens to render.
	local COL      = { 16, 176, 336, 496 }
	--[[
		The filter row has columns of its own, packed tighter than the rest.

		Scan AH and Resume share the right-hand end of this row, and Resume sat
		exactly on top of the Min profit box - the same x, the same width, the
		same y. Nobody saw it for a while because Resume only appears after a
		scan has been interrupted, so most of the time there was nothing there
		to notice.

		The row was never short of space; it was spread thin. Five controls in
		four 160-pixel columns left gaps of sixty and a hundred pixels between
		them while the last one ran into the buttons. Twenty-pixel gutters fit
		all five in the first two thirds and leave the last third to the two
		buttons, with room to spare between.

		Kept separate from COL because that one also places the second row and
		the tick boxes, and those have long labels beside them rather than
		above, so they need the wide columns they have.
	]]
	local FCOL     = { 16, 96, 216, 336, 466 }
	local LABEL_Y  = -38
	local FIELD_Y  = -56
	local LABEL2_Y = -84
	local FIELD2_Y = -102
	local CHECK_Y  = -134

	local lblRatio = MakeLabel(f, "Min ratio", FCOL[1], LABEL_Y)
	local ratioEdit = MakeEditBox(f, FCOL[1], FIELD_Y, 60)
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

	local lblMaxBid = MakeLabel(f, "Max bid each", FCOL[2], LABEL_Y)
	local maxBidEdit = MakeMoneyEdit(f, FCOL[2], FIELD_Y, 100,
		function() return BS.db.maxBid end,
		function(v) BS.db.maxBid = v end,
		"Maximum bid, per item",
		"Hide anything that costs more than this to bid on |cffffd100for one of "
		.. "them|r. 0 = no limit.\n\n"
		.. "Per item, not per auction: a stack of twenty at a 40g bid is 2g each, and "
		.. "2g is what you are being asked to pay for one of them. A limit that judged "
		.. "the 40g would throw away every stack on the house.\n\n"
		.. "The auction still costs the whole 40g to bid on. The BID button always "
		.. "shows what one press spends, and a batch asks you to approve the total "
		.. "before it starts.")

	local lblMinBuy = MakeLabel(f, "Min buyout", FCOL[3], LABEL_Y)
	local minBuyEdit = MakeMoneyEdit(f, FCOL[3], FIELD_Y, 100,
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
	local PROFIT_X = FCOL[5]
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
	local lblQuality = MakeLabel(f, "Min quality", FCOL[4], LABEL_Y)
	local qualityBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	qualityBtn:SetPoint("TOPLEFT", FCOL[4], FIELD_Y - 1)
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

	-- Widths on this row are chosen to add up rather than by eye: the last
	-- button has to land inside an 842-wide window, and the category button
	-- ahead of them is a fixed 260.
	local wishBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	wishBtn:SetPoint("TOPLEFT", 286, FIELD2_Y)
	wishBtn:SetWidth(108)
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
	wishScanBtn:SetPoint("TOPLEFT", 400, FIELD2_Y)
	wishScanBtn:SetWidth(150)
	wishScanBtn:SetHeight(22)
	wishScanBtn:SetText("Scan wishlist")
	wishScanBtn:SetScript("OnClick", function() BS:StartScan(false, "wishlist") end)
	Tip(wishScanBtn, "Scan only the wishlist",
		"Searches for each item on your wishlist in turn and applies the same "
		.. "filters. Much quicker than a full scan.")
	f.wishScanBtn = wishScanBtn

	-- Craft used to be a button here; it is a tab now, which is what freed the
	-- room these three get to spread back into.
	local rebidBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	rebidBtn:SetPoint("TOPLEFT", 590, FIELD2_Y)
	rebidBtn:SetWidth(104)
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
	myBidsBtn:SetPoint("TOPLEFT", 700, FIELD2_Y)
	myBidsBtn:SetWidth(122)
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

	--[[
		Under Scan AH, in the one part of this row nothing else wanted.

		Moving a filter already repaints the table on its own - the filters are
		a window onto the results rather than something baked into them - so
		this is for the two things that need saying out loud: prices that have
		moved since the list was drawn, and auctions that have since ended.
	]]
	local refreshBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	refreshBtn:SetPoint("TOPRIGHT", -18, CHECK_Y - 1)
	refreshBtn:SetWidth(104)
	refreshBtn:SetHeight(22)
	refreshBtn:SetText("Refresh")
	refreshBtn:SetScript("OnClick", function() BS:RefreshResults() end)
	Tip(refreshBtn, "Go over the list again",
		"Re-applies the filters, drops auctions that have certainly ended, and "
		.. "rebuilds the Profit column from current prices - useful straight after an "
		.. "Auctionator scan.\n\nIt asks the auction house for nothing, so it costs "
		.. "nothing.\n\nChanging a filter already repaints the table by itself; you do "
		.. "not have to press this for that.")
	f.refreshBtn = refreshBtn

	------------------------------------------------------- column headers --
	-- a band behind the names, so the header reads as a heading rather than as
	-- the first row of the table
	local headBand = f:CreateTexture(nil, "BACKGROUND")
	headBand:SetTexture(1, 1, 1, 0.06)
	headBand:SetPoint("TOPLEFT", 16, -166)
	headBand:SetWidth(ROW_WIDTH)
	headBand:SetHeight(20)

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

	-- bright rule with a dark one beneath: reads as a carved edge at any UI
	-- scale, where the single faint line it replaces tended to disappear
	local line = f:CreateTexture(nil, "ARTWORK")
	line:SetTexture(1, 0.82, 0, 0.5)
	line:SetPoint("TOPLEFT", 16, -186)
	line:SetWidth(ROW_WIDTH)
	line:SetHeight(2)

	local lineShadow = f:CreateTexture(nil, "ARTWORK")
	lineShadow:SetTexture(0, 0, 0, 0.85)
	lineShadow:SetPoint("TOPLEFT", 16, -188)
	lineShadow:SetWidth(ROW_WIDTH)
	lineShadow:SetHeight(1)

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

		-- Banding, fixed to the slot rather than to the data. A row keeps its
		-- place on screen however the list is scrolled, so the pattern stays
		-- still while the contents move past it; striping by result index would
		-- make the whole table shimmer on every scroll.
		if i % 2 == 0 then
			local stripe = row:CreateTexture(nil, "BACKGROUND")
			stripe:SetTexture(1, 1, 1, 0.035)
			stripe:SetAllPoints(row)
		end

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
				-- deliberately a chat link, so the Buy page's shift-click
				-- shortcut has to know not to treat it as a request to shop
				if BS.LinkToChat then BS:LinkToChat(r.link)
				else HandleModifiedItemClick(r.link) end
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

				--[[
					Which of the three price sources said so.

					They answer the same question from different moments: our own
					sweep is the freshest but only knows what it walked past,
					Auctionator's database covers everything but only moves when
					Auctionator scans, and the cache is Auctionator's answer from
					up to a day ago. When a Market figure looks wrong next to
					Auctionator's own window, this is the line that says why.
				]]
				if r.priceSrc == "scan" then
					GameTooltip:AddDoubleLine("Priced from", "this addon's last scan",
						0.5, 0.5, 0.5, 0.5, 0.7, 0.5)
				elseif r.priceSrc == "auctionator" then
					GameTooltip:AddDoubleLine("Priced from", "Auctionator's database",
						0.5, 0.5, 0.5, 0.5, 0.6, 0.7)
				elseif r.priceSrc == "cache" then
					GameTooltip:AddDoubleLine("Priced from", "a remembered price",
						0.5, 0.5, 0.5, 0.7, 0.6, 0.4)
				end
			else
				GameTooltip:AddLine("Nothing known about what this is worth -", 1, 0.5, 0.2)
				GameTooltip:AddLine("the buyout alone proves nothing, so the", 1, 0.5, 0.2)
				GameTooltip:AddLine("ratio is only the seller's asking price.", 1, 0.5, 0.2)
			end

			-- where the number in the Ratio column came from, since there are
			-- two possible answers and they mean very different things
			if r.ratioFrom == "market" then
				GameTooltip:AddDoubleLine("Ratio: worth over what a bid costs",
					format("%.1fx", r.ratio or 0), 0.8, 0.8, 0.8, 1, 1, 1)
				if r.ratioBuyout then
					GameTooltip:AddDoubleLine("On the seller's buyout instead",
						format("%.1fx", r.ratioBuyout), 0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
				end
			else
				GameTooltip:AddDoubleLine("Ratio: the seller's buyout over the bid",
					format("%.1fx", r.ratio or 0), 0.9, 0.6, 0.4, 0.9, 0.6, 0.4)
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
	for _, m in ipairs(BS.ModeOrder) do self:BuildCraftUI(f, m) end
	self:BuildSellUI(f)
	if self:HasBuy() then self:BuildBuyUI(f) end

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

	-- Must come before anything that reads self.frame, which SetTab does: it
	-- bails out when there is no window yet, so calling it any earlier in here
	-- left both tabs looking unselected until the first one was clicked.
	self.frame = f

	self:SetTab("snipe")		-- the window opens on the auctions
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
	Solid(c)
	c:EnableMouse(true)
	c:Hide()

	-- only one side panel at a time, they share the same spot
	c:SetScript("OnShow", function()
		if BS.wishFrame   then BS.wishFrame:Hide()   end
		if BS.ledgerFrame then BS.ledgerFrame:Hide() end
		BS:SetTab("snipe")		-- side panels belong to the auction page
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
	Solid(w)
	w:EnableMouse(true)
	w:Hide()
	w:SetScript("OnShow", function()
		if BS.catFrame    then BS.catFrame:Hide()    end
		if BS.ledgerFrame then BS.ledgerFrame:Hide() end
		BS:SetTab("snipe")		-- side panels belong to the auction page
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
	Solid(g)
	g:EnableMouse(true)
	g:Hide()
	g:SetScript("OnShow", function()
		if BS.catFrame  then BS.catFrame:Hide()  end
		if BS.wishFrame then BS.wishFrame:Hide() end
		BS:SetTab("snipe")		-- side panels belong to the auction page
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
				if (e.outCount or 0) > 0 or (e.leadCount or 0) > 0 then
					GameTooltip:AddDoubleLine("Still leading / outbid",
						format("%d / %d", e.leadCount or 0, e.outCount or 0),
						0.7, 0.7, 0.7, 0.2, 1, 0.2)
					GameTooltip:AddLine("You cannot outbid yourself - the server refuses "
						.. "a bid on an auction you already lead, and these are separate "
						.. "auctions. Somebody else took the ones marked outbid.",
						0.6, 0.6, 0.6, true)
				end
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

local CRAFT_ROWS   = 13
local CRAFT_ROW_H  = 22
local DETAIL_ROWS  = 8
local DETAIL_ROW_H = 16

--[[
	The page answers two questions that want different shapes.

	"Which of these is worth making?" is a sorted list, and it is the top half.

	"So what do I actually have to buy?" is a breakdown, and it is the bottom
	half - either the reagents of whichever recipe you clicked, or, once you
	have typed quantities against a few of them, the whole shopping list with
	your bags already deducted.

	It fills the window rather than hanging off the side of it, which is what
	lets both halves be read at a glance instead of through a slot.
]]
function BS:BuildCraftUI(parent, m)
	m = self:Mode(m)

	--[[
		The profession is asked for, never captured.

		A page outlives the choice: the selector across the top changes it, and the
		list, the breakdown, the buttons and any shopping run all have to follow.
		A profession held in an upvalue at build time would be whichever one it was
		when the window was made, for the rest of the session.
	]]
	local function prof() return BS:ModeProf(m) end

	--[[
		Frame names go by mode. FauxScrollFrameTemplate hangs a named scroll bar
		off whatever it is given, so two pages built by the same function must not
		be handed the same name.
	]]
	local sfx = "_" .. m.id

	local g = CreateFrame("Frame", "BidSniperCraftFrame" .. sfx, parent)
	g.mode = m
	g.view = "shopping"		-- which of the two the breakdown below is showing
	g:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, -34)
	g:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -11, 10)
	g:EnableMouse(true)
	-- nothing under a covered page should answer the wheel either
	g:SetScript("OnMouseWheel", function() end)
	g:EnableMouseWheel(true)
	g:Hide()

	--[[
		A page, not a sheet laid over one.

		This stands exactly where the auction table stands, so any trace of that
		table coming through reads as a fault rather than as depth - the two tabs
		are meant to feel like separate pages of one window, and neither may ever
		be a ghost behind the other. So: no transparency at all, and an edge of
		its own so the surface has a boundary rather than merely a colour.

		The frame level is not set here. The window is SetToplevel, which moves it
		as you click between it and other windows, and a level worked out once at
		build time can end up beneath children that moved with it. SetTab settles
		it against the parent every time the page comes up.
	]]
	g:SetBackdrop({
		bgFile   = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = false, edgeSize = 14,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	g:SetBackdropColor(0.05, 0.05, 0.07, 1)
	g:SetBackdropBorderColor(0.35, 0.32, 0.25, 1)

	-- Belt and braces over the backdrop: a solid fill corner to corner, so the
	-- inset ring the border draws its edge into cannot show anything through.
	local sheet = g:CreateTexture(nil, "BACKGROUND")
	sheet:SetTexture(0.05, 0.05, 0.07, 1)
	sheet:SetAllPoints(g)

	g:SetScript("OnShow", function()
		-- opening it is a request for the current answer, and both Auctionator's
		-- database and your bags may have moved since it was last up
		BS:InvalidateCost(prof())
		BS:RefreshCraft()
	end)

	local title = g:CreateFontString(nil, "ARTWORK")
	Font(title, 12, 1, 0.82, 0)
	title:SetPoint("TOPLEFT", 18, -8)
	g.titleFS = title		-- set on every repaint: the profession can change

	--[[
		Which profession this page is showing, when its mode offers more than one.

		A row of one button that cannot be pressed to any effect is noise, so it is
		not built at all until there is something to choose between - which means
		adding a second profession to a mode makes the selector appear on its own.

		On the title's line rather than under it: the page below is laid out to the
		pixel and a new row would push the list into the breakdown.
	]]
	g.profBtns = {}
	local choices = BS:ProfsForMode(m)
	if #choices > 1 then
		local bx = 190
		for _, choice in ipairs(choices) do
			local b = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
			b:SetPoint("TOPLEFT", bx, -6)
			b:SetWidth(66)
			b:SetHeight(18)
			b:SetText(choice.label)
			b.prof = choice
			b:SetScript("OnClick", function(self) BS:SetModeProf(m, self.prof) end)
			Tip(b, choice.title, "Show " .. choice.title .. " on this page.")
			g.profBtns[#g.profBtns + 1] = b
			bx = bx + 70
		end
	end

	local help = g:CreateFontString(nil, "ARTWORK")
	Font(help, 10, 0.6, 0.6, 0.6)
	help:SetPoint("TOPLEFT", 18, -28)
	help:SetWidth(780)
	help:SetJustifyH("LEFT")
	help:SetText(m.help)

	--[[
		Whether making it would still teach you anything.

		Ticked, the page drops everything the tradeskill window paints grey. It is
		a filter on the eyes only - see VisibleCosted for why a hidden recipe is
		still costed, still holds its Want, and is still shopped for.

		Top right rather than in the button row at the bottom: that row is full,
		and this belongs with the list it filters rather than with the things that
		spend money.
	]]
	local levelCb = CreateFrame("CheckButton", nil, g, "UICheckButtonTemplate")
	levelCb:SetPoint("TOPRIGHT", -20, -4)
	levelCb:SetWidth(20)
	levelCb:SetHeight(20)

	local levelLbl = g:CreateFontString(nil, "ARTWORK")
	Font(levelLbl, 10, 0.8, 0.8, 0.8)
	levelLbl:SetPoint("RIGHT", levelCb, "LEFT", -2, 0)
	levelLbl:SetText("only what can still level me")

	levelCb.Refresh = function() levelCb:SetChecked(BS:LevelOnly(m, prof())) end
	levelCb:SetScript("OnClick", function(self)
		BS:SetLevelOnly(m, prof(), self:GetChecked() and true or false)
	end)
	Tip(levelCb, "Hide what is too easy",
		"Drops every recipe your tradeskill window paints grey - the ones that can "
		.. "no longer give you a skill point.\n\n"
		.. "The colours are the client's own and arrive free with the recipe: orange "
		.. "almost always levels you, yellow usually does, green sometimes, grey "
		.. "never.\n\n"
		.. "They are a snapshot from the last time that window was open, and they go "
		.. "stale in one direction only - skill goes up, so a recipe recorded as "
		.. "orange may be yellow by now, never the other way about. Opening the "
		.. "profession again brings them up to date.\n\n"
		.. "Anything read before this addon recorded difficulty has none, and is "
		.. "never hidden: not knowing is not the same as knowing it is grey.")
	g.levelCb = levelCb

	-- a band behind the headers, so the column names read as a heading rather
	-- than as the first row of the list
	local band = g:CreateTexture(nil, "BACKGROUND")
	band:SetTexture(1, 1, 1, 0.06)
	band:SetPoint("TOPLEFT", 14, -48)
	band:SetWidth(788)
	band:SetHeight(20)

	-- With the whole window to work in, Sells for gets its own column instead
	-- of living in a tooltip.
	--[[
		The recipe and the Want box sit in the same place on every page, because
		they are the two things every reading of a recipe has in common. The five
		columns between them belong to the mode, geometry included - which is what
		lets a new mode be a table in BidSniperCraft.lua and nothing here.
	]]
	local heads = { { "Recipe", 2, 208, "LEFT" }, { "Want", 334, 44, "CENTER" } }
	for _, h in ipairs(m.heads) do heads[#heads + 1] = h end
	for _, h in ipairs(heads) do
		local fs = g:CreateFontString(nil, "ARTWORK")
		Font(fs, 10, 0.8, 0.8, 0.8)
		fs:SetPoint("TOPLEFT", 18 + h[2], -52)
		fs:SetWidth(h[3])
		fs:SetJustifyH(h[4])
		fs:SetText(h[1])
	end

	local scroll = CreateFrame("ScrollFrame", "BidSniperCraftScroll" .. sfx, g, "FauxScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 18, -66)
	scroll:SetWidth(756)
	scroll:SetHeight(CRAFT_ROWS * CRAFT_ROW_H)
	scroll:SetScript("OnVerticalScroll", function(self, offset)
		FauxScrollFrame_OnVerticalScroll(self, offset, CRAFT_ROW_H, function() BS:RefreshCraft() end)
	end)
	g.scroll = scroll

	g.rows = {}
	for i = 1, CRAFT_ROWS do
		local row = CreateFrame("Button", nil, g)
		row:SetWidth(740)
		row:SetHeight(CRAFT_ROW_H)
		if i == 1 then
			row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
		else
			row:SetPoint("TOPLEFT", g.rows[i - 1], "BOTTOMLEFT", 0, 0)
		end
		row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")

		--[[
			Banding, set once at build rather than per paint. A row sits at a
			fixed place on screen whatever the list is scrolled to, so tying the
			stripe to the slot keeps the pattern still while the contents move -
			which is the point of it. Tying it to the data would make the whole
			list shimmer on every scroll.
		]]
		if i % 2 == 0 then
			local stripe = row:CreateTexture(nil, "BACKGROUND")
			stripe:SetTexture(1, 1, 1, 0.035)
			stripe:SetAllPoints(row)
		end

		-- the recipe whose reagents are showing below, marked properly rather
		-- than with an arrow glued to the front of its name
		row.pick = row:CreateTexture(nil, "BORDER")
		row.pick:SetTexture(1, 0.82, 0, 0.14)
		row.pick:SetAllPoints(row)
		row.pick:Hide()

		row.cells = {}
		local layout = { { 2, 208, "LEFT" } }
		for _, h in ipairs(m.heads) do
			layout[#layout + 1] = { h[2], h[3], h[4] }
		end
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
		want:SetPoint("LEFT", 334, 0)
		want:SetWidth(44)
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
			BS:SetWant(prof(), self.owner, self:GetText())
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
			if g.pick == self.costed.name and g.view == "recipe" then
				g.view = "shopping"
			else
				g.pick = self.costed.name
				g.view = "recipe"
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
			-- the mode decides what is worth saying about the sums
			for _, t in ipairs(m.tipLines(c)) do
				GameTooltip:AddDoubleLine(t[1], t[2], 0.9, 0.9, 0.9,
					t[3] or 1, t[4] or 1, t[5] or 1)
			end
			--[[
				Crafts, and what those crafts come to whenever the two differ.
				Can make and Want are both counted in crafts; a recipe that
				yields two is the only place that distinction bites, and this is
				where it gets spelled out rather than left to be inferred.
			]]
			local makes = c.canMake or 0
			if (c.yield or 1) > 1 and makes > 0 then
				GameTooltip:AddDoubleLine("From what is in your bags",
					format("%d crafts  =  %g", makes, makes * c.yield),
					0.8, 0.8, 0.8, 1, 0.82, 0)
			else
				GameTooltip:AddDoubleLine("From what is in your bags",
					format("%d", makes), 0.8, 0.8, 0.8, 1, 0.82, 0)
			end
			if c.onAuction ~= nil then
				GameTooltip:AddDoubleLine("Already listed on the AH",
					format("%d", c.onAuction), 0.8, 0.8, 0.8,
					(c.onAuction == 0) and 1 or 1, (c.onAuction == 0) and 0.6 or 1,
					(c.onAuction == 0) and 0.2 or 1)
			else
				GameTooltip:AddLine("The auction house has not sent your own listings yet.",
					0.6, 0.6, 0.6, true)
			end

			if not c.exact then
				GameTooltip:AddLine(" ")
				GameTooltip:AddLine("This is an estimate:", 1, 0.6, 0.2)
				for _, why in ipairs(c.doubts) do
					GameTooltip:AddLine("  " .. why, 1, 0.6, 0.2, true)
				end
			end

			GameTooltip:AddLine(" ")
			local tr, tg, tb, td = BS.DiffColour(c.difficulty)
			if td then
				GameTooltip:AddDoubleLine("Skill", format("%s - %s", td.label, td.says),
					0.8, 0.8, 0.8, tr, tg, tb)
			else
				GameTooltip:AddDoubleLine("Skill", "not recorded yet - open the profession",
					0.8, 0.8, 0.8, 0.6, 0.6, 0.6)
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
	-- everything below hangs off where the list ends, so the row count above is
	-- the only number to change if this is ever re-proportioned
	local BELOW = -66 - CRAFT_ROWS * CRAFT_ROW_H

	--[[
		The seam between "which of these is worth making" and "so what do I go
		and buy" carries real weight, so it gets drawn rather than implied.

		A single faint line vanished into the background at most UI scales. A
		bright rule with a dark one directly beneath it reads as a carved edge
		instead, and the panel below picks the section out on its own.
	]]
	local pane = g:CreateTexture(nil, "BACKGROUND")
	pane:SetTexture(1, 1, 1, 0.045)
	pane:SetPoint("TOPLEFT", 14, BELOW - 14)
	pane:SetWidth(788)
	pane:SetHeight(40 + DETAIL_ROWS * DETAIL_ROW_H)

	local rule = g:CreateTexture(nil, "ARTWORK")
	rule:SetTexture(1, 0.82, 0, 0.5)
	rule:SetPoint("TOPLEFT", 14, BELOW - 6)
	rule:SetWidth(788)
	rule:SetHeight(2)

	local ruleShadow = g:CreateTexture(nil, "ARTWORK")
	ruleShadow:SetTexture(0, 0, 0, 0.85)
	ruleShadow:SetPoint("TOPLEFT", 14, BELOW - 8)
	ruleShadow:SetWidth(788)
	ruleShadow:SetHeight(1)

	local detailTitle = g:CreateFontString(nil, "ARTWORK")
	Font(detailTitle, 11, 1, 0.82, 0)
	detailTitle:SetPoint("TOPLEFT", 18, BELOW - 18)
	detailTitle:SetWidth(780)
	detailTitle:SetJustifyH("LEFT")
	g.detailTitle = detailTitle

	local detailScroll = CreateFrame("ScrollFrame", "BidSniperCraftDetailScroll" .. sfx, g,
		"FauxScrollFrameTemplate")
	detailScroll:SetPoint("TOPLEFT", 18, BELOW - 36)
	detailScroll:SetWidth(756)
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
		fs:SetWidth(756)
		fs:SetJustifyH("LEFT")
		g.detailRows[i] = fs
	end

	local detailFoot = g:CreateFontString(nil, "ARTWORK")
	Font(detailFoot, 10, 0.7, 0.7, 0.7)
	detailFoot:SetPoint("TOPLEFT", 18, BELOW - 36 - DETAIL_ROWS * DETAIL_ROW_H)
	detailFoot:SetWidth(780)
	detailFoot:SetJustifyH("LEFT")
	g.detailFoot = detailFoot

	--------------------------------------------------------------- buttons --
	local readBtn = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
	readBtn:SetPoint("BOTTOMLEFT", 18, 18)
	readBtn:SetWidth(112)
	readBtn:SetHeight(24)
	readBtn:SetText("Read recipes")
	readBtn:SetScript("OnClick", function() BS:HarvestRecipes(prof(), false) end)
	Tip(readBtn, "Read your tradeskill window",
		"The client will not say what a character can make unless the tradeskill "
		.. "window is open. It is read automatically whenever you open one, so this "
		.. "is only here for when you want to force it.\n\n"
		.. "It reads whichever profession is open rather than this page's, because "
		.. "that is plainly what you meant by pressing it. And it merges rather than "
		.. "replaces, so a search box or a 'have materials' tick cannot wipe out "
		.. "recipes it could not see.")

	local listBtn = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
	listBtn:SetPoint("BOTTOMLEFT", 136, 18)
	listBtn:SetWidth(112)
	listBtn:SetHeight(24)
	listBtn:SetText("Shopping list")
	listBtn:SetScript("OnClick", function()
		g.view = "shopping"
		BS:RefreshCraft()
	end)
	Tip(listBtn, "What to go and buy",
		"Adds up the reagents for everything you have put a number against, takes "
		.. "off what is in your bags, and prices what is left.\n\n"
		.. "Bags only. What is in the bank is mentioned in grey beside anything you "
		.. "are short of, but never deducted - it may be there on purpose, and that "
		.. "is your call rather than an assumption made for you.\n\n"
		.. "Anything that comes off a vendor is listed on its own. It is not part "
		.. "of any cost here - but you still need to know how many to pick up.")

	local recalcBtn = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
	recalcBtn:SetPoint("BOTTOMLEFT", 254, 18)
	recalcBtn:SetWidth(100)
	recalcBtn:SetHeight(24)
	recalcBtn:SetText("Recalculate")
	recalcBtn:SetScript("OnClick", function()
		BS:InvalidateCost(prof())		-- drop the costing and work it out again
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
	clearBtn:SetScript("OnClick", function() BS:ClearWants(prof()) end)
	Tip(clearBtn, "Forget the quantities",
		"Empties every number in the Want column. The recipes themselves stay.")

	local forgetBtn = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
	forgetBtn:SetPoint("BOTTOMLEFT", 456, 18)
	forgetBtn:SetWidth(66)
	forgetBtn:SetHeight(24)
	forgetBtn:SetText("Forget")
	forgetBtn:SetScript("OnClick", function() BS:ForgetRecipes(prof()) end)
	Tip(forgetBtn, "Empty the recipe list",
		"For when you have unlearned something, or read the wrong tradeskill in. "
		.. "It empties this page only - the other professions keep theirs. Open the "
		.. "profession again to build it back.")

	--[[
		The one button on this page that spends money, so it is the one that
		looks like it might.

		It sits at the end of the row rather than beside Shopping list, because
		the two are a sentence in that order: work out what to buy, then go and
		buy it. Everything left of here rearranges numbers and can be pressed by
		accident all day.
	]]
	local shopBtn = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
	shopBtn:SetPoint("BOTTOMLEFT", 528, 18)
	shopBtn:SetWidth(122)
	shopBtn:SetHeight(24)
	shopBtn:SetText("Buy the list")
	shopBtn:SetScript("OnClick", function()
		if BS:HasShop() then BS:ShopStart(prof(), m) else BS:NoShop() end
	end)
	Tip(shopBtn, "Go and buy all of it",
		"Takes the shopping list to the Buy tab and works down it for you: it fills "
		.. "in each search, finds the cheapest set of auctions that covers what you "
		.. "are short of, and arms the purchase. You press BUY, and it moves on to "
		.. "the next reagent on its own.\n\n"
		.. "You approve one total at the start and it never spends past it. Anything "
		.. "dearer than the list said - by more than the margin on the right - is "
		.. "left alone and named in chat with both figures, so nothing quietly costs "
		.. "triple because the market moved since the scan.\n\n"
		.. "WoW only lets an addon buy while you are actually clicking, so the "
		.. "presses are yours. Everything between them is not.")
	g.shopBtn = shopBtn

	--[[
		How far over the quote a run may go before it walks away.

		A margin rather than an exact match, because the quote came from the
		last scan and the cheapest auction behind it may well have been bought
		in the meantime - at nought per cent a run would refuse almost
		everything and read as broken.
	]]
	local overLabel = g:CreateFontString(nil, "ARTWORK")
	Font(overLabel, 10, 0.7, 0.7, 0.7)
	overLabel:SetPoint("BOTTOMLEFT", 660, 25)
	overLabel:SetText("pay up to +")

	local over = CreateFrame("EditBox", nil, g)
	over:SetPoint("BOTTOMLEFT", 722, 21)
	over:SetWidth(36)
	over:SetHeight(20)
	over:SetAutoFocus(false)
	over:SetNumeric(true)
	over:SetMaxLetters(3)
	over:SetJustifyH("CENTER")
	over:SetTextInsets(2, 2, 0, 0)
	over:SetBackdrop({
		bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 10,
		insets = { left = 2, right = 2, top = 2, bottom = 2 },
	})
	over:SetBackdropColor(0, 0, 0, 0.65)
	over:SetBackdropBorderColor(0.45, 0.45, 0.45, 1)
	Font(over, 11, 1, 1, 1)

	over.Refresh = function()
		if over:HasFocus() then return end
		over.painting = true
		over:SetText(tostring(BS:HasShop() and BS:ShopOver() or 20))
		over.painting = nil
	end
	local function commitOver()
		if over.painting or not BS:HasShop() then return end
		BS:ShopSettings().over = math.max(0, math.min(200,
			tonumber(over:GetText()) or BS:ShopOver()))
	end
	over:SetScript("OnTextChanged", commitOver)
	over:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	over:SetScript("OnEditFocusLost", function(self) commitOver() over.Refresh() end)
	over:SetScript("OnEscapePressed", function(self) over.Refresh() self:ClearFocus() end)
	Tip(over, "How far over the quote to go",
		"A run pays at most this much more than the shopping list said, per reagent, "
		.. "and leaves anything dearer.\n\n"
		.. "It is measured against the part of the purchase you actually needed. A "
		.. "stack that overshoots is judged on the items you were short of rather "
		.. "than on the ones that came with them, so a lone stack of twenty can never "
		.. "sneak past when you only wanted two.\n\n"
		.. "20% is a sensible starting point: enough that a cheap auction being taken "
		.. "between the scan and the trip does not stop the run, tight enough that a "
		.. "market which has genuinely moved does.")
	g.over = over

	local overPct = g:CreateFontString(nil, "ARTWORK")
	Font(overPct, 10, 0.7, 0.7, 0.7)
	overPct:SetPoint("BOTTOMLEFT", 762, 25)
	overPct:SetText("%")

	local count = g:CreateFontString(nil, "ARTWORK")
	Font(count, 11, 0.7, 0.7, 0.7)
	count:SetPoint("BOTTOMRIGHT", -18, 48)
	g.count = count

	--[[
		One page per profession, kept by id rather than in a single craftFrame.
		Everything that paints, shows or hides one looks it up here, so a third
		profession needs no change to any of them.
	]]
	self.craftFrames = self.craftFrames or {}
	self.craftFrames[m.id] = g
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

local function PaintRecipeDetail(g, p, name)
	local r = BS:Recipes(p)[name]
	if not r then
		g.detailTitle:SetText("|cff888888that recipe is no longer on the list|r")
		return {}, ""
	end

	local c = BS:CostRecipe(p, r)
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

-- The list is worked out once per repaint by the caller and handed in, because
-- the Buy the list button needs the same figures and this runs on every tick of
-- the scroll wheel. Two walks of every reagent per frame is one too many.
local function PaintShoppingList(g, p, buy, vendor, cost, exact)
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
		extras = format("  Plus %d %s off a vendor, not counted in that total.",
			n, n == 1 and p.vendorOne or p.vendorMany)
	end
	if banked > 0 then
		extras = extras .. format("  |cff777777%d of these you also have in the bank, "
			.. "not deducted.|r", banked)
	end

	return lines, format("What you are short after your bags. The bank is never "
		.. "deducted.%s", extras)
end

--[[
	Paint one profession's page, or every one of them.

	No argument means all, which is what nearly every call from outside this file
	wants: a scan finishing, an owner list arriving, a vendor correction - each of
	those changes the answer on every page at once, and none of those callers
	should have to know how many pages there are. A page that is not up returns on
	the second line, so painting all of them costs a table lookup each.
]]
function BS:RefreshCraft()
	for _, m in ipairs(BS.ModeOrder) do self:RefreshCraftPage(m) end
end

function BS:RefreshCraftPage(m)
	m = self:Mode(m)

	local g = self.craftFrames and self.craftFrames[m.id]
	if not g or not g:IsShown() then return end

	local p = self:ModeProf(m)
	if not p then return end

	g.titleFS:SetText(p.title)

	-- the page you are already on is not a place to go, same as the tabs
	for _, b in ipairs(g.profBtns or {}) do
		if b.prof == p then b:Disable() else b:Enable() end
	end

	--[[
		Painting moves focus off boxes whose row has changed hands, and losing
		focus commits, and committing asks for a repaint - so this can be called
		from inside itself. Re-entering half way through would paint rows from
		one list and the breakdown from another. Instead the inner call just
		notes that something moved, and the outer one goes round again once it
		has finished.

		The flag lives on the page rather than on the addon, so a repaint of one
		page cannot swallow the repaint of another.
	]]
	if g.painting then
		g.dirty = true
		return
	end
	g.painting = true

	--[[
		Painted from the last costing rather than costed afresh, because this
		also runs on every tick of the scroll wheel and the fallback price
		lookups reach into Auctionator. The costing is thrown away whenever
		something that feeds it moves - a scan, a harvest, a quantity, or the
		panel being opened - so it can never show figures older than the prices
		and bags behind them.
	]]
	local list, hidden = self:PageList(m)

	local offset = FauxScrollFrame_GetOffset(g.scroll) or 0
	for i = 1, CRAFT_ROWS do
		local row = g.rows[i]
		local c   = list[offset + i]
		if c then
			row.costed = c

			local picked = (g.view == "recipe" and g.pick == c.name)
			if picked then row.pick:Show() else row.pick:Hide() end

			--[[
				The recipe's name, in the tradeskill window's own colour for it:
				orange, yellow, green or grey. It is the thing the eye lands on,
				so it is the thing worth colouring.

				White when no difficulty has been recorded yet - which is not grey,
				and must not be allowed to look like it.
			]]
			local hex = BS.DiffHex(c.difficulty)
			row.cells[1]:SetText("|cff" .. (hex or "ffffff") .. c.name .. "|r")

			-- and the rest from the mode, however many columns it declared
			local vals = { m.cells(c) }
			for ci = 2, #row.cells do
				row.cells[ci]:SetText(vals[ci - 1] or "")
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
			row.pick:Hide()
			SetWantText(row.want, nil)
			row.want:Hide()
			row:Hide()
		end
	end
	FauxScrollFrame_Update(g.scroll, #list, CRAFT_ROWS, CRAFT_ROW_H)

	----------------------------------------------------------- breakdown --
	--[[
		One walk of the shopping list per repaint, shared by the breakdown below
		and by the Buy the list button at the bottom. Costing a reagent can fall
		through to Auctionator, and this runs on every notch of the scroll
		wheel, so the walk is done once and passed to both.
	]]
	local buyList, vendorList, listCost, listExact = self:ShoppingList(p)

	local lines, foot
	if g.view == "recipe" and g.pick then
		lines, foot = PaintRecipeDetail(g, p, g.pick)
	else
		lines, foot = PaintShoppingList(g, p, buyList, vendorList, listCost, listExact)
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

	if #list == 0 and hidden == 0 then
		g.count:SetText(format("|cffff8800no recipes - open your %s window|r", p.window))
	elseif #list == 0 then
		-- everything you can make is grey, which is worth saying outright rather
		-- than showing as an empty page with a tick box above it
		g.count:SetText(format("|cff808080all %d are too easy to level you|r", hidden))
	else
		g.count:SetText(format("%d recipe%s%s%s%s", #list, #list == 1 and "" or "s",
			exact < #list and format("  -  |cffff8800%d estimated|r", #list - exact) or "",
			planned > 0 and format("  -  |cffffd100%d planned|r", planned) or "",
			hidden > 0 and format("  -  |cff808080%d hidden|r", hidden) or ""))
	end

	---------------------------------------------------------- going shopping --
	if g.over then g.over.Refresh() end
	if g.levelCb then g.levelCb.Refresh() end

	--[[
		Lit only when pressing it would spend something, and when it is not, it
		says which of the reasons it is rather than going quietly grey - a dark
		button with the same words on it as a live one teaches you nothing, and
		the tooltip is the wrong place to find out that you are standing in the
		wrong building.

		The one case left clickable is the file being missing, because that is
		the only one where pressing it has something useful to tell you and no
		other way of telling you.
	]]
	if g.shopBtn then
		if not BS:HasShop() then
			g.shopBtn:SetText("Buy the list")
			g.shopBtn:Enable()
		elseif self.shopRun then
			g.shopBtn:SetText("shopping...")
			g.shopBtn:Disable()
		elseif not self.atAH then
			g.shopBtn:SetText("not at the AH")
			g.shopBtn:Disable()
		else
			local queue, est = self:ShopQueue(buyList)
			if #queue == 0 then
				g.shopBtn:SetText("nothing to buy")
				g.shopBtn:Disable()
			else
				g.shopBtn:SetText("Buy " .. BS.MoneyPlain(est))
				g.shopBtn:Enable()
			end
		end
	end

	g.painting = nil
	if g.dirty then
		g.dirty = nil
		self:RefreshCraftPage(m)
	end
end

--[[
	Switching pages.

	The crafting page is a frame filling the window on top of the auction side
	rather than a replacement for it, which keeps every widget exactly where it
	was built and means nothing has to be reparented or re-anchored. It is
	opaque, it takes the mouse, and it swallows the wheel, so what is underneath
	is neither visible nor reachable while it is up.
]]
function BS:SetTab(which)
	if not self.frame then return end
	self.tab = which

	local sp = self.sellFrame
	if sp then
		if which == "sell" then
			sp:SetFrameLevel(self.frame:GetFrameLevel() + 20)
			sp:Show()
		else
			sp:Hide()
		end
	end

	local bp = self.buyFrame
	if bp then
		if which == "buy" then
			bp:SetFrameLevel(self.frame:GetFrameLevel() + 20)
			bp:Show()
		else
			-- the recent list is a child that floats over the page, so leaving
			-- the page has to take it with us
			if bp.recent then bp.recent:Hide() end
			bp:Hide()
		end
	end

	--[[
		One page per profession, and only the one whose tab you are on comes up.

		The level is settled on the way up rather than at build time. The window is
		SetToplevel, so its level moves as you click between it and other windows,
		and a number worked out once can end up beneath the very children it was
		meant to cover.
	]]
	for _, m in ipairs(BS.ModeOrder) do
		local g = self.craftFrames and self.craftFrames[m.id]
		if g then
			if which == m.tab then
				g:SetFrameLevel(self.frame:GetFrameLevel() + 20)
				g:Show()
			else
				g:Hide()
			end
		end
	end

	-- the side panels belong to the auction page and have nowhere to sit on
	-- the other ones
	if which ~= "snipe" then
		if self.catFrame    then self.catFrame:Hide()    end
		if self.wishFrame   then self.wishFrame:Hide()   end
		if self.ledgerFrame then self.ledgerFrame:Hide() end
	end

	for _, t in ipairs(self.frame.tabs or {}) do
		if t.key == which then
			t:Disable()		-- the page you are on is not a place to go
		else
			t:Enable()
		end
	end

	self:UpdateUI()
end

--[[
	Open a crafting page, optionally on a named profession.

	Asking for a profession the mode does not offer is not an error worth
	stopping for - the page opens on whatever it was showing, which is the same
	thing that happens if you press the tab yourself.
]]
function BS:ShowCraft(m, p)
	if not self.frame then return end
	m = self:Mode(m)

	if p then
		for _, choice in ipairs(self:ProfsForMode(m)) do
			if choice == self:Prof(p) then self:SetModeProf(m, choice) break end
		end
	end

	self.frame:Show()
	if self.tab == m.tab then self:SetTab("snipe") else self:SetTab(m.tab) end
end

--=============================================================================
--  buying: the listings, the plan, and the other ways to buy it
--=============================================================================

local BUY_ROWS   = 9
local BUY_ROW_H  = 20
local PLAN_ROWS  = 7
local PLAN_ROW_H = 19

--[[
	Three lists, and each answers a different question.

	The top one is every listing, cheapest per item first. That is the whole of
	Auctionator's buy tab, and for "I want the cheap one" it is still the right
	answer, so it is the biggest thing on the page and you can buy straight off
	it.

	Bottom left is the plan: which auctions, and how many of each, add up to the
	number you asked for. Bottom right is what else that number could have been.
	They sit side by side because they are read against each other - the point
	of the right-hand list is the moment one of its lines is plainly better than
	the plan on the left, and that comparison should not need scrolling.
]]
function BS:BuildBuyUI(parent)
	local g = CreateFrame("Frame", "BidSniperBuyFrame", parent)
	g:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, -34)
	g:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -11, 10)
	g:EnableMouse(true)
	g:SetScript("OnMouseWheel", function() end)
	g:EnableMouseWheel(true)
	g:Hide()

	-- opaque, exactly as the other pages are, so nothing of the auction table
	-- can read as a ghost behind this one
	g:SetBackdrop({
		bgFile   = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = false, edgeSize = 14,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	g:SetBackdropColor(0.05, 0.05, 0.07, 1)
	g:SetBackdropBorderColor(0.35, 0.32, 0.25, 1)

	local sheet = g:CreateTexture(nil, "BACKGROUND")
	sheet:SetTexture(0.05, 0.05, 0.07, 1)
	sheet:SetAllPoints(g)

	g:SetScript("OnShow", function() BS:RefreshBuy() end)

	local title = g:CreateFontString(nil, "ARTWORK")
	Font(title, 12, 1, 0.82, 0)
	title:SetPoint("TOPLEFT", 18, -8)
	title:SetText("Buy")

	local help = g:CreateFontString(nil, "ARTWORK")
	Font(help, 10, 0.6, 0.6, 0.6)
	help:SetPoint("TOPLEFT", 18, -26)
	help:SetWidth(780)
	help:SetJustifyH("LEFT")
	help:SetText("Search an item and buy the cheapest per item, or say how many you "
		.. "want and let it work out which auctions together cost least. More items "
		.. "for the same gold or less always wins, so the other quantities worth "
		.. "having are listed beside the plan.")
	g.help = help

	--[[
		Where the help text is, and instead of it.

		A shopping run drives this page rather than replacing it, so everything
		below carries on meaning what it means - these are real listings and a
		real plan, for whichever reagent the run has reached. What changes is
		that you did not choose it, which is exactly the thing the page has to
		say out loud, and the standing instructions on how to search are the
		least useful two lines on screen while something else is searching for
		you.
	]]
	local shopLine = g:CreateFontString(nil, "ARTWORK")
	Font(shopLine, 10, 1, 0.82, 0)
	shopLine:SetPoint("TOPLEFT", 18, -26)
	shopLine:SetWidth(780)
	shopLine:SetJustifyH("LEFT")
	shopLine:Hide()
	g.shopLine = shopLine

	--------------------------------------------------------------- search --
	MakeLabel(g, "Item", 18, -62)
	local search = MakeEditBox(g, 18, -76, 240)
	search:SetMaxLetters(64)
	local function doSearch()
		search:ClearFocus()
		if g.recent then g.recent:Hide() end
		BS:BuyStartSearch(search:GetText())
	end
	search:SetScript("OnEnterPressed", doSearch)
	search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	Tip(search, "What to look for",
		"Type a name or paste an item link. Case does not matter.\n\n"
		.. "Searching again while one is still running replaces it, so you never have "
		.. "to wait for a search you have changed your mind about.\n\n"
		.. "The auction house matches on part of a name, but only the whole name is "
		.. "listed here - searching for Copper Bar will not fill the page with Copper "
		.. "Bar Racks. Type half a name and it says what it found instead.")
	g.search = search

	local searchBtn = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
	searchBtn:SetPoint("TOPLEFT", 266, -77)
	searchBtn:SetWidth(76)
	searchBtn:SetHeight(20)
	searchBtn:SetText("Search")
	searchBtn:SetScript("OnClick", doSearch)
	g.searchBtn = searchBtn

	local recentBtn = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
	recentBtn:SetPoint("TOPLEFT", 348, -77)
	recentBtn:SetWidth(72)
	recentBtn:SetHeight(20)
	recentBtn:SetText("Recent")
	Tip(recentBtn, "What you looked at last",
		"The last dozen searches, newest first. Click one to run it again.")

	--[[
		A list of my own rather than a dropdown. Blizzard's dropdown hangs
		named frames off whatever it is given as a parent, which is the one
		thing every widget in this file goes out of its way not to do, and a
		list of names in a box is not worth the exception.
	]]
	local recent = CreateFrame("Frame", nil, g)
	recent:SetPoint("TOPLEFT", 348, -98)
	recent:SetWidth(220)
	recent:SetHeight(20)		-- grows to the number of entries when it opens
	recent:SetBackdrop({
		bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	recent:SetBackdropColor(0.04, 0.04, 0.06, 0.98)
	recent:SetBackdropBorderColor(0.45, 0.45, 0.45, 1)
	recent:EnableMouse(true)
	recent:Hide()
	recent.rows = {}
	for i = 1, 12 do
		local b = CreateFrame("Button", nil, recent)
		b:SetPoint("TOPLEFT", 6, -4 - (i - 1) * 16)
		b:SetWidth(208)
		b:SetHeight(16)
		b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
		local fs = b:CreateFontString(nil, "ARTWORK")
		Font(fs, 11, 0.9, 0.9, 0.9)
		fs:SetPoint("LEFT", 2, 0)
		fs:SetWidth(204)
		fs:SetJustifyH("LEFT")
		b.text = fs
		b:SetScript("OnClick", function(self)
			if not self.name then return end
			recent:Hide()
			search:SetText(self.name)
			BS:BuyStartSearch(self.name)
		end)
		b:Hide()
		recent.rows[i] = b
	end
	g.recent = recent

	recentBtn:SetScript("OnClick", function()
		if recent:IsShown() then recent:Hide() return end
		-- settled on the way up, as the pages themselves are: the window is
		-- SetToplevel, so a level worked out at build time drifts
		recent:SetFrameLevel(g:GetFrameLevel() + 10)
		local list = BS:BuySettings().recent
		if #list == 0 then
			BS:Print("Nothing searched for yet.")
			return
		end
		for i, b in ipairs(recent.rows) do
			if list[i] then
				b.name = list[i]
				b.text:SetText(list[i])
				b:Show()
			else
				b.name = nil
				b:Hide()
			end
		end
		recent:SetHeight(8 + math.min(#list, 12) * 16)
		recent:Show()
	end)

	MakeLabel(g, "How many", 430, -62)
	local qty = MakeEditBox(g, 430, -76, 62)
	qty:SetNumeric(true)
	qty:SetMaxLetters(5)
	qty:SetJustifyH("CENTER")
	--[[
		Committed on every keystroke, so the plan answers as you type. The table
		behind it is worked out once per search rather than once per keystroke -
		it does not depend on the number you want, only on what is for sale - so
		typing a figure costs a lookup, not a recalculation.
	]]
	qty.Refresh = function()
		--[[
			While a shopping run is driving the page the number is the run's, and
			this box only reports it: it cannot be clicked into, so it cannot take
			focus, so it can never commit a figure of yours over the run's.

			The focus check below is why it has to be taken away rather than merely
			ignored. A focused box refuses to be repainted - which is right while
			you are typing into it - and a box left focused when a run started was
			still showing your last number and still committed it on the way out.
		]]
		local owned = BS.shopRun and true or false
		if owned then
			qty:ClearFocus()
			qty:EnableMouse(false)
			qty:SetTextColor(0.6, 0.6, 0.6)
		else
			qty:EnableMouse(true)
			qty:SetTextColor(1, 1, 1)
			if qty:HasFocus() then return end
		end

		qty.painting = true
		qty:SetText(tostring(BS:BuyTarget()))
		qty.painting = nil
	end
	local function commitQty()
		if qty.painting then return end
		-- a run owns the quantity while it is running; this box is showing it
		if BS.shopRun then return end
		local n = tonumber(qty:GetText()) or 0
		BS:BuySettings().qty = math.max(1, math.min(9999, n))
		BS:BuyReplan()
		BS:RefreshBuy()
	end
	qty:SetScript("OnTextChanged", commitQty)
	qty:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	qty:SetScript("OnEditFocusLost", commitQty)
	qty:SetScript("OnEscapePressed", function(self) qty.Refresh() self:ClearFocus() end)
	Tip(qty, "How many you want",
		"The plan below is the cheapest set of auctions that gets you at least this "
		.. "many. Leave it at 1 and it simply finds the cheapest single purchase.\n\n"
		.. "During a shopping run this shows what the run still needs of the reagent "
		.. "it is on, and greys out. Your own number is kept and comes back when the "
		.. "run ends.")
	g.qty = qty

	local bestBtn = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
	bestBtn:SetPoint("TOPLEFT", 502, -77)
	bestBtn:SetWidth(108)
	bestBtn:SetHeight(20)
	bestBtn:SetText("Best mix")
	bestBtn:SetScript("OnClick", function() BS:BuyReplan() BS:RefreshBuy() end)
	Tip(bestBtn, "Back to the worked-out plan",
		"Clicking a listing or one of the other quantities replaces the plan with "
		.. "that choice. This puts the cheapest way of reaching your number back.")

	local cbMine = MakeCheck(g, "Hide mine", 618, -62,
		function() return BS:BuySettings().hideOwn end,
		function(v)
			BS:BuySettings().hideOwn = v
			if BS.buy then BS:Print("Search again to apply that to the list.") end
		end,
		"Skip your own auctions",
		"Auctions posted by any of your characters. Buying your own back costs you "
		.. "the cut and gains you nothing.\n\nTakes effect on the next search.")

	local cbAll = MakeCheck(g, "Every option", 618, -84,
		function() return BS:BuySettings().allOptions end,
		function(v) BS:BuySettings().allOptions = v BS:RefreshBuy() end,
		"Show every quantity",
		"Off, the list on the right shows the quantities where the price per item "
		.. "actually drops - the points worth knowing about. On, it shows every "
		.. "quantity that is not beaten by a bigger one, which is a much longer "
		.. "list saying much the same thing.")

	local cbShift = MakeCheck(g, "Shift-click search", 618, -106,
		function() return BS:BuySettings().shiftSearch end,
		function(v) BS:BuySettings().shiftSearch = v end,
		"Shift-click an item to look it up",
		"Shift-click an item anywhere - your bags, a chat link, a loot window - and "
		.. "this page opens on it and searches, whichever tab you were on.\n\n"
		.. "It stays out of the way where shift-click already means something: away "
		.. "from the auction house, while you are typing in chat, and on rows that "
		.. "link an item into chat on purpose.")

	local summary = g:CreateFontString(nil, "ARTWORK")
	Font(summary, 11, 1, 1, 1)
	summary:SetPoint("TOPLEFT", 18, -106)
	-- stops short of the tick box on its right
	summary:SetWidth(590)
	summary:SetJustifyH("LEFT")
	g.summary = summary

	------------------------------------------------------- the listings --
	local band = g:CreateTexture(nil, "BACKGROUND")
	band:SetTexture(1, 1, 1, 0.06)
	band:SetPoint("TOPLEFT", 14, -126)
	band:SetWidth(788)
	band:SetHeight(20)

	local LIST_COLS = {
		{ "Per item", 2,   100, "RIGHT"  },
		{ "Stack",    106, 44,  "RIGHT"  },
		{ "Up",       154, 60,  "RIGHT"  },
		{ "Each",     218, 104, "RIGHT"  },
		{ "All of it",326, 110, "RIGHT"  },
		{ "Seller",   440, 120, "LEFT"   },
		{ "Left",     564, 44,  "CENTER" },
		{ "In plan",  612, 124, "RIGHT"  },
	}
	for _, h in ipairs(LIST_COLS) do
		local fs = g:CreateFontString(nil, "ARTWORK")
		Font(fs, 10, 0.8, 0.8, 0.8)
		fs:SetPoint("TOPLEFT", 18 + h[2], -130)
		fs:SetWidth(h[3])
		fs:SetJustifyH(h[4])
		fs:SetText(h[1])
	end

	local scroll = CreateFrame("ScrollFrame", "BidSniperBuyScroll", g, "FauxScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 18, -148)
	scroll:SetWidth(756)
	scroll:SetHeight(BUY_ROWS * BUY_ROW_H)
	scroll:SetScript("OnVerticalScroll", function(self, offset)
		FauxScrollFrame_OnVerticalScroll(self, offset, BUY_ROW_H, function() BS:RefreshBuy() end)
	end)
	g.scroll = scroll

	g.rows = {}
	for i = 1, BUY_ROWS do
		local row = CreateFrame("Button", nil, g)
		row:SetWidth(740)
		row:SetHeight(BUY_ROW_H)
		if i == 1 then
			row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
		else
			row:SetPoint("TOPLEFT", g.rows[i - 1], "BOTTOMLEFT", 0, 0)
		end
		row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
		row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

		-- banding tied to the slot rather than to the data, so the stripes stay
		-- still while the list scrolls under them
		if i % 2 == 0 then
			local stripe = row:CreateTexture(nil, "BACKGROUND")
			stripe:SetTexture(1, 1, 1, 0.035)
			stripe:SetAllPoints(row)
		end

		-- listings the plan is actually taking, marked on the listing itself
		row.pick = row:CreateTexture(nil, "BORDER")
		row.pick:SetTexture(0.2, 0.9, 0.2, 0.12)
		row.pick:SetAllPoints(row)
		row.pick:Hide()

		row.cells = {}
		for c, h in ipairs(LIST_COLS) do
			local fs = row:CreateFontString(nil, "ARTWORK")
			Font(fs, 11, 1, 1, 1)
			fs:SetPoint("LEFT", h[2], 0)
			fs:SetWidth(h[3])
			fs:SetJustifyH(h[4])
			row.cells[c] = fs
		end

		row:SetScript("OnClick", function(self, button)
			local o = self.offer
			if not o then return end
			-- the same three as the auctions table, so one habit works on both
			if IsShiftKeyDown() and o.link then
				BS:LinkToChat(o.link)
				return
			end
			if button == "RightButton" then
				-- the item itself, in the normal browse tab
				BS:SearchInBrowse({ name = o.name })
				return
			end
			BS:BuyOnly(o, IsControlKeyDown())
		end)

		row:SetScript("OnEnter", function(self)
			local o = self.offer
			if not o then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			if o.link then GameTooltip:SetHyperlink(o.link)
			else GameTooltip:SetText(o.name, 1, 1, 1) end
			GameTooltip:AddLine(" ")
			GameTooltip:AddDoubleLine("Price per item", BS.Money(o.unit), 0.8, 0.8, 0.8, 1, 1, 1)
			GameTooltip:AddDoubleLine("One stack of " .. o.count, BS.Money(o.buyout),
				0.8, 0.8, 0.8, 1, 1, 1)
			GameTooltip:AddDoubleLine(format("All %d of them (%d items)",
				o.qty, o.qty * o.count), BS.Money(o.qty * o.buyout), 0.8, 0.8, 0.8, 1, 1, 1)
			if o.manyOwners then
				GameTooltip:AddLine("Several sellers are asking exactly this.", 0.6, 0.6, 0.6, true)
			end
			if o.leading then
				GameTooltip:AddLine("You are the high bidder on one of these.", 1, 0.6, 0.2, true)
			end
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("Click to buy from this listing alone.", 0.5, 0.8, 1)
			GameTooltip:AddLine("Ctrl-click for every one of them.", 0.5, 0.8, 1)
			GameTooltip:AddLine("Shift-click to link it into chat.", 0.5, 0.8, 1)
			GameTooltip:AddLine("Right-click to look it up in Browse.", 0.5, 0.8, 1)
			GameTooltip:Show()
		end)
		row:SetScript("OnLeave", function() GameTooltip:Hide() end)

		row:Hide()
		g.rows[i] = row
	end

	--------------------------------------------------- the plan, and the rest --
	local planBand = g:CreateTexture(nil, "BACKGROUND")
	planBand:SetTexture(1, 1, 1, 0.06)
	planBand:SetPoint("TOPLEFT", 14, -336)
	planBand:SetWidth(388)
	planBand:SetHeight(20)

	local optBand = g:CreateTexture(nil, "BACKGROUND")
	optBand:SetTexture(1, 1, 1, 0.06)
	optBand:SetPoint("TOPLEFT", 410, -336)
	optBand:SetWidth(392)
	optBand:SetHeight(20)

	local planTitle = g:CreateFontString(nil, "ARTWORK")
	Font(planTitle, 10, 1, 0.82, 0)
	planTitle:SetPoint("TOPLEFT", 20, -340)
	planTitle:SetWidth(380)
	planTitle:SetJustifyH("LEFT")
	g.planTitle = planTitle

	local optTitle = g:CreateFontString(nil, "ARTWORK")
	Font(optTitle, 10, 1, 0.82, 0)
	optTitle:SetPoint("TOPLEFT", 416, -340)
	optTitle:SetWidth(384)
	optTitle:SetJustifyH("LEFT")
	optTitle:SetText("Other ways to buy it")
	g.optTitle = optTitle

	local PLAN_COLS = {
		{ 2,   124, "LEFT"  },
		{ 128, 90,  "RIGHT" },
		{ 222, 46,  "RIGHT" },
		{ 272, 100, "RIGHT" },
	}
	g.planRows = {}
	for i = 1, PLAN_ROWS do
		local row = CreateFrame("Frame", nil, g)
		row:SetWidth(376)
		row:SetHeight(PLAN_ROW_H)
		row:SetPoint("TOPLEFT", 18, -358 - (i - 1) * PLAN_ROW_H)
		row.cells = {}
		for c, l in ipairs(PLAN_COLS) do
			local fs = row:CreateFontString(nil, "ARTWORK")
			Font(fs, 11, 1, 1, 1)
			fs:SetPoint("LEFT", l[1], 0)
			fs:SetWidth(l[2])
			fs:SetJustifyH(l[3])
			row.cells[c] = fs
		end
		row:Hide()
		g.planRows[i] = row
	end

	local optScroll = CreateFrame("ScrollFrame", "BidSniperBuyOptScroll", g, "FauxScrollFrameTemplate")
	optScroll:SetPoint("TOPLEFT", 414, -358)
	optScroll:SetWidth(360)
	optScroll:SetHeight(PLAN_ROWS * PLAN_ROW_H)
	optScroll:SetScript("OnVerticalScroll", function(self, offset)
		FauxScrollFrame_OnVerticalScroll(self, offset, PLAN_ROW_H, function() BS:RefreshBuy() end)
	end)
	g.optScroll = optScroll

	local OPT_COLS = {
		{ 2,   54,  "RIGHT" },
		{ 60,  104, "RIGHT" },
		{ 168, 100, "RIGHT" },
		{ 272, 100, "RIGHT" },
	}
	g.optRows = {}
	for i = 1, PLAN_ROWS do
		local row = CreateFrame("Button", nil, g)
		row:SetWidth(360)
		row:SetHeight(PLAN_ROW_H)
		if i == 1 then
			row:SetPoint("TOPLEFT", optScroll, "TOPLEFT", 0, 0)
		else
			row:SetPoint("TOPLEFT", g.optRows[i - 1], "BOTTOMLEFT", 0, 0)
		end
		row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")

		row.pick = row:CreateTexture(nil, "BORDER")
		row.pick:SetTexture(1, 0.82, 0, 0.14)
		row.pick:SetAllPoints(row)
		row.pick:Hide()

		row.cells = {}
		for c, l in ipairs(OPT_COLS) do
			local fs = row:CreateFontString(nil, "ARTWORK")
			Font(fs, 11, 1, 1, 1)
			fs:SetPoint("LEFT", l[1], 0)
			fs:SetWidth(l[2])
			fs:SetJustifyH(l[3])
			row.cells[c] = fs
		end

		row:SetScript("OnClick", function(self)
			if self.option then BS:BuyChoose(self.option) end
		end)
		row:SetScript("OnEnter", function(self)
			local o = self.option
			if not o then return end
			local plan = BS.buyPlan
			GameTooltip:SetOwner(self, "ANCHOR_LEFT")
			GameTooltip:AddLine(format("%s items for %s", BS.Comma(o.n), BS.Money(o.cost)), 1, 1, 1)
			GameTooltip:AddDoubleLine("Per item", BS.Money(o.unit), 0.8, 0.8, 0.8, 1, 1, 1)
			if plan and plan.qty > 0 and o.n ~= plan.qty then
				GameTooltip:AddLine(" ")
				local dq, dc = o.n - plan.qty, o.cost - plan.cost
				GameTooltip:AddDoubleLine(dq > 0 and "More items" or "Fewer items",
					format("%+d", dq), 0.8, 0.8, 0.8, 1, 1, 1)
				GameTooltip:AddDoubleLine(dc >= 0 and "More gold" or "Less gold",
					(dc >= 0 and "+" or "-") .. BS.MoneyPlain(math.abs(dc)),
					0.8, 0.8, 0.8, 1, 1, 1)
				if dq > 0 and dc <= 0 then
					GameTooltip:AddLine("More of them for no more money. Take this one.",
						0.2, 1, 0.2, true)
				end
			end
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("Click to plan this instead.", 0.5, 0.8, 1)
			GameTooltip:Show()
		end)
		row:SetScript("OnLeave", function() GameTooltip:Hide() end)

		row:Hide()
		g.optRows[i] = row
	end

	--------------------------------------------------------------- footer --
	local foot = g:CreateFontString(nil, "ARTWORK")
	Font(foot, 10, 0.7, 0.7, 0.7)
	foot:SetPoint("TOPLEFT", 18, -496)
	foot:SetWidth(780)
	foot:SetJustifyH("LEFT")
	g.foot = foot

	local status = g:CreateFontString(nil, "ARTWORK")
	Font(status, 11, 1, 1, 1)
	status:SetPoint("BOTTOMLEFT", 18, 22)
	status:SetWidth(500)
	status:SetJustifyH("LEFT")
	g.status = status

	--[[
		The one line that says, in words, which of the states the button below
		it is in. Directly above it and right-aligned to it, so the two read as
		one thing rather than as a caption that might belong to something else.
	]]
	local state = g:CreateFontString(nil, "ARTWORK")
	Font(state, 11, 1, 1, 1)
	state:SetPoint("BOTTOMRIGHT", -18, 46)
	state:SetWidth(420)
	state:SetJustifyH("RIGHT")
	g.state = state

	-- The purchase happens in this OnClick and nowhere else. PlaceAuctionBid is
	-- protected, so the client only honours it while handling a real click.
	local buyBtn = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
	buyBtn:SetPoint("BOTTOMRIGHT", -18, 18)
	buyBtn:SetWidth(170)
	buyBtn:SetHeight(24)
	buyBtn:SetScript("OnClick", function()
		if BS.buyRun and BS.buyRun.stage == "ready" then
			BS:FireArmedBuy()
		else
			BS:BuyStart()
		end
	end)
	Tip(buyBtn, "Buy the plan",
		"WoW only lets an addon buy while you are actually clicking, so this is a "
		.. "press per page of results rather than a press per auction: everything on "
		.. "the page the plan wants goes in one press, and the button says what that "
		.. "costs before you press it.\n\nIt never spends more than the total you "
		.. "approved, and stops if the gold runs out.\n\n"
		.. "|cffff7020Orange|r means this press spends the figure on it. "
		.. "|cff40ff40Green|r means it is finished and the button is dead - buying "
		.. "again takes a deliberate press of Best mix, so a habit of clicking cannot "
		.. "buy a second load.")
	g.buyBtn = buyBtn

	--[[
		Stop means stop the whole errand, not this leg of it.

		During a shopping run the thing you want to abandon is the run - if Stop
		only ended the purchase on screen, the next reagent would start
		searching a second later and pressing it would look broken. Skip, next
		to it, is the one that means this reagent and no more.
	]]
	local stopBtn = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
	stopBtn:SetPoint("BOTTOMRIGHT", -194, 18)
	stopBtn:SetWidth(80)
	stopBtn:SetHeight(24)
	stopBtn:SetText("Stop")
	stopBtn:SetScript("OnClick", function()
		if BS.shopRun then
			BS:ShopStop("Shopping stopped.")
		elseif BS.buyRun then
			BS:BuyStop("Buying stopped.")
		else
			-- a search walking through pages, and nothing bought to undo
			BS:BuyCancelSearch("Search stopped.")
		end
	end)
	Tip(stopBtn, "Stop",
		"While a search is running, stops it where it is. You do not have to wait "
		.. "for it - clicking another item stops it too, and looks that one up "
		.. "instead.\n\n"
		.. "While buying, nothing already bought comes back.\n\n"
		.. "During a shopping run this ends the run, not just the reagent on screen, "
		.. "and prints what it managed to buy.")
	stopBtn:Hide()
	g.stopBtn = stopBtn

	local skipBtn = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
	skipBtn:SetPoint("BOTTOMRIGHT", -280, 18)
	skipBtn:SetWidth(80)
	skipBtn:SetHeight(24)
	skipBtn:SetText("Skip")
	skipBtn:SetScript("OnClick", function() BS:ShopSkip() end)
	Tip(skipBtn, "Leave this reagent",
		"Moves the shopping run on to the next thing on the list without buying this "
		.. "one. Anything already bought for it stays bought, and the reason shows up "
		.. "as 'you skipped it' in the report at the end.")
	skipBtn:Hide()
	g.skipBtn = skipBtn

	g.refreshers = { qty, cbMine, cbAll, cbShift }
	self.buyFrame = g
end

--[[
	Painting the page.

	Everything here is read off self.buy and self.buyPlan, which are worked out
	elsewhere; this only decides how it looks. The one piece of thinking it does
	is the colour on the options list, and that is the whole point of the list:
	a quantity handing you more for no more gold is marked green, because that
	is a mistake you should not be able to make on this page.
]]
function BS:RefreshBuy()
	local g = self.buyFrame
	if not g or not g:IsShown() then return end

	-- painting writes into the boxes, and a box being written to asks for a
	-- repaint; the other pages guard this the same way
	if self.buyPainting then
		self.buyDirty = true
		return
	end
	self.buyPainting = true

	for _, w in ipairs(g.refreshers) do if w.Refresh then w.Refresh() end end

	local buy    = self.buy
	local plan   = self.buyPlan
	local offers = buy and buy.offers or {}

	------------------------------------------------------------- summary --
	if self.buySearch then
		g.summary:SetText("|cffffd100Searching...|r")
	elseif not buy then
		g.summary:SetText("|cff888888Search for something to buy.|r")
	else
		local notes = {}
		if buy.noBuyout > 0 then
			notes[#notes + 1] = format("%d bid-only", buy.noBuyout)
		end
		if buy.mine > 0 then
			notes[#notes + 1] = format("%d yours", buy.mine)
		end
		if buy.truncated then
			notes[#notes + 1] = "|cffff8800only the first 1000 read|r"
		end
		g.summary:SetText(format("%s  -  |cffffffff%s|r for sale in %d listing%s%s%s",
			buy.link or buy.name, BS.Comma(buy.total), buy.listings,
			buy.listings == 1 and "" or "s",
			#offers > 0 and format(", cheapest |cffffffff%s|r each",
				BS.Money(offers[1].unit)) or "",
			#notes > 0 and ("   |cff888888(" .. table.concat(notes, ", ") .. ")|r") or ""))
	end

	------------------------------------------------------------ listings --
	-- which listings the plan is taking, so the top list can show it
	local taking = {}
	if plan then
		for _, line in ipairs(plan.lines) do taking[line.offer] = line.take end
	end

	local offset = FauxScrollFrame_GetOffset(g.scroll) or 0
	for i = 1, BUY_ROWS do
		local row = g.rows[i]
		local o   = offers[offset + i]
		if o then
			row.offer = o
			local take = taking[o]
			row.cells[1]:SetText(BS.Money(o.unit))
			row.cells[2]:SetText("x" .. o.count)
			row.cells[3]:SetText(tostring(o.qty))
			row.cells[4]:SetText(BS.Money(o.buyout))
			row.cells[5]:SetText(o.qty > 1 and BS.Money(o.qty * o.buyout) or "|cff666666-|r")
			row.cells[6]:SetText(o.manyOwners and "|cff888888several|r"
				or (o.owner or "|cff666666?|r"))
			row.cells[7]:SetText(BS.timeLeftText[o.timeLeft] or "?")
			row.cells[8]:SetText(take and format("|cff00ff00%d of %d|r", take, o.qty) or "")
			if take then row.pick:Show() else row.pick:Hide() end
			row:Show()
		else
			row.offer = nil
			row:Hide()
		end
	end
	FauxScrollFrame_Update(g.scroll, #offers, BUY_ROWS, BUY_ROW_H)

	---------------------------------------------------------------- plan --
	if not plan then
		g.planTitle:SetText("What to buy")
	elseif plan.source == "listing" then
		g.planTitle:SetText(format("What to buy  |cff888888- from one listing, %s for %s|r",
			BS.Comma(plan.qty), BS.MoneyPlain(plan.cost)))
	elseif plan.source == "option" then
		g.planTitle:SetText(format("What to buy  |cff888888- %s for %s, %s each|r",
			BS.Comma(plan.qty), BS.MoneyPlain(plan.cost), BS.MoneyPlain(plan.unit)))
	else
		-- when the cheapest way past your number goes well past it, saying so
		-- here is the difference between a surprise and a decision
		g.planTitle:SetText(format("What to buy  |cff888888- cheapest way to %s%s|r",
			BS.Comma(plan.target),
			plan.qty > plan.target
				and format(", which brings %s", BS.Comma(plan.qty)) or ""))
	end

	local lines = plan and plan.lines or {}
	for i = 1, PLAN_ROWS do
		local row  = g.planRows[i]
		local last = (i == PLAN_ROWS) and #lines > PLAN_ROWS
		local line = (not last) and lines[i] or nil
		if line then
			local o = line.offer
			row.cells[1]:SetText(o.count > 1
				and format("%d x |cffaaaaaastack of %d|r", line.take, o.count)
				or  format("%d x |cffaaaaaasingle|r", line.take))
			row.cells[2]:SetText(BS.Money(o.buyout))
			row.cells[3]:SetText(tostring(line.items))
			row.cells[4]:SetText(BS.Money(line.cost))
			row:Show()
		elseif last then
			row.cells[1]:SetText(format("|cff888888and %d more...|r", #lines - PLAN_ROWS + 1))
			row.cells[2]:SetText("")
			row.cells[3]:SetText("")
			row.cells[4]:SetText("")
			row:Show()
		else
			row:Hide()
		end
	end

	------------------------------------------------------------- options --
	local options, bestN = self:BuyOptionRows()
	local oOffset  = FauxScrollFrame_GetOffset(g.optScroll) or 0
	local hereUnit = plan and plan.unit or 0
	local target   = plan and plan.target or 0

	--[[
		The heading says what the list is a list of, because that was the thing
		that was unclear. Every row reaches your number and every row past the
		first is better value per item - so when there is only the first, the
		honest answer is that overshooting buys you nothing here, and saying so
		beats a list with one line in it and no explanation.
	]]
	local better = false
	for i = 2, #options do
		if options[i].unit < options[1].unit then better = true break end
	end

	if not plan then
		g.optTitle:SetText("Other ways to buy it")
	elseif not bestN then
		g.optTitle:SetText(format("Other ways to buy it  |cffff8800- not enough "
			.. "for %s|r", BS.Comma(target)))
	elseif better then
		g.optTitle:SetText(format("Other ways to get |cffffffff%s|r or more",
			BS.Comma(target)))
	else
		g.optTitle:SetText(format("Other ways to get %s  |cff888888- buying more "
			.. "is no better value|r", BS.Comma(target)))
	end

	for i = 1, PLAN_ROWS do
		local row = g.optRows[i]
		local o   = options[oOffset + i]
		if o then
			row.option = o
			local here = plan and o.n == plan.qty and o.cost == plan.cost

			--[[
				The comparison the page is for. Green means this hands you more
				than the plan does for the same gold or less - the deal you would
				have missed. Otherwise say what the price per item does, since
				that is what makes overshooting worth it.

				"cheapest" marks the worked-out answer for your number. It used
				to vanish from the list the moment you picked something else,
				which left no way back to it but the button.
			]]
			local note, colour
			if here then
				note, colour = "|cffffd100this one|r", "|cffffd100"
			elseif plan and o.n > plan.qty and o.cost <= plan.cost then
				note, colour = "|cff00ff00more, for less|r", "|cff00ff00"
			elseif bestN and o.n == bestN then
				note, colour = "|cffffd100cheapest|r", "|cffffffff"
			elseif not bestN then
				note, colour = "|cffff8800all there is|r", "|cffff8800"
			else
				--[[
					A percentage that rounds to nothing is worse than no
					percentage: "0% cheaper each" reads as a difference and is
					the absence of one. Below half a point, say so in words.
				]]
				local pct = (hereUnit > 0) and ((o.unit / hereUnit - 1) * 100) or 0
				if pct < -0.5 then
					note, colour = format("|cff00ff00%.0f%% cheaper each|r", -pct),
						"|cffffffff"
				elseif pct > 0.5 then
					note, colour = format("|cffff8800%.0f%% dearer each|r", pct),
						"|cff888888"
				else
					note, colour = "|cff888888same value|r", "|cff888888"
				end
			end

			row.cells[1]:SetText(colour .. BS.Comma(o.n) .. "|r")
			row.cells[2]:SetText(BS.Money(o.cost))
			row.cells[3]:SetText(BS.Money(o.unit))
			row.cells[4]:SetText(note)
			if here then row.pick:Show() else row.pick:Hide() end
			row:Show()
		else
			row.option = nil
			row:Hide()
		end
	end
	FauxScrollFrame_Update(g.optScroll, #options, PLAN_ROWS, PLAN_ROW_H)

	---------------------------------------------------------------- foot --
	local foot = ""
	if plan and plan.short then
		foot = format("|cffff8800Only %s for sale - the plan takes the lot.|r  ",
			BS.Comma(buy.total))
	end
	if plan then
		foot = foot .. format("This plan: |cffffffff%s|r items for |cffffffff%s|r, "
			.. "|cffffffff%s|r each.", BS.Comma(plan.qty), BS.Money(plan.cost),
			BS.Money(plan.unit))
		if self.buyDP and self.buyDP.capped then
			foot = foot .. "   |cff888888(options listed up to "
				.. BS.Comma(self.buyDP.maxq) .. ")|r"
		end
	elseif buy then
		foot = "Nothing to buy here."
	end
	g.foot:SetText(foot)

	---------------------------------------------------- the shopping run --
	--[[
		Painted before the buttons, because what the run is doing decides what
		the buttons are allowed to say. A run mid-search has no plan yet, and a
		Buy button offering the last reagent's plan while the banner names the
		next one is the page contradicting itself.
	]]
	local shopping = self.shopRun and self.ShopStatus and self:ShopStatus() or nil
	if shopping then
		g.shopLine:SetText(shopping)
		g.shopLine:Show()
		g.help:Hide()
	else
		g.shopLine:Hide()
		g.help:Show()
	end

	------------------------------------------------------------- buttons --
	--[[
		The button and the line above it are set together, in one place, from
		one decision. They are the only thing standing between a habit of
		clicking and a second load of everything, and two separate opinions
		about which state we are in is exactly how that guard goes quiet.
	]]
	local run  = self.buyRun
	local done = self.buyDone

	if run and run.stage == "ready" then
		--[[
			The only state that spends. It names the figure this single press
			commits - not the plan total, which may take several presses - so
			that what the button says and what leaves your bags are the same
			number every time.
		]]
		g.buyBtn:SetText(ArmedText("BUY", BS.MoneyPlain(run.pageCost)))
		g.buyBtn:Enable()
		g.state:SetText(format("%sReady to buy.|r This press spends |cffffffff%s|r "
			.. "-  %s of %s bought so far.", ARMED_COLOUR, BS.Money(run.pageCost),
			BS.Comma(run.got), BS.Comma(run.items)))

	elseif run then
		g.buyBtn:SetText(BusyText("finding..."))
		g.buyBtn:Disable()
		g.state:SetText(BusyText("Finding the auctions - nothing is being bought "
			.. "this moment."))

	elseif self.shopRun then
		--[[
			Nothing to press. Either the run is still looking at the list, in
			which case buying has not started and saying "Buy" would be a lie
			about what is happening, or it is between reagents and the plan on
			screen is there by accident of when the paint landed rather than
			because it is the one the next press would buy.
		]]
		local surveying = (self.shopRun.phase == "survey")
		g.buyBtn:SetText(BusyText(surveying and "checking..." or "searching..."))
		g.buyBtn:Disable()
		g.state:SetText(BusyText(surveying
			and "Checking what is for sale. Nothing is being bought yet."
			or  "Looking up the next reagent."))

	elseif done then
		--[[
			Finished, and the button is dead until you ask for another one. This
			is the state the page never used to have: it went straight back to
			offering a fresh purchase, which is how you buy twice.
		]]
		g.buyBtn:SetText(DoneText(done.shop and "Run finished"
			or ("Bought " .. BS.Comma(done.qty))))
		g.buyBtn:Disable()

		if done.shop then
			g.state:SetText(format("%sShopping run finished - %s items across %d "
				.. "reagent%s for %s.|r%s", DONE_COLOUR, BS.Comma(done.qty),
				done.reagents, done.reagents == 1 and "" or "s", BS.Money(done.cost),
				done.capped > 0 and "  |cffff8800Some recipes were cut back - see "
					.. "chat.|r" or ""))
		else
			g.state:SetText(format("%sDone - bought %s %s for %s.|r  Press "
				.. "|cffffffffBest mix|r to plan another.", DONE_COLOUR,
				BS.Comma(done.qty), done.name, BS.Money(done.cost)))
		end

	elseif plan and #plan.lines > 0 then
		g.buyBtn:SetText("Buy " .. BS.Comma(plan.qty) .. " for " .. BS.MoneyPlain(plan.cost))
		g.buyBtn:Enable()
		g.state:SetText(format("|cff888888Nothing bought yet.|r Starts a purchase of "
			.. "|cffffffff%s|r for |cffffffff%s|r, one press per page.",
			BS.Comma(plan.qty), BS.Money(plan.cost)))

	else
		g.buyBtn:SetText("Buy")
		g.buyBtn:Disable()
		g.state:SetText("")
	end

	-- a search walking through pages is a thing worth being able to stop,
	-- so the button is there for that too and not only for buying
	if run or self.shopRun or self.buySearch then
		g.stopBtn:Show()
	else
		g.stopBtn:Hide()
	end
	if self.shopRun then g.skipBtn:Show() else g.skipBtn:Hide() end

	self.buyPainting = nil
	if self.buyDirty then
		self.buyDirty = nil
		self:RefreshBuy()
	end
end

function BS:ShowBuy()
	if not self.frame then return end
	self.frame:Show()
	if self.tab == "buy" then self:SetTab("snipe") else self:SetTab("buy") end
end

--=============================================================================
--  emptying a patch of your bags onto the auction house
--=============================================================================

local SELL_ROWS  = 13
local SELL_ROW_H = 20

--[[
	A staging area you empty in one pass.

	The range is in slot numbers rather than rows because rows are a drawing
	detail - bag frames differ, and addons redraw them - whereas slot 1 is
	always the top left. The list below the settings shows exactly what falls
	inside the range, so "the first two rows" is whatever you can see listed.
]]
function BS:BuildSellUI(parent)
	local g = CreateFrame("Frame", "BidSniperSellFrame", parent)
	g:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, -34)
	g:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -11, 10)
	g:EnableMouse(true)

	--[[
		The wheel scrolls the list rather than being swallowed.

		Every other page here catches the wheel and does nothing with it, purely
		so it cannot fall through to the auction house frame behind and scroll
		that instead. This page is one you work down, changing a number on row
		after row, so the wheel is worth wiring to the thing it looks like it
		should move. Anywhere over the panel, not only over the rows: hunting
		for the strip that accepts a wheel is its own small annoyance.

		Three rows a notch, and the scrollbar clamps its own value, so the ends
		need no arithmetic here.
	]]
	g:SetScript("OnMouseWheel", function(self, delta)
		local bar = _G["BidSniperSellScrollScrollBar"]
		if not bar then return end
		bar:SetValue(bar:GetValue() - (delta or 0) * SELL_ROW_H * 3)
	end)
	g:EnableMouseWheel(true)
	g:Hide()

	g:SetBackdrop({
		bgFile   = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = false, edgeSize = 14,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	g:SetBackdropColor(0.05, 0.05, 0.07, 1)
	g:SetBackdropBorderColor(0.35, 0.32, 0.25, 1)

	local sheet = g:CreateTexture(nil, "BACKGROUND")
	sheet:SetTexture(0.05, 0.05, 0.07, 1)
	sheet:SetAllPoints(g)

	g:SetScript("OnShow", function() BS:RefreshSell() end)

	local title = g:CreateFontString(nil, "ARTWORK")
	Font(title, 12, 1, 0.82, 0)
	title:SetPoint("TOPLEFT", 18, -8)
	title:SetText("Sell from your bags")

	local help = g:CreateFontString(nil, "ARTWORK")
	Font(help, 10, 0.6, 0.6, 0.6)
	help:SetPoint("TOPLEFT", 18, -28)
	help:SetWidth(780)
	help:SetJustifyH("LEFT")
	help:SetText("Tick the bags you stage things in - they count as one run of space, "
		.. "with From slot cutting into the first and To slot stopping part way through "
		.. "the last. The first press searches the auction "
		.. "house for every item, throws out any giveaway listings sitting under the "
		.. "real market, and prices against what is left - then posting is one press "
		.. "per lot. Per lot is how many go in one auction, saved against that item: "
		.. "23 in lots of 4 is five auctions of 4 and a last one of 3.")

	------------------------------------------------------------- settings --
	local function NumBox(label, x, width, get, set, tip, tipBody)
		local fs = g:CreateFontString(nil, "ARTWORK")
		Font(fs, 10, 0.8, 0.8, 0.8)
		fs:SetPoint("TOPLEFT", x, -62)
		fs:SetText(label)

		local eb = MakeEditBox(g, x, -76, width)
		eb:SetNumeric(true)
		eb:SetAutoFocus(false)

		--[[
			Committed on every keystroke, so the list below answers as you type
			rather than when you finally press enter. `painting` marks the
			addon writing the saved value back, so restoring a number does not
			read as somebody typing it and set off another round.
		]]
		eb.Refresh = function()
			if eb:HasFocus() then return end
			eb.painting = true
			eb:SetText(tostring(get() or 0))
			eb.painting = nil
		end
		local function commit()
			if eb.painting then return end
			set(tonumber(eb:GetText()) or 0)
			BS:RefreshSell()
		end
		eb:SetScript("OnTextChanged", commit)
		eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
		eb:SetScript("OnEditFocusLost", commit)
		if tip then Tip(eb, tip, tipBody) end
		return eb
	end

	--[[
		Tick as many bags as you like. The slot range below applies inside each
		one, so two rows of the backpack and the whole of your last bag is two
		ticks and a range of 1 to 0.
	]]
	local bagLabel = g:CreateFontString(nil, "ARTWORK")
	Font(bagLabel, 10, 0.8, 0.8, 0.8)
	bagLabel:SetPoint("TOPLEFT", 18, -62)
	bagLabel:SetText("Bags to sell from")

	g.bagChecks = {}
	for bag = 0, 4 do
		local cb = CreateFrame("CheckButton", nil, g, "UICheckButtonTemplate")
		cb:SetWidth(20)
		cb:SetHeight(20)
		cb:SetPoint("TOPLEFT", 18 + bag * 74, -78)
		cb:SetScript("OnClick", function() BS:ToggleSellBag(bag) end)

		local fs = g:CreateFontString(nil, "ARTWORK")
		Font(fs, 10, 0.9, 0.9, 0.9)
		fs:SetPoint("LEFT", cb, "RIGHT", 1, 0)
		fs:SetWidth(52)
		fs:SetJustifyH("LEFT")
		cb.label = fs

		cb.bag = bag
		Tip(cb, (bag == 0) and "Your backpack" or ("Bag " .. bag),
			"Tick every bag you want emptied. The ticked bags are one run of space: "
			.. "From slot cuts into the first, To slot stops part way through the "
			.. "last, and anything between them is taken whole.\n\n"
			.. "Bags are numbered left to right along the bar.")
		g.bagChecks[bag] = cb
	end

	local s = BS:SellSettings()
	g.boxes = {}
	g.boxes[1] = NumBox("From slot", 400, 46,
		function() return BS:SellSettings().fromSlot end,
		function(v) BS:SellSettings().fromSlot = math.max(1, v) end,
		"Where the run starts", "Slots count left to right, top to bottom, so slot 1 "
		.. "is the top left of the bag.\n\n"
		.. "This cuts into the FIRST ticked bag only. Any bag after it is taken whole.")
	g.boxes[2] = NumBox("To slot (0 = end)", 458, 46,
		function() return BS:SellSettings().toSlot end,
		function(v) BS:SellSettings().toSlot = math.max(0, v) end,
		"Where the run ends", "This stops part way through the LAST ticked bag only. "
		.. "Everything before it is taken whole.\n\n"
		.. "For a four-wide bag, the first two rows are slots 1 to 8. 0 means carry "
		.. "on to the end.\n\n"
		.. "Tick one bag and both numbers land on it, which is the ordinary case.")
	g.boxes[3] = NumBox("Undercut %", 542, 46,
		function() return BS:SellSettings().undercut end,
		function(v) BS:SellSettings().undercut = math.max(0, math.min(90, v)) end,
		"How far under the lowest", "Auctionator holds the cheapest price its last scan "
		.. "saw, and that is the price this goes under. Left at 0 you post one copper "
		.. "below the cheapest listing, which is what undercutting means. Raise it only "
		.. "to go in deliberately cheaper. It never matches the lowest exactly, which "
		.. "would leave you behind that auction in the sort order.")
	g.boxes[4] = NumBox("Opening bid %", 600, 46,
		function() return BS:SellSettings().bidPct end,
		function(v) BS:SellSettings().bidPct = math.max(1, math.min(100, v)) end,
		"Opening bid", "The starting bid, as a percentage of the buyout.")

	local durBtn = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
	durBtn:SetPoint("TOPLEFT", 658, -76)
	durBtn:SetWidth(96)
	durBtn:SetHeight(20)
	durBtn:SetScript("OnClick", function()
		local sc = BS:SellSettings()
		sc.duration = (sc.duration % 3) + 1
		BS:RefreshSell()
	end)
	Tip(durBtn, "How long to list for",
		"Click to cycle 12, 24 and 48 hours. A longer listing costs a bigger deposit.")
	g.durBtn = durBtn

	local refreshBtn = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
	refreshBtn:SetPoint("TOPLEFT", 100, -104)
	refreshBtn:SetWidth(90)
	refreshBtn:SetHeight(20)
	refreshBtn:SetText("Refresh")
	--[[
		Also the way to force a fresh look at the market.

		Prices stand for an hour, which is right almost always and wrong exactly
		when something has just moved - a competitor undercutting the wall, or a
		giveaway being bought out from under the figure we are pricing off. This
		is the button you already reach for when the page looks out of date, so
		it is the one that should throw the quotes away too.
	]]
	refreshBtn:SetScript("OnClick", function()
		BS:SellForgetQuotes()
		BS:RefreshSell()
	end)
	Tip(refreshBtn, "Read the bag again",
		"After moving things about.\n\nAlso forgets what the auction house said "
		.. "things were going for, so the next press checks again rather than "
		.. "standing on prices from up to an hour ago.")

	------------------------------------------------------------- the list --
	--[[
		One line per item now, not per stack as it happens to sit in the bag.
		Per lot is the box in the middle: how many of that item go in one
		auction. What follows it is the shape that makes - "5 x 4 + 3" is five
		auctions of four and a last one of three - and then what a full lot
		fetches and what the whole heap is worth.
	]]
	local heads = { { "What", 2, 286, "LEFT" }, { "Per lot", 296, 50, "LEFT" },
	                { "Auctions", 350, 76, "RIGHT" },
	                { "Each", 434, 116, "RIGHT" }, { "Total", 558, 116, "RIGHT" } }
	for _, h in ipairs(heads) do
		local fs = g:CreateFontString(nil, "ARTWORK")
		Font(fs, 10, 0.8, 0.8, 0.8)
		fs:SetPoint("TOPLEFT", 18 + h[2], -136)
		fs:SetWidth(h[3])
		fs:SetJustifyH(h[4])
		fs:SetText(h[1])
	end

	local band = g:CreateTexture(nil, "BACKGROUND")
	band:SetTexture(1, 1, 1, 0.06)
	band:SetPoint("TOPLEFT", 14, -132)
	band:SetWidth(788)
	band:SetHeight(20)

	--[[
		Scrolled, because a bag holds far more distinct things than thirteen and
		every one of them has a number on it you may want to change. A list that
		showed the first thirteen was not a shortened list, it was a list you
		could not reach the bottom of - and the lot sizes down there are exactly
		the ones you would not find out about until they had gone up wrong.

		Same faux-scroll the crafting pages use: thirteen frames that are
		repainted as the offset moves, rather than one frame per item.
	]]
	local scroll = CreateFrame("ScrollFrame", "BidSniperSellScroll", g,
		"FauxScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 18, -154)
	scroll:SetWidth(756)
	scroll:SetHeight(SELL_ROWS * SELL_ROW_H)
	scroll:SetScript("OnVerticalScroll", function(self, offset)
		FauxScrollFrame_OnVerticalScroll(self, offset, SELL_ROW_H,
			function() BS:RefreshSell() end)
	end)
	g.scroll = scroll

	g.rows = {}
	for i = 1, SELL_ROWS do
		local row = CreateFrame("Frame", nil, g)
		row:SetWidth(740)
		row:SetHeight(SELL_ROW_H)
		if i == 1 then
			row:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
		else
			row:SetPoint("TOPLEFT", g.rows[i - 1], "BOTTOMLEFT", 0, 0)
		end

		if i % 2 == 0 then
			local stripe = row:CreateTexture(nil, "BACKGROUND")
			stripe:SetTexture(1, 1, 1, 0.035)
			stripe:SetAllPoints(row)
		end

		row.cells = {}
		local layout = { { 2, 286, "LEFT" }, { 350, 76, "RIGHT" },
		                 { 434, 116, "RIGHT" }, { 558, 116, "RIGHT" } }
		for c, l in ipairs(layout) do
			local fs = row:CreateFontString(nil, "ARTWORK")
			Font(fs, 11, 1, 1, 1)
			fs:SetPoint("LEFT", l[1], 0)
			fs:SetWidth(l[2])
			fs:SetJustifyH(l[3])
			row.cells[c] = fs
		end

		--[[
			The lot size, typed on the row it belongs to.

			It is saved against the item the moment it is typed, and it is the
			item that is remembered rather than the row - the list re-sorts
			itself as prices move, so a number tied to "the fourth line" would
			land on whatever happened to be there next time.

			`painting` marks the addon writing the saved value back into the
			box, so restoring a number is not mistaken for somebody typing one
			and does not set off another round of saving and repainting.
		]]
		local eb = CreateFrame("EditBox", nil, row)
		eb:SetPoint("LEFT", 296, 0)
		eb:SetWidth(44)
		eb:SetHeight(18)
		eb:SetAutoFocus(false)
		eb:SetNumeric(true)
		eb:SetMaxLetters(4)
		eb:SetTextInsets(4, 4, 0, 0)
		eb:SetBackdrop({
			bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 10,
			insets = { left = 2, right = 2, top = 2, bottom = 2 },
		})
		eb:SetBackdropColor(0, 0, 0, 0.65)
		eb:SetBackdropBorderColor(0.45, 0.45, 0.45, 1)
		Font(eb, 11, 1, 1, 1)

		local function commit()
			if eb.painting or not eb.itemName then return end
			BS:SetSellStackSize(eb.itemName, eb.itemLink, tonumber(eb:GetText()) or 0)
		end

		--[[
			Saved on every keystroke so the shape beside it answers as you type,
			but a posting run is only rebuilt when you have finished typing.

			The difference matters: rebuilding puts an item in the sell slot,
			and doing that on the way from "1" to "15" would pick things up and
			put them down twice for one number.
		]]
		local function settle()
			--[[
				`painting` marks the addon letting go of the box rather than a
				person doing it. The repaint drops focus itself when a row
				changes hands, and that must not read as "they have finished
				typing" and rebuild a posting run nobody touched.
			]]
			if eb.painting then return end
			commit()
			if BS.sellList then BS:SellReplan() end
		end

		eb:SetScript("OnTextChanged", commit)
		eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
		eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
		eb:SetScript("OnEditFocusLost", settle)
		eb:SetScript("OnEnter", function(self)
			if not self.itemName then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine("How many in one auction", 1, 0.82, 0)
			GameTooltip:AddLine(format("%d of these to post. In lots of %d that is %s.",
				self.total or 0, self.size or 1, self.shape or "-"), 1, 1, 1, true)
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("Whatever is left over after the whole lots goes up as "
				.. "one last smaller auction, priced for its own size, rather than "
				.. "being left in your bag.", 0.8, 0.8, 0.8, true)
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("Saved against this item, so it is the same every time "
				.. "you post it. Blank or 0 means a full stack.", 0.6, 0.9, 1, true)
			GameTooltip:AddLine("Can be changed mid-run: press enter and what is still "
				.. "to go is worked out again round the new size.", 0.6, 0.9, 1, true)
			if self.maxStack and self.maxStack > 1 then
				GameTooltip:AddLine(format("A full stack of these is %d.", self.maxStack),
					0.6, 0.6, 0.6, true)
			end
			GameTooltip:Show()
		end)
		eb:SetScript("OnLeave", function() GameTooltip:Hide() end)
		row.stackBox = eb

		--[[
			Where the asking price came from, on the row it belongs to.

			The number in Each is the end of a short argument - what is up, what
			was disregarded and why - and a price you cannot see the argument
			for is a price you have to take on faith. Given what a wrong one
			costs, it is worth being able to look.
		]]
		row:EnableMouse(true)
		row:SetScript("OnEnter", function(self)
			local it = self.item
			if not it then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			if it.link then
				GameTooltip:SetHyperlink(it.link)
			else
				GameTooltip:AddLine(it.name or "?", 1, 1, 1)
			end
			GameTooltip:AddLine(" ")

			local q = it.quote
			if q and q.unit then
				GameTooltip:AddDoubleLine("Others are asking, each",
					BS.Money(q.unit), 0.8, 0.8, 0.8, 1, 1, 1)
				GameTooltip:AddDoubleLine("Competing auctions",
					tostring(q.rivals or 0), 0.8, 0.8, 0.8, 1, 1, 1)

				GameTooltip:AddDoubleLine("Read from",
					q.src == "scan" and "the last full scan" or "a search just now",
					0.5, 0.5, 0.5, 0.6, 0.6, 0.6)

				if (q.dropped or 0) > 0 then
					GameTooltip:AddLine(" ")
					GameTooltip:AddLine(format("%d listing%s ignored as a giveaway.",
						q.dropped, q.dropped == 1 and "" or "s"), 1, 0.55, 0.15, true)
					GameTooltip:AddLine(format("The cheapest is %s, which is far below "
						.. "everything else up. Undercutting it would copy somebody "
						.. "else's mistake onto your whole stock.",
						BS.Money(q.lowest or 0)), 0.85, 0.75, 0.6, true)
				elseif q.thin then
					GameTooltip:AddLine(" ")
					GameTooltip:AddLine("Only one other auction is up, so there is "
						.. "nothing to check it against. Worth a look before posting.",
						1, 0.8, 0.4, true)
				end

				--[[
					Every price the sweep kept was a giveaway, so the real one is
					somewhere it never wrote down. Rare, and worth saying rather
					than quietly pricing into: pressing Refresh asks the auction
					house properly and reads the whole list.
				]]
				if q.partial then
					GameTooltip:AddLine(" ")
					GameTooltip:AddLine("The scan only kept the cheapest few of these "
						.. "and all of them looked like giveaways, so this price may "
						.. "still be low. Press Refresh to ask the auction house "
						.. "directly.", 1, 0.55, 0.15, true)
				end
			elseif q and q.none then
				GameTooltip:AddLine("Nothing else of this is for sale.", 0.6, 0.9, 1, true)
				GameTooltip:AddLine("Priced from the last scan instead.", 0.7, 0.7, 0.7, true)
			else
				GameTooltip:AddLine("Not checked against the auction house yet.",
					1, 0.8, 0.4, true)
				GameTooltip:AddLine("Press the button below and it will look before "
					.. "it posts anything.", 0.7, 0.7, 0.7, true)
			end

			GameTooltip:AddLine(" ")
			GameTooltip:AddDoubleLine("You will ask, each",
				BS.Money(it.unit or 0), 0.8, 0.8, 0.8, 0.4, 1, 0.4)
			GameTooltip:Show()
		end)
		row:SetScript("OnLeave", function() GameTooltip:Hide() end)

		row:Hide()
		g.rows[i] = row
	end

	local foot = g:CreateFontString(nil, "ARTWORK")
	Font(foot, 10, 0.7, 0.7, 0.7)
	foot:SetPoint("TOPLEFT", 18, -158 - SELL_ROWS * SELL_ROW_H)
	foot:SetWidth(780)
	foot:SetJustifyH("LEFT")
	g.foot = foot

	--------------------------------------------------------------- buttons --
	-- The post itself happens in this OnClick and nowhere else. StartAuction is
	-- only honoured while the client is handling a real click.
	local sellBtn = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
	sellBtn:SetPoint("BOTTOMRIGHT", -18, 18)
	sellBtn:SetWidth(150)
	sellBtn:SetHeight(24)
	sellBtn:SetScript("OnClick", function()
		if BS.armedSell then
			BS:FireArmedSell()
			BS:SellArmNext()		-- arming is not protected, so this is free here
		elseif BS.sellList then
			-- mid-run with nothing loaded means the last post is still settling
			-- before its remainder; pressing again here would start the whole
			-- queue over from the top
			return
		else
			BS:SellStart()
		end
	end)
	Tip(sellBtn, "Post the next one",
		"WoW only lets an addon post while you are actually clicking, so this is one "
		.. "press per item. Each press posts what is on the button and loads the next, "
		.. "so you keep clicking the same spot.\n\nEvery stack of the same item goes in "
		.. "a single press.")
	g.sellBtn = sellBtn

	local skipBtn = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
	skipBtn:SetPoint("BOTTOMRIGHT", -174, 18)
	skipBtn:SetWidth(80)
	skipBtn:SetHeight(24)
	skipBtn:SetText("Skip")
	skipBtn:SetScript("OnClick", function() BS:SellSkip() end)
	Tip(skipBtn, "Pass on this one", "Leaves it in the bag and loads the next item.")
	g.skipBtn = skipBtn

	local stopBtn = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
	stopBtn:SetPoint("BOTTOMLEFT", 18, 18)
	stopBtn:SetWidth(90)
	stopBtn:SetHeight(24)
	stopBtn:SetText("Stop")
	stopBtn:SetScript("OnClick", function() BS:CancelSell() end)
	Tip(stopBtn, "Stop posting", "Clears whatever is lined up. Nothing already posted "
		.. "comes back.")

	local count = g:CreateFontString(nil, "ARTWORK")
	Font(count, 11, 0.7, 0.7, 0.7)
	count:SetPoint("BOTTOMLEFT", 118, 24)
	g.count = count

	self.sellFrame = g
end

function BS:RefreshSell()
	local g = self.sellFrame
	if not g or not g:IsShown() then return end

	-- Painting writes into the boxes, and a box being written to asks for a
	-- repaint, so this can be reached from inside itself. Same guard the
	-- crafting page uses, and for the same reason.
	if self.sellPainting then
		self.sellDirty = true
		return
	end
	self.sellPainting = true

	for _, eb in ipairs(g.boxes) do eb.Refresh() end

	local s = self:SellSettings()
	g.durBtn:SetText(BS.SellDurations[s.duration] or "24 hours")

	-- the tick boxes, each labelled with how big that bag actually is
	for bag = 0, 4 do
		local cb   = g.bagChecks[bag]
		local size = GetContainerNumSlots(bag) or 0
		cb:SetChecked(s.bags[bag] and true or false)
		if size > 0 then
			cb.label:SetText(format("%s |cff888888(%d)|r",
				(bag == 0) and "Pack" or tostring(bag), size))
			cb:Enable()
			cb.label:SetTextColor(0.9, 0.9, 0.9)
		else
			-- an empty bag slot is nothing to tick
			cb.label:SetText((bag == 0) and "Pack" or tostring(bag))
			cb:Disable()
			cb.label:SetTextColor(0.4, 0.4, 0.4)
		end
	end

	local queue, skipped, plan = self:SellQueue()

	-- every item, not the thirteen on screen: the footer says what the whole
	-- bag is asking, and scrolling must not change it
	local total = 0
	for _, it in ipairs(plan) do total = total + it.worth end

	--[[
		The window onto the plan, wherever the scrollbar has been dragged to.

		Rows are reused as it moves, so every row is rebound to whatever item
		has landed in it - including its lot-size box, which is why the box
		carries the item's name rather than trusting its position.
	]]
	local offset = FauxScrollFrame_GetOffset(g.scroll) or 0

	for i = 1, SELL_ROWS do
		local row = g.rows[i]
		local it  = plan[offset + i]
		if it then
			row.item = it
			local colour = ITEM_QUALITY_COLORS[it.quality] or ITEM_QUALITY_COLORS[1]

			--[[
				A mark rather than a sentence: there is no room for one, and the
				tooltip has all of it. Orange where a giveaway was disregarded,
				yellow where there was only one rival to judge by.
			]]
			local q    = it.quote
			local mark = ""
			if q and q.partial then
				mark = "  |cffff4444!|r"
			elseif q and (q.dropped or 0) > 0 then
				mark = "  |cffff8800*|r"
			elseif q and q.thin then
				mark = "  |cffffcc66?|r"
			end

			row.cells[1]:SetText((colour and colour.hex or "") .. (it.name or "?") .. "|r"
				.. "  |cffaaaaaax" .. it.total .. "|r" .. mark)

			--[[
				"5 x 4 + 3" - five auctions of four and a last one of three.
				The remainder is coloured apart because it is the part that is
				not what you asked for: it is what was left when the whole lots
				ran out, and it is worth being able to see at a glance which
				items have one.
			]]
			local shape = (it.full > 0)
				and ((it.full == 1) and tostring(it.size)
				     or format("%d |cff888888x|r %d", it.full, it.size))
				or ""
			if it.rest > 0 then
				shape = (shape ~= "" and (shape .. " |cff888888+|r ") or "")
					.. "|cffffcc66" .. it.rest .. "|r"
			end
			row.cells[2]:SetText(shape ~= "" and shape or "|cff666666-|r")

			-- what one full lot fetches; the remainder is priced for its own
			-- size and the total below already counts it that way
			local head = it.lots[1]
			row.cells[3]:SetText(head and BS.Money(head.buyout) or "|cff666666-|r")
			row.cells[4]:SetText("|cffffd100" .. BS.Money(it.worth) .. "|r")

			local eb = row.stackBox

			--[[
				If the row under a box being typed into has become a different
				item - a scan landed and re-sorted the list - the half-typed
				number belongs to neither of them. Dropping focus lets the
				repaint below put the new item's own figure in, rather than
				saving what was meant for the old one against the new one.
			]]
			if eb.itemName ~= it.name and eb:HasFocus() then
				-- marked as ours, so letting go of the box does not save the
				-- half-typed number against whichever item has landed here
				eb.painting = true
				eb:ClearFocus()
				eb.painting = nil
			end

			eb.itemName = it.name
			eb.itemLink = it.link
			eb.total    = it.total
			eb.size     = it.size
			eb.maxStack = it.maxStack
			eb.shape    = BS.LotText(it)
			if not eb:HasFocus() then
				eb.painting = true
				eb:SetText(tostring(it.size))
				eb.painting = nil
			end
			eb:Show()
			row:Show()
		else
			row.item = nil
			row.stackBox.itemName = nil
			row.stackBox:Hide()
			row:Hide()
		end
	end

	FauxScrollFrame_Update(g.scroll, #plan, SELL_ROWS, SELL_ROW_H)

	local notes = {}

	-- how many rows there are, now that the list scrolls and the screen no
	-- longer tells you: thirteen visible says nothing about forty being there
	if #plan > SELL_ROWS then
		notes[#notes + 1] = format("%d items - scroll for the rest", #plan)
	end

	--[[
		Two different numbers and both worth saying: how many auctions go up,
		and how many times you have to press the button to put them there. All
		the lots of one size go up in a single press, so they are rarely equal.
	]]
	if #queue > 0 then
		local auctions = 0
		for _, lot in ipairs(queue) do auctions = auctions + lot.stacks end
		notes[#notes + 1] = format("%d auction%s in %d press%s",
			auctions, auctions == 1 and "" or "s",
			#queue, #queue == 1 and "" or "es")
	end
	if skipped.bound > 0 then
		notes[#notes + 1] = format("%d soulbound, skipped", skipped.bound)
	end
	if skipped.priced > 0 then
		notes[#notes + 1] = format("|cffff8800%d with no known price, skipped|r",
			skipped.priced)
	end
	if skipped.locked > 0 then
		notes[#notes + 1] = format("%d locked", skipped.locked)
	end

	g.foot:SetText(format("%s.%s%s", self:SellRangeText(),
		#plan > 0 and format("  Asking |cffffd100%s|r in all.", BS.Money(total)) or
			"  Nothing in there to post.",
		#notes > 0 and ("   " .. table.concat(notes, "   -   ")) or ""))

	--[[
		The same three states as the Bid and Buy pages, in the same colours.
		Posting does not spend gold, but it does commit a deposit and put your
		goods somewhere you cannot immediately get them back from, and "did that
		go through or not" is exactly as easy to misread here as anywhere else.
	]]
	if self.sellSurvey then
		--[[
			The check pass. Greyed because there is nothing useful to press: it
			is asking the auction house what these are really going for, and
			every price on the page is about to be replaced by the answer.
		]]
		g.sellBtn:SetText("Checking prices...")
		g.skipBtn:Hide()
		g.sellBtn:Disable()
	elseif self.armedSell then
		g.sellBtn:SetText(ArmedText("POST", BS.MoneyPlain(self.armedSell.buyout)))
		g.skipBtn:Show()
		g.sellBtn:Enable()
	elseif self.sellList then
		-- the pause between an item's whole lots and its remainder: greyed so
		-- the wait reads as the addon working rather than as a dead button
		g.sellBtn:SetText("Waiting...")
		g.skipBtn:Hide()
		g.sellBtn:Disable()
	else
		--[[
			Says what the press will actually do. The first one checks the
			market before it posts anything, and a button that said "Start
			posting" and then spent ten seconds searching would read as a
			button that had not worked.
		]]
		--[[
			A scan the Sell tab can price from counts as already checked, so a
			fresh sweep leaves this reading "Start posting" rather than offering
			to go and ask for something it was told minutes ago.
		]]
		local needCheck = false
		for _, it in ipairs(plan) do
			if not (BS:SellQuote(it.name) or BS:SellScanQuote(it.name)) then
				needCheck = true
				break
			end
		end
		g.sellBtn:SetText(needCheck and "Check prices & post" or "Start posting")
		g.skipBtn:Hide()
		g.sellBtn:Enable()
	end

	if self.sellSurvey then
		local sv = self.sellSurvey
		g.count:SetText(format("|cffffd100Checking %d of %d|r", sv.at, #sv.queue))
	elseif self.sellList then
		--[[
			Counted in presses rather than in auctions, because that is the
			number you are working through: one lot is one press however many
			auctions it puts up.
		]]
		g.count:SetText(format("%s%d of %d posted  -  click POST for the next|r",
			ARMED_COLOUR, (self.sellIndex or 1) - 1, #self.sellList))
	elseif (self.sellPosted or 0) > 0 then
		-- past tense, and it stays until the next run replaces it, so a page you
		-- come back to still says what happened on it
		g.count:SetText(DoneText(format("Finished - %d posted", self.sellPosted)))
	else
		g.count:SetText("")
	end

	self.sellPainting = nil
	if self.sellDirty then
		self.sellDirty = nil
		self:RefreshSell()
	end
end

function BS:ShowSell()
	if not self.frame then return end
	self.frame:Show()
	if self.tab == "sell" then self:SetTab("snipe") else self:SetTab("sell") end
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
				-- one row stands for several auctions, so say how they split
				if (e.outCount or 0) > 0 and (e.leadCount or 0) > 0 then
					label = label .. format("  |cffff8800%d outbid|r|cff888888 of %d|r",
						e.outCount, e.copies)
				else
					label = label .. format("  |cffffd100(%d of them)|r", e.copies)
				end
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

--[[
	The auction page's status line sits at the bottom of the window, where the
	other pages cover it. The buy page runs queries of its own and has plenty to
	say while they are in flight, so it keeps a line of its own and this puts
	the same words in both.
]]
function BS:SetStatus(text)
	if self.frame then self.frame.status:SetText(text or "") end
	if self.buyFrame and self.buyFrame.status then
		self.buyFrame.status:SetText(text or "")
	end
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
	-- Browse's own search replaces the auction list, which is the list a buy
	-- search or a purchase is standing on
	if self.buySearch or self.buyRun then
		self:Print("The Buy tab is using the auction house - finish or stop it first.")
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

--[[
	The ratio, and how much to believe it.

	It is normally what the item is worth over what a bid costs. When nothing is
	known about the item there is nothing to go on but the seller's buyout, and
	a seller's opinion is not a valuation - so that case is marked rather than
	dressed up as the same number. Grey, with a `?`, the same shorthand the
	Profit column uses for "no idea".
]]
local function RatioText(ratio, from)
	if from == "buyout" then
		return string.format("|cff999999%.1fx?|r", ratio)
	end
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

	-- The other tabs paint themselves, but everything else in the addon calls
	-- this one when something changes - so it passes the message along rather
	-- than making every caller know which page is up.
	if self.sellFrame and self.sellFrame:IsShown() then self:RefreshSell() end
	if self.buyFrame  and self.buyFrame:IsShown()  then self:RefreshBuy()  end

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

	--[[
		The same three states as the Buy and Sell pages, in the same colours and
		the same words, because they are the same question: is this press about
		to spend gold, has it already, or is it waiting on something. A bid is
		one press per auction rather than per page, which makes it the button
		most likely to be pressed on autopilot.
	]]
	if self.armed then
		-- one click, one bid: the button shows exactly what it is about to spend
		f.batchBtn:SetText(ArmedText("BID", BS.MoneyPlain(self.armed.bid)))
		f.batchBtn:Enable()
	elseif self.batch then
		f.batchBtn:SetText(BusyText("preparing..."))
		f.batchBtn:Disable()
	else
		--[[
			Left as an action even straight after a batch, unlike the Buy page's
			button, and the difference is deliberate. Ending a batch can find
			copies the scan had stepped over, and the only way to take those is
			to press this again - so a dead button here would block the thing
			EndBatch has just told you to do.

			What a finished batch changes is the line underneath, which says so
			in the past tense. The button stays honest by staying an
			instruction rather than pretending to be a status.
		]]
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
		f.selCount:SetText(format("%sclick BID  -  %d of %d done|r",
			ARMED_COLOUR, self.batchDone or 0, #self.batch))
	elseif (self.batchDone or 0) > 0 then
		--[[
			The batch is over. Said in the past tense and in the finished
			colour, because the rows stay ticked afterwards and a page showing a
			live selection next to a button reading "Bid selected" is a page
			that looks like it has not started yet.
		]]
		f.selCount:SetText(format("%sBatch finished - %d bid%s.|r  %d still ticked.",
			DONE_COLOUR, self.batchDone,
			(self.batchSkipped or 0) > 0
				and format(", %d skipped", self.batchSkipped) or "",
			selected))
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
	elseif #self:Shown() > 0 and (self.db.minProfit or 0) > 0 then
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

	-- the filters are a window onto the results, so this is what is behind it
	local results = self:Shown()
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
			row.cells[4]:SetText(RatioText(r.ratio, r.ratioFrom))
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
