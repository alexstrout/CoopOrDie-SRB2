--[[
	Coop or Die! v1.1 by fox: https://taraxis.com/

	--------------------------------------------------------------------------------
	Copyright (c) 2021 Alex Strout

	Permission is hereby granted, free of charge, to any person obtaining a copy of
	this software and associated documentation files (the "Software"), to deal in
	the Software without restriction, including without limitation the rights to
	use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
	of the Software, and to permit persons to whom the Software is furnished to do
	so, subject to the following conditions:

	The above copyright notice and this permission notice shall be included in all
	copies or substantial portions of the Software.

	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
	IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
	FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
	AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
	LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
	OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
	SOFTWARE.

	--------------------------------------------------------------------------------
	Extensively draws code from foxBot,
	Copyright (c) 2021 Alex Strout and Shane Ellis

	See license-foxBot.txt or:
	https://github.com/alexstrout/foxBot-SRB2/blob/master/license.txt
]]



--[[
	--------------------------------------------------------------------------------
	GLOBAL CONVARS
	(see "bothelp" at bottom for a description of each)
	--------------------------------------------------------------------------------
]]
local CV_CDDebug = CV_RegisterVar({
	name = "cd_debug",
	defaultvalue = "Off",
	flags = 0,
	PossibleValue = CV_OnOff
})
local CV_CDEnemyClearPct = CV_RegisterVar({
	name = "cd_enemyclearpct",
	defaultvalue = "40",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = {MIN = 0, MAX = 100}
})
local CV_CDEnemyClearMax = CV_RegisterVar({
	name = "cd_enemyclearmax",
	defaultvalue = "75",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = {MIN = 0, MAX = UINT16_MAX}
})
local CV_CDDMFlags = CV_RegisterVar({
	name = "cd_dmflags",
	defaultvalue = "7",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = {MIN = 0, MAX = 15}
})
local CV_CDTeamLives = CV_RegisterVar({
	name = "cd_teamlives",
	defaultvalue = "On",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = CV_OnOff
})
local CV_CDEmeraldBonus = CV_RegisterVar({
	name = "cd_emeraldbonus",
	defaultvalue = "On",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = CV_OnOff
})
local CV_CDShowHud = CV_RegisterVar({
	name = "cd_showhud",
	defaultvalue = "On",
	flags = 0,
	PossibleValue = CV_OnOff
})
local CV_CDHudMaxPlayers = CV_RegisterVar({
	name = "cd_hudmaxplayers",
	defaultvalue = "12",
	flags = 0,
	PossibleValue = {MIN = 0, MAX = 32}
})



--[[
	--------------------------------------------------------------------------------
	GLOBAL TYPE DEFINITIONS
	Defines any mobj types etc. needed by CoopOrDie
	--------------------------------------------------------------------------------
]]
freeslot(
	"MT_FOXCD_SCOREBOP"
)
mobjinfo[MT_FOXCD_SCOREBOP] = {
	spawnstate = S_INVISIBLE,
	radius = FRACUNIT,
	height = FRACUNIT,
	flags = MF_NOGRAVITY|MF_NOCLIP|MF_NOTHINK|MF_NOCLIPHEIGHT|MF_ENEMY
}



--[[
	--------------------------------------------------------------------------------
	GLOBAL HELPER VALUES / FUNCTIONS
	Used in various points throughout code
	--------------------------------------------------------------------------------
]]
--Team lives for sync
local teamlives = 0
local revivequeue = {}
local lastmapnum = 0

--Level times (for NoReload reset detection)
local levelstarttime = 0
local lastleveltime = 0

--Current percentage of enemies destroyed in stage
local enemyct = 0
local targetenemyct = 0
local pendingenemyct = 0
local pendingenemycttime = 0
local notifythreshold = 0

--Current list of "active" mobj thinkers
local mobjthinkers = {}

--Track if we're a new client (re)joining the game
--This is needed as PlayerJoin does not fire for rejoining clients
local newclient = false

--NetVars!
addHook("NetVars", function(network)
	teamlives = network($)
	revivequeue = network($)
	lastmapnum = network($)
	levelstarttime = network($)
	lastleveltime = network($)
	enemyct = network($)
	targetenemyct = network($)
	pendingenemyct = network($)
	pendingenemycttime = network($)
	notifythreshold = network($)
	mobjthinkers = network($)
	newclient = true --Only set on server and joining client(s)
end)

--Sound to play next frame for teamlives-related noises
local lifesfx = nil
local lastlifesfx = nil

--Cache of mobjthinker functions for quick lookup later
local mobjthinkerfunc = {}

--Enemies ineligible for enemyct / targetenemyct
--These are signified by not having damage mechanics applied
--mobjinfo[MT_DETON].cd_skipcount = true
--mobjinfo[MT_POINTY].cd_skipcount = true
--mobjinfo[MT_EGGGUARD].cd_skipcount = true
mobjinfo[MT_CANARIVORE].cd_skipcount = true
--mobjinfo[MT_PTERABYTE].cd_skipcount = true
mobjinfo[MT_BIGMINE].cd_skipcount = true
mobjinfo[MT_ROSY].cd_skipcount = true
mobjinfo[MT_BUMBLEBORE].cd_skipcount = true
mobjinfo[MT_FOXCD_SCOREBOP].cd_skipcount = true

--Enemies that bots should spin-attack when tagged
mobjinfo[MT_SPINCUSHION].cd_aispinattack = true
mobjinfo[MT_SPRINGSHELL].cd_aispinattack = true
mobjinfo[MT_YELLOWSHELL].cd_aispinattack = true

--Enemies that bots should prioritize when tagged
mobjinfo[MT_HIVEELEMENTAL].cd_aipriority = true

--Text table used for HUD hook
local hudtext = {}

--Player already drawn to coop HUD this frame? (set by HUD hook)
local huddrawn = {}

--Resolve player by number (string or int)
local function ResolvePlayerByNum(num)
	if type(num) != "number"
		num = tonumber(num)
	end
	if num != nil and num >= 0 and num < 32
		return players[num]
	end
	return nil
end

--Returns absolute angle (0 to 180)
--Useful for comparing angles
local function AbsAngle(ang)
	if ang < 0 and ang > ANGLE_180
		return InvAngle(ang)
	end
	return ang
end



--[[
	--------------------------------------------------------------------------------
	CDINFO SETUP FUNCTIONS / CONSOLE COMMANDS
	Any CoopOrDie info "setup" logic, including console commands
	This is a lot like foxBot's stuff, but we swap out:
		"ai" struct for "cdinfo"
		"ai_followers" struct for "cd_pinnedplayers"
		Function / console command names
	--------------------------------------------------------------------------------
]]
--Reset (or define) all CDInfo vars to their initial values
local function ResetCDInfo(player)
	local pci = player.cdinfo
	pci.needsrevive = false --Spectating after hitting 0 lives
	pci.awardshieldtime = 0 --Time after which a shield is awarded
	pci.finished = false --Previously finished level at some point
	pci.laststarpostnum = player.starpostnum --Last starpost we've reached
	pci.reexittimeout = 0 --If reborn again in this time, end level instead of warp
end

--Register pin with player for lookup later
local function RegisterPinnedPlayer(player, pin)
	if not player.cd_pinnedplayers
		player.cd_pinnedplayers = {}
	end
	local retVal = player.cd_pinnedplayers[#pin + 1] == nil
	player.cd_pinnedplayers[#pin + 1] = pin
	return retVal
end

--Unregister pin with player
local function UnregisterPinnedPlayer(player, pin)
	if not (player and player.valid and player.cd_pinnedplayers)
		return
	end
	local retVal = player.cd_pinnedplayers[#pin + 1] != nil
	player.cd_pinnedplayers[#pin + 1] = nil
	if table.maxn(player.cd_pinnedplayers) < 1
		player.cd_pinnedplayers = nil
	end
	return retVal
end

--Unregister all pins with player
local function UnregisterAllPinnedPlayers(player)
	if player.cd_pinnedplayers
		for _, pin in pairs(player.cd_pinnedplayers)
			UnregisterPinnedPlayer(player, pin)
		end
		return true
	end
	return false
end

--Create CDInfo table for a given player, if needed
local function SetupCDInfo(player)
	if player.cdinfo
		return
	end

	--Create table, defining any vars that shouldn't be reset via ResetCDInfo
	player.cdinfo = {
		lastshield = SH_NONE, --Last shield of player (used for end-of-level teleport)
		lastlives = player.lives, --Last life count of player (used to sync w/ team)
		useteamlives = false, --Current sync setting for teamlives
		reborn = false --Just recently reborn from hitting end of level
	}
	ResetCDInfo(player) --Define the rest w/ their respective values
end

--Destroy CDInfo table (and any child tables / objects) for a given player, if needed
local function DestroyCDInfo(player)
	if not player.cdinfo
		return
	end

	--Remove us from the revive queue
	for k, v in pairs(revivequeue)
		if v == player
			table.remove(revivequeue, k)
			break
		end
	end

	--Unregister us from all players' pinned players
	for p in players.iterate
		UnregisterPinnedPlayer(p, player)
	end

	--My work here is done
	player.cdinfo = nil
	collectgarbage()
end

--List all players, possible including pins only
local function ListPlayers(player)
	local count = 0
	for p in players.iterate
		local msg = " " .. #p .. " - " .. p.name
		if player.cd_pinnedplayers
			for _, pin in pairs(player.cd_pinnedplayers)
				if pin == p
					msg = $ .. " \x81(pinned)"
					break
				end
			end
		end
		if p == player
			msg = $ .. " \x8A(you)"
		end
		CONS_Printf(player, msg)
		count = $ + 1
	end
	CONS_Printf(player, "Returned " .. count .. " nodes")
end
COM_AddCommand("LISTPLAYERS", ListPlayers, COM_LOCAL)

--Pin a particular player to the coop hud
local function PinPlayer(player, pin)
	--Make sure we're valid / won't end up pinning ourself
	local pin = ResolvePlayerByNum(pin)
	if not (pin and pin.valid) or pin == player
		if pin == player
			CONS_Printf(player, "You can't pin yourself! Please try a different player:")
		else
			CONS_Printf(player, "Invalid player! Please specify a player by number:")
		end
		ListPlayers(player)
		return
	end

	--Pin that player!
	if RegisterPinnedPlayer(player, pin)
		CONS_Printf(player, "Pinning " .. pin.name)
	else
		CONS_Printf(player, "Already pinned " .. pin.name .. "!")
	end
end
COM_AddCommand("PINPLAYER", PinPlayer, 0)

--Unpin a particular player from the coop hud
local function UnpinPlayer(player, pin)
	--Make sure we have pins!
	if not player.cd_pinnedplayers
		CONS_Printf(player, "You don't have any pinned players!")
		return
	end

	--Support "all" argument
	if pin != nil
	and string.lower(pin) == "all"
	and UnregisterAllPinnedPlayers(player)
		CONS_Printf(player, "Unpinning all players")
		return
	end

	--Make sure we're valid / won't end up unpinning ourself
	local pin = ResolvePlayerByNum(pin)
	if not (pin and pin.valid) or pin == player
		if pin == player
			CONS_Printf(player, "You can't unpin yourself! Please try a different player:")
		else
			CONS_Printf(player, "Invalid player! Please specify a player by number:")
		end
		ListPlayers(player)
		return
	end

	--Unpin that player!
	if UnregisterPinnedPlayer(player, pin)
		CONS_Printf(player, "Unpinning " .. pin.name)
	else
		CONS_Printf(player, "Already unpinned " .. pin.name .. "!")
	end
end
COM_AddCommand("UNPINPLAYER", UnpinPlayer, 0)

--Debug command for printing out CDInfo objects
COM_AddCommand("DEBUG_CDINFODUMP", function(player, bot)
	bot = ResolvePlayerByNum(bot)
	if not (bot and bot.valid and bot.cdinfo)
		CONS_Printf(player, "-- mobjthinkers --")
		for k, v in pairs(mobjthinkers)
			CONS_Printf(player, tostring(k) .. " = " .. v)
		end
		CONS_Printf(player, "-- revivequeue --")
		for k, v in pairs(revivequeue)
			CONS_Printf(player, k .. " = " .. tostring(v) .. " " .. v.name)
		end
		return
	end
	CONS_Printf(player, "-- cdinfo " .. bot.name .. " --")
	for k, v in pairs(bot.cdinfo)
		CONS_Printf(player, k .. " = " .. tostring(v))
	end
end, COM_LOCAL)



--[[
	--------------------------------------------------------------------------------
	COOP OR DIE LOGIC
	Now we're getting into actual CD-specific stuff
	--------------------------------------------------------------------------------
]]
--Get the next threshold to do an audio notification at
--(and other cool things now, like team revive)
local function GetNextNotifyThreshold(threshold)
	if targetenemyct == 0
	or enemyct >= targetenemyct
		return -1
	end
	return 25 * ((enemyct * 100 / targetenemyct / 25) + 1)
end

--Determine if we're a valid enemy for CD purposes
local function ValidEnemy(mobj)
	return (mobj.flags & (MF_BOSS | MF_ENEMY))
		and mobj.info.spawnhealth < 16 --Skip anything crazy
		and mobj.health > 0 --Doesn't hurt to check
		and not mobj.info.cd_skipcount
end

--Set skincolor for target mobj based on source
local function SetColorFor(mobj, source)
	if source and source.player
		if source.player == consoleplayer
			if splitscreen
				mobj.color = SKINCOLOR_AZURE
			else
				mobj.color = SKINCOLOR_GREY
			end
		elseif source.player == secondarydisplayplayer
			mobj.color = SKINCOLOR_PINK
		else
			mobj.color = SKINCOLOR_YELLOW
		end
	else
		mobj.color = SKINCOLOR_YELLOW
	end
end

--Handle mobj tic logic for enemies
local MobjThinkForEnemy = 1
mobjthinkerfunc[MobjThinkForEnemy] = function(mobj)
	--Decrement frettime
	if mobj.cd_frettime
		mobj.cd_frettime = $ - 1
		if mobj.cd_frettime <= 0
			mobjthinkers[mobj] = nil
			mobj.cd_frettime = nil
			mobj.flags2 = $ & ~MF2_FRET
		end
	end
end

--Handle mobj tic logic for spheres
local MobjThinkForSphere = 2
mobjthinkerfunc[MobjThinkForSphere] = function(mobj)
	--Decrement frettime
	if mobj.cd_frettime
		mobj.cd_frettime = $ - 1
		mobj.colorized = not $ --Flash on/off
		if mobj.cd_frettime <= 0
			mobjthinkers[mobj] = nil
			mobj.cd_frettime = nil

			--Set target color when done
			mobj.colorized = true
			SetColorFor(mobj, mobj.cd_lastattacker)
		end
	end
end

--Print various event messages
local function PrintDownMessage(player)
	print(player.name .. " is out!")
end
local function PrintReviveMessage(player)
	if player --Assumed valid
		print(player.name .. " has revived!")
	else
		print("The party has revived via a 1up monitor!")
	end
end
local function PrintRebornMessage(player)
	--Assumes targetenemyct > enemyct > 0
	print(player.name .. " has warped to start. (" .. 100 - (enemyct * 100 / targetenemyct) .. "% enemy goal remaining)")
end

--Think for players!
local function PreThinkFrameFor(player)
	if not player.valid
		return
	end

	--Make sure we have a proper CoopOrDie info
	if not player.cdinfo
		SetupCDInfo(player)
	end
	local pci = player.cdinfo

	--Handle lives here - note that useteamlives lags behind a tic
	--This fixes some timing issues w/ foxBot if loaded first
	if pci.useteamlives
	and player.lives > 0
	and pci.lastlives > 0
		if player.lives != pci.lastlives
			teamlives = player.lives
		elseif leveltime > levelstarttime
			if teamlives > player.lives
			and not lifesfx --Revive sound takes priority
			and (
				--Play sound only for local players
				player == consoleplayer
				or player == secondarydisplayplayer
			)
				lifesfx = sfx_3db09
			end
			player.lives = teamlives
		end
	--KO'd? Register for revive if not already
	elseif player.lives <= 0
	and pci.lastlives <= 0
	and not pci.needsrevive
		pci.needsrevive = true
		table.insert(revivequeue, player)

		--Do teamlives mechanics if enabled; otherwise, just reset to 1
		if CV_CDTeamLives.value
			PrintDownMessage(player)
		else
			teamlives = 1
		end
	end
	pci.useteamlives = CV_CDTeamLives.value --Set based on setting
		and not (player.ai and player.ai.synclives) --And foxBot sync

	--Handle revives
	if pci.needsrevive
	and (
		(
			--Team revive
			teamlives > 1
			and (
				player.lives > pci.lastlives --Party revive via 1up
				or revivequeue[1] == player --Next in queue
			)
		)
		or (
			--Somehow revived on our own
			player.mo and player.mo.valid
			and player.mo.health > 0
		)
	)
		pci.needsrevive = false
		for k, v in pairs(revivequeue)
			if v == player
				table.remove(revivequeue, k)
				break
			end
		end
		--Do teamlives mechanics if enabled; otherwise, just reset to 1
		if CV_CDTeamLives.value
			--Decrement teamlives if not a 1up
			if player.lives <= pci.lastlives
				teamlives = max($ - 1, 1)
				PrintReviveMessage(player)
			--Otherwise print a party revive message once
			elseif table.maxn(revivequeue) == 0
				PrintReviveMessage()
			end
			lifesfx = sfx_marioa --Takes priority over other lifesfx
		else
			teamlives = 1
		end
		player.lives = teamlives
		player.spectator = false
		player.playerstate = PST_REBORN
	end
	pci.lastlives = player.lives

	--Handle exiting here
	if (player.pflags & PF_FINISHED)
	and enemyct < targetenemyct
		--Short-circuit failsafe for custom exit triggers
		if pci.reexittimeout > 0
			pci.reexittimeout = 0
			pendingenemyct = targetenemyct - enemyct
			pendingenemycttime = 1 --Process this tic
			return
		end

		--Record last shield if applicable
		pci.lastshield = player.powers[pw_shield]

		--Reset starposts
		player.starpostnum = 0
		player.starposttime = 0
		pci.laststarpostnum = 0

		--If we're a bot, bump our leader to the top of the queue
		--This prevents us from continually respawning at the exit
		if player.ai
		and player.ai.leader
		and player.ai.leader.valid
		and player.ai.leader.spectator
			for k, v in pairs(revivequeue)
				if v == player.ai.leader
					table.remove(revivequeue, k)
					table.insert(revivequeue, 1, player.ai.leader)
					break
				end
			end
		end

		--Remember that we finished level for later
		pci.finished = true

		--Unset our finished state and queue for respawn
		player.pflags = $ & ~PF_FINISHED
		player.playerstate = PST_REBORN
		pci.reborn = true
		pci.reexittimeout = TICRATE / 2
		PrintRebornMessage(player)

		--Revive someone if needed
		teamlives = max($, 2)
		return
	--Reapply finished state if we previously finished level
	--Note this is cleared on map reset so we don't cheat the time bonus
	elseif pci.finished
	and targetenemyct > 0
	and enemyct >= targetenemyct
		P_DoPlayerFinish(player)
		pci.finished = false
	elseif pci.reexittimeout > 0
		pci.reexittimeout = $ - 1
	end
	if pci.reborn
		pci.reborn = false

		--Rings don't carry over - instead, we get reborn w/ bonus rings
		--This keeps things simple and also means we can re-earn extra lives
		--This also stacks with ring-sync bots and that's ok
		player.rings = $ + 20

		--We'll also get additional bonus rings if we have all emeralds
		--This does not stack with ring-sync bots since that would be ridiculous
		if All7Emeralds(emeralds)
		and not (player.ai and player.ai.syncrings)
		and CV_CDEmeraldBonus.value
			player.rings = $ + 20
		end

		--Carry over shield, if applicable - otherwise queue shield award
		if (pci.lastshield & SH_NOSTACK)
		and pci.lastshield != SH_PINK
			P_SwitchShield(player, pci.lastshield)
			pci.lastshield = SH_NONE
		elseif leveltime == levelstarttime --Randomize a bit on level start
			pci.awardshieldtime = P_RandomByte() * TICRATE / 170
		else
			pci.awardshieldtime = TICRATE
		end

		--Woosh!
		if player.realmo and player.realmo.valid
		and (leveltime > levelstarttime or player == consoleplayer)
			S_StartSound(player.realmo, sfx_mixup)
		end
		P_FlashPal(player, PAL_MIXUP, TICRATE / 4)
	end

	--Revive someone if we've hit a new starpost?
	if player.starpostnum > pci.laststarpostnum
		teamlives = max($, 2)

		--Set for all players to avoid coopstarposts issues
		for p in players.iterate
			if p.cdinfo
				p.cdinfo.laststarpostnum = p.starpostnum
			end
		end
	end

	--Award shields if queued
	if pci.awardshieldtime > 0
		pci.awardshieldtime = $ - 1
		if pci.awardshieldtime <= 0
			--Pick from array of random shields
			local shieldchoices = {
				SH_ARMAGEDDON,
				SH_ELEMENTAL,
				SH_ATTRACT,
				SH_FLAMEAURA,
				SH_BUBBLEWRAP,
				SH_THUNDERCOIN,
				SH_PITY | SH_FIREFLOWER
			}
			local i = P_RandomKey(table.maxn(shieldchoices)) + 1

			--Switch that shield! Honoring an existing SH_STACK if present
			P_SwitchShield(player, (pci.lastshield & SH_STACK) | shieldchoices[i])
			pci.lastshield = SH_NONE

			--Sounds and fireflower color
			if player.realmo and player.realmo.valid
				if player.powers[pw_shield] & SH_FIREFLOWER
					player.realmo.color = SKINCOLOR_WHITE
				end
				S_StartSound(player.realmo, sfx_shield)
			end
		end
	end
end



--[[
	--------------------------------------------------------------------------------
	LUA HOOKS
	Define all hooks used to actually interact w/ the game
	--------------------------------------------------------------------------------
]]
--Tic? Tock! Call thinker functions for players and any registered mobjthinkers
addHook("PreThinkFrame", function()
	for player in players.iterate
		PreThinkFrameFor(player)
	end
	for k_mobj, v_func in pairs(mobjthinkers)
		if k_mobj.valid
			mobjthinkerfunc[v_func](k_mobj)
		else
			mobjthinkers[k_mobj] = nil
		end
	end

	--Handle any pendingenemyct
	if pendingenemycttime > 0
		pendingenemycttime = $ - 1
		if pendingenemycttime <= 0
		or pendingenemyct + enemyct >= targetenemyct
			enemyct = $ + pendingenemyct
			pendingenemyct = 0

			--Make noises! And revive players
			if notifythreshold > 0 and targetenemyct > 0
			and enemyct * 100 / targetenemyct >= notifythreshold
				notifythreshold = GetNextNotifyThreshold($)
				teamlives = max($, 2)
				if consoleplayer and consoleplayer.valid
					if enemyct >= targetenemyct
						S_StartSound(nil, sfx_ideya, consoleplayer)
					else
						S_StartSound(nil, sfx_3db06, consoleplayer)
					end
				end
			end
		end
	end

	--Play any lifesfx set for this frame
	if lifesfx and lifesfx == lastlifesfx
		if consoleplayer and consoleplayer.valid
			S_StartSound(nil, lifesfx, consoleplayer)
		end
		lifesfx = nil
	end
	lastlifesfx = lifesfx

	--Handle anything required for (re)joining clients
	--Note that consoleplayer is server for a few tics on new clients
	--Thus, newclient never gets unset on the server itself, but that's ok
	if newclient
	and consoleplayer
	and consoleplayer != server
		newclient = false

		--Fix grey enemies for mid-game joiners
		for mobj in mobjs.iterate()
			if mobj.cd_lastattacker
				SetColorFor(mobj, mobj.cd_lastattacker)
			end
		end
	end

	--Record lastleveltime, for reset detection
	lastleveltime = leveltime
end)

--Handle MapChange for resetting things
local function HandleMapChange(mapnum)
	for player in players.iterate
		if player.cdinfo
			ResetCDInfo(player)

			--Reset a few more things if different map
			if mapnum != lastmapnum
				player.cdinfo.reborn = false
			--Hand out shields if restarting map from death
			elseif teamlives <= 1
				player.cdinfo.reborn = true
			end
		end
	end

	--Reset level times
	levelstarttime = 0
	lastleveltime = 0

	--Reset enemy count, unless we're restarting the map
	if mapnum != lastmapnum
		enemyct = 0
	elseif multiplayer
		enemyct = $ / 2 --Unchanged for singleplayer
	end
	targetenemyct = 0
	pendingenemyct = 0
	pendingenemycttime = 0
	notifythreshold = -1

	--Reset revivequeue / mobjthinkers
	revivequeue = {}
	mobjthinkers = {}
	collectgarbage()

	--Ensure teamlives is a sane value
	teamlives = max($, 1)
end
addHook("MapChange", HandleMapChange)

--Handle MapLoad for post-load actions
local PostMapLoadFor = 3
mobjthinkerfunc[PostMapLoadFor] = function(mobj)
	if mobj.cd_counttime
		mobj.cd_counttime = $ - 1
		if mobj.cd_counttime <= 0
			mobjthinkers[mobj] = nil
			mobj.cd_counttime = nil

			--Count up enemies
			--Only done here to avoid altering targetenemyct mid-game
			for mobj in mobjs.iterate()
				if ValidEnemy(mobj)
					targetenemyct = $ + mobj.info.spawnhealth

					--Debug
					if CV_CDDebug.value and not netgame
						mobj.colorized = true
						mobj.color = SKINCOLOR_ORANGE
					end
				end
			end
			if CV_CDDebug.value
				print("-- CDDebug: Counted " .. targetenemyct .. " enemies * spawnhealth")
			end
			targetenemyct = min(
				--40% of 1 enemy is still 1 enemy!
				FixedCeil($ * FRACUNIT * CV_CDEnemyClearPct.value / 100) / FRACUNIT,
				CV_CDEnemyClearMax.value
			)
			if CV_CDDebug.value
				print("-- CDDebug: Adjusting count to " .. targetenemyct)
			end
			notifythreshold = GetNextNotifyThreshold($)
		end
	end
end
local function HandleMapLoad(mapnum)
	if G_IsSpecialStage()
		--Tighten special stage time!
		if CV_CDDMFlags.value & 4
			local count = 0
			for player in players.iterate
				count = $ + 1
			end
			for player in players.iterate
				player.nightstime = max($ * 3 / max(count, 3), 60 * TICRATE)
			end
		end
	end
	lastmapnum = mapnum

	--Handle any post-MapLoad logic - just use mobjthinkers for this
	--Server may be nil when exiting to title, but should otherwise always be valid
	if server and server.valid
		mobjthinkers[server] = PostMapLoadFor
		server.cd_counttime = TICRATE
	end
end
addHook("MapLoad", HandleMapLoad)

--Handle enemy spawning
addHook("MobjSpawn", function(mobj)
	--Flag boss types as priority AI target
	if mobj.info.flags & MF_BOSS
		mobj.info.cd_aipriority = true
	end
	--Flag enemy as "active" to run damage hooks etc. on
	if ValidEnemy(mobj)
		mobj.cd_active = true

		--Debug
		if CV_CDDebug.value and not netgame
			mobj.colorized = true
			mobj.color = SKINCOLOR_GREEN
		end
	end
end)

--Handle enemy collision (no collide on merp)
local function HandleCollide(tmthing, thing)
	if thing.cd_frettime
	and thing.cd_lastattacker
	and (
		thing.cd_lastattacker.mo == tmthing
		or (tmthing.player and thing.cd_lastattacker.player == tmthing.player)
	)
		return false
	end
end
addHook("MobjCollide", HandleCollide, MT_PLAYER)
addHook("MobjMoveCollide", HandleCollide, MT_PLAYER)

--Handle enemy damage (now with more merp)
addHook("MobjDamage", function(target, inflictor, source, damage, damagetype)
	if target.cd_active
	and source and source.valid
	and (CV_CDDMFlags.value & 1)
	and not (
		--Nukes and other big explosions also instantly deal real damage
		damagetype == DMG_NUKE
		or (damagetype & (DMG_CANHURTSELF | DMG_DEATHMASK))
	)
		if not target.cd_lastattacker
			target.cd_lastattacker = {
				mo = source,
				player = source.player
			}

			--Handle colorization
			target.colorized = true
			SetColorFor(target, source)

			--Spawn and immediately destroy a scorebop
			--This gives us POINTS using native scoring
			local scorebop = P_SpawnMobjFromMobj(target, 0, 0, 0, MT_FOXCD_SCOREBOP)
			scorebop.height = target.height
			P_KillMobj(scorebop, inflictor, source, damagetype)

			--Boop!
			mobjthinkers[target] = MobjThinkForEnemy
			target.cd_frettime = TICRATE / 4
			target.flags2 = $ | MF2_FRET
			S_StartSound(target, sfx_dmpain)
			return true
		elseif target.cd_lastattacker.mo == source
		or (source.player and target.cd_lastattacker.player == source.player)
			--Merp
			if inflictor
			and not target.cd_frettime
				mobjthinkers[target] = MobjThinkForEnemy
				target.cd_frettime = TICRATE / 2
				S_StartSound(target, sfx_s3k7b)

				--Count number of merps, eventually retaliating
				if not target.cd_merpcount
					target.cd_merpcount = 3
				else
					target.cd_merpcount = $ - 1
					if target.cd_merpcount < 2
						--cd_frettime already set above
						target.flags2 = $ | MF2_FRET
					end
					if target.cd_merpcount <= 0
						--Player or player-like buddy object :)
						if inflictor.player
							S_StartSound(inflictor, sfx_shldls)
							P_DoPlayerPain(inflictor.player, target, target)
						elseif inflictor.info.spawnstate == mobjinfo[MT_PLAYER].spawnstate
							S_StartSound(inflictor, sfx_shldls)
							inflictor.state = S_PLAY_PAIN
						end
						target.cd_merpcount = nil
					end
				end
			end
			return true
		else
			--Allow hit trading on bosses etc.
			target.cd_lastattacker = nil

			--Decolorize for proper explosion fx / bosses
			target.colorized = false
			target.color = SKINCOLOR_NONE
		end
	end
end)

--Handle enemy death
local function HandleDeath(target, inflictor, source, damagetype)
	--Need to check valid as MobjRemoved may fire outside level
	--Also check leveltime in case any enemies are removed at level start
	--(+ 1 tic incase we're spamming retry for some reason)
	if leveltime > levelstarttime + 1
	and target.valid and target.cd_active
		target.cd_active = false
		target.cd_lastattacker = nil
		mobjthinkers[target] = nil

		--Decolorize for proper explosion fx
		target.colorized = false
		target.color = SKINCOLOR_NONE

		--Increment enemy count!
		pendingenemyct = $ + target.info.spawnhealth
		pendingenemycttime = TICRATE / 2
	end
end
addHook("MobjDeath", HandleDeath)
addHook("MobjRemoved", HandleDeath)

--Handle player death
addHook("MobjDeath", function(target, inflictor, source, damagetype)
	if CV_CDDMFlags.value & 8
		for mobj in mobjs.iterate()
			if mobj.cd_lastattacker
			and (
				mobj.cd_lastattacker.mo == target
				or (target.player and mobj.cd_lastattacker.player == target.player)
			)
				mobj.cd_lastattacker = nil

				--Decolorize
				mobj.colorized = false
				mobj.color = SKINCOLOR_NONE
			end
		end
	end
end, MT_PLAYER)

--Handle special stage spheres
addHook("TouchSpecial", function(special, toucher)
	if not (CV_CDDMFlags.value & 2)
	or not multiplayer --No teammates in singleplayer special stages
		return nil
	end
	if not special.cd_lastattacker
		special.cd_lastattacker = {
			mo = toucher,
			player = toucher.player
		}

		--Handle colorization
		special.colorized = true
		special.color = SKINCOLOR_WHITE

		--*iconic sphere noises*
		mobjthinkers[special] = MobjThinkForSphere
		special.cd_frettime = TICRATE / 8
		S_StartSound(toucher, sfx_s3k65)
		return true
	elseif special.cd_lastattacker.mo == toucher
	or (toucher.player and special.cd_lastattacker.player == toucher.player)
	or special.cd_frettime --Simulate MF2_FRET behavior
		return true
	end
end, MT_BLUESPHERE)

--Handle (re)spawning for players
addHook("PlayerSpawn", function(player)
	--Players get awards w/ all emeralds since it's more difficult
	if All7Emeralds(emeralds)
	and CV_CDEmeraldBonus.value
		SetupCDInfo(player) --For first-time joiners; safe if existing
		player.cdinfo.reborn = true --No effect on eol teleport
	end

	--Handle NoReload resets
	if leveltime < lastleveltime
		HandleMapChange(lastmapnum)
		HandleMapLoad(lastmapnum)
	end

	--Record level start time (for NoReload levels)
	--This could be in MapLoad, but dedicated servers start w/ no players
	if levelstarttime == 0
		levelstarttime = leveltime
	end

	--Match teamlives to (highest) expected player lives at level start
	if leveltime == levelstarttime
		teamlives = max($, player.lives)
	end
end)

--Handle sudden quitting for players
addHook("PlayerQuit", function(player, reason)
	if player.cdinfo
		DestroyCDInfo(player)
	end
end)

--HUD hook!
local function BuildHudFor(v, stplyr, cam, player, i, namecolor)
	--Ring / time hud!
	local rcolor = "\x82"
	if player.nightstime
		if player.mo and player.mo.valid
		and (player.mo.eflags & (MFE_TOUCHWATER | MFE_UNDERWATER))
		and leveltime % (TICRATE / 4) < TICRATE / 8
			rcolor = "\x85"
		end
		hudtext[i] = rcolor .. "Time \x80" .. player.nightstime / TICRATE
	else
		if player.rings <= 0
		and leveltime % TICRATE < TICRATE / 2
			rcolor = "\x85"
		end
		hudtext[i] = rcolor .. "Rings \x80" .. player.rings
	end
	if string.len(player.name) > 11
		hudtext[i + 1] = string.sub(player.name, 0, 10) .. ".."
	else
		hudtext[i + 1] = player.name
	end
	if namecolor
		hudtext[i + 1] = namecolor .. $
	end

	--Spectating or dead? (will only display if AI leader or pinned)
	local pmo = player.realmo
	if player.spectator
	or not (pmo and pmo.valid)
	or pmo.health <= 0
		hudtext[i] = "\x86" .. "Dead.."
	end
	hudtext[i + 2] = ""
	hudtext[i + 3] = ""

	local bmo = stplyr.realmo
	if bmo and bmo.valid
	and pmo and pmo.valid
		--Distance (pre-scaled for approximate drawing purposes - can get very large)
		local zdist = (pmo.z - bmo.z) / bmo.scale
		local dist = FixedHypot(
			R_PointToDist2(
				bmo.x, bmo.y,
				pmo.x, pmo.y
			) / bmo.scale,
			zdist
		)
		hudtext[i + 2] = "\x86" .. "Dist "
		if dist > INT16_MAX
		or dist < 0
			hudtext[i + 2] = $ .. "Far.."
		else
			hudtext[i + 2] = $ .. dist / 100
		end

		--Angle (note angleturn is converted to angle by constant of 16, not FRACBITS)
		local angle = stplyr.cmd.angleturn << 16
			- R_PointToAngle2(
				bmo.x, bmo.y,
				pmo.x, pmo.y
			)

		local dir = nil
		if dist <= 256
			dir = " "
		elseif AbsAngle(angle) > ANGLE_135
			dir = "v"
		elseif AbsAngle(angle) > ANGLE_45
			if angle < 0
				dir = "<"
			else
				dir = ">"
			end
		else
			dir = "^"
		end
		if abs(zdist) > 256
			if dist - abs(zdist) < dist / 8
				dir = " "
			end
			if zdist < 0
				dir = "-" .. $
			else
				dir = "+" .. $
			end
		end
		hudtext[i + 3] = "\x86" .. dir
	end

	--Keep simple foxBot concepts in case player prefers only this hud
	if stplyr.ai
	and player == stplyr.ai.leader
		if stplyr.ai.playernosight
			hudtext[i + 2] = "\x87" .. string.sub($, 2)
		end
		if stplyr.ai.cmd_time > 0
		and stplyr.ai.cmd_time < 3 * TICRATE
			hudtext[i + 3] = "\x81" + "AI control in " .. stplyr.ai.cmd_time / TICRATE + 1 .. "..."
		elseif stplyr.ai.doteleport
			hudtext[i + 3] = "\x84Teleporting..."
		end
	end
	return i + 4
end
hud.add(function(v, stplyr, cam)
	--If not previous text in buffer... (e.g. debug)
	if hudtext[1] == nil
		--And we don't want a hud...
		if CV_CDShowHud.value == 0
			return
		end

		--Otherwise generate a simple coop hud
		local i = 100
		if targetenemyct > 0
			i = enemyct * 100 / targetenemyct
			hudtext[1] = i .. "%"
			hudtext[2] = "Enemy Goal:"
			if pendingenemyct
				hudtext[1] = $ .. " \x83+" .. pendingenemyct .. "x"
			end
			if i < 25
				hudtext[1] = "\x85" .. $
			elseif i < 50
				hudtext[1] = "\x84" .. $
			elseif i < 75
				hudtext[1] = "\x81" .. $
			elseif i < 100
				hudtext[1] = "\x8A" .. $
			else
				hudtext[1] = "\x83" .. "DONE!"
			end
		else
			hudtext[1] = ""
			hudtext[2] = ""
		end

		--Put AI leader up top if using foxBot
		i = 3
		if stplyr.ai
		and stplyr.ai.leader
		and stplyr.ai.leader.valid
			i = BuildHudFor(v, stplyr, cam, stplyr.ai.leader, i, "\x83")
			huddrawn[#stplyr.ai.leader] = true

			--And realleader right below if different (e.g. dead)
			if stplyr.ai.realleader != stplyr.ai.leader
			and stplyr.ai.realleader
			and stplyr.ai.realleader.valid
				i = BuildHudFor(v, stplyr, cam, stplyr.ai.realleader, i, "\x87")
				huddrawn[#stplyr.ai.realleader] = true
			end
		end

		--Put any pinned players after
		if stplyr.cd_pinnedplayers
			for _, pin in pairs(stplyr.cd_pinnedplayers)
				if pin.valid
				and not huddrawn[#pin]
					i = BuildHudFor(v, stplyr, cam, pin, i, "\x81")
					huddrawn[#pin] = true
				end
			end
		end

		--Draw rest of players
		local hudmax = CV_CDHudMaxPlayers.value
		for player in players.iterate
			--Stop after cd_hudmaxplayers
			if i > hudmax * 4 + 2 --4 hudtext each + 2 for enemyct
				break
			end

			if player != stplyr
			and not huddrawn[#player]
			and player.mo and player.mo.valid --Infers not spectator.. for now
			and player.mo.health > 0
				i = BuildHudFor(v, stplyr, cam, player, i)
			end
			huddrawn[#player] = false
		end
	end

	--Positioning / size
	local x = 16
	local y = 16
	local size = "small"
	local size_r = "small-right"
	local scale = 1

	--Special stage?
	if G_IsSpecialStage()
		y = $ + 32
	end

	--Account for splitscreen
	--Avoiding V_PERPLAYER as text gets a bit too squashed
	if splitscreen
		y = $ / 2
		if #stplyr > 0
			y = $ + 108 --Magic!
		end
	end

	--Small fonts become illegible at low res
	if v.height() < 400
		size = nil
		size_r = "right"
		scale = 2
	end

	--Draw! Flushing hudtext after
	--This is messy and made more sense in foxBot, but oh well
	for k, s in ipairs(hudtext)
		if k & 1
			if k == 1 --Enemy goal % (e.g. "26% +1x")
				v.drawString(320 - x - 30 * scale, y, s,
					V_SNAPTOTOP | V_SNAPTORIGHT | V_ALLOWLOWERCASE | v.localTransFlag(), size)
			else
				v.drawString(320 - x - 30 * scale, y, s,
					V_SNAPTOTOP | V_SNAPTORIGHT | v.localTransFlag(), size)
			end
		else
			if k > 2 and (k + 2) % 4 == 0 --Direction indicator
			and string.len(s) < 4 --Displaying a direction
				v.drawString(320 - x - 34 * scale, y, s,
					V_SNAPTOTOP | V_SNAPTORIGHT | V_MONOSPACE | V_ALLOWLOWERCASE | v.localTransFlag(), size_r)
			else
				v.drawString(320 - x - 34 * scale, y, s,
					V_SNAPTOTOP | V_SNAPTORIGHT | v.localTransFlag(), size_r)
			end
			y = $ + 4 * scale

			--Insert a small line break between players
			if (k + 2) % 4 == 0
				y = $ + 2 * scale

				--Wrap to another column if needed
				if (k + 2) % (68 / scale) == 0 --17 players * 4 hudtext each
					x = $ + 64 * scale
					y = $ - 160 * scale --Honor splitscreen etc.
				end
			end
		end
		hudtext[k] = nil
	end
end, "game")



--[[
	--------------------------------------------------------------------------------
	HELP STUFF
	Things that may or may not be helpful
	--------------------------------------------------------------------------------
]]
local function BotHelp(player)
	print(
		"\x87 Coop or Die! v1.1: 2021-06-11",
		"",
		"\x87 MP Server Admin:",
		"\x80  cd_enemyclearpct - Required % of enemies for level completion",
		"\x80  cd_enemyclearmax - Maximum # of enemies for level completion",
		"\x80  cd_dmflags - Difficulty modifier flags",
		"\x86   (1 = Enemies require 2+ hits from different players)",
		"\x86   (2 = Spheres require 2 pickups from different players)",
		"\x86   (4 = Special Stages restrict time based on player count)",
		"\x86   (8 = Players reset their tagged enemy hits on death)",
		"\x83   Note: These options can be combined by adding them together!",
		"\x80  cd_teamlives - Share team lives using goal-driven revive mechanics?",
		"\x80  cd_emeraldbonus - Award ring / shield bonuses on spawn w/ all emeralds?",
		"",
		"\x87 MP Client:",
		"\x80  cd_showhud - Draw CoopOrDie info to HUD?",
		"\x80  cd_hudmaxplayers - Maximum # of players to draw on HUD",
		"\x80  pinplayer <player> - Pin <player> to HUD",
		"\x80  unpinplayer <player> - Unpin <player> from HUD \x86(\"all\" = all players)",
		"\x80  listplayers - List active players"
	)
	if not player
		print(
			"",
			"\x87 Use \"cdhelp\" to show this again!"
		)
	end
end
COM_AddCommand("CDHELP", BotHelp, COM_LOCAL)



--[[
	--------------------------------------------------------------------------------
	INIT ACTIONS
	Actions to take once we've successfully initialized
	--------------------------------------------------------------------------------
]]
BotHelp() --Display help
