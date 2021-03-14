--[[
	Coop or Die! v0.x by fox: https://taraxis.com/

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
	Copyright (c) 2021 Alex Strout and CobaltBW - MIT License
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
	defaultvalue = "60",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = {MIN = 0, MAX = 100}
})
local CV_CDEnemyClearMax = CV_RegisterVar({
	name = "cd_enemyclearmax",
	defaultvalue = "200",
	flags = CV_NETVAR|CV_SHOWMODIF,
	PossibleValue = {MIN = 0, MAX = UINT16_MAX}
})
local CV_CDResetTagsOnDeath = CV_RegisterVar({
	name = "cd_resettagsondeath",
	defaultvalue = "Off",
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

--Current percentage of enemies destroyed in stage
local enemyct = 0
local targetenemyct = 0
local notifythreshold = 0

--Current list of "active" mobj thinkers
local mobjthinkers = {}

--Track if we're a new client (re)joining the game
--This is needed as PlayerJoin does not fire for rejoining clients
local newclient = false

--NetVars!
addHook("NetVars", function(network)
	teamlives = network($)
	enemyct = network($)
	targetenemyct = network($)
	notifythreshold = network($)
	mobjthinkers = network($)
	newclient = true --Only set on server and joining client(s)
end)

--Cache of mobjthinker functions for quick lookup later
local mobjthinkerfunc = {}

--Enemies ineligible for enemyct / targetenemyct
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
local function ResetCDInfo(ai)
	ai.reborn = false --Just recently reborn from hitting end of level
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
		lastrings = player.rings, --Last ring count of player (used for end-of-level teleport)
		lastxtralife = player.xtralife, --Last xtralife count of player (also used for eol teleport)
		lastlives = player.lives, --Last life count of player (used to sync w/ team)
		huddrawn = false --Whether player was already drawn to coop HUD this frame (set by HUD hook)
	}
	ResetCDInfo(player.cdinfo) --Define the rest w/ their respective values
end

--Destroy CDInfo table (and any child tables / objects) for a given player, if needed
local function DestroyCDInfo(player)
	if not player.cdinfo
		return
	end

	--Unregister all pinned players
	UnregisterAllPinnedPlayers(player)

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
	if string.lower(pin) == "all"
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
		return
	end
	for k, v in pairs(bot.cdinfo)
		CONS_Printf(player, k .. " = " .. tostring(v))
	end
end, COM_LOCAL)



--[[
	--------------------------------------------------------------------------------
	COOP OR DIE LOGIC
	Now we're getting into actual CD-specific stuff
	PreThinkFrameFor is very similar to foxBot's, but we alter a few things:
		All players have "cdinfo" structs, not just players following leaders
		Lives are synced game-wide via teamlives
		Added some logic to deny exiting if targetenemyct isn't met
		Altered leader logic (mostly to sync w/ foxBot)
		Additional range check added to bai.playernosight

	--------------------------------------------------------------------------------
]]
--Determine if we're a valid enemy for CD purposes
local function ValidEnemy(mobj)
	return mobj.flags & (MF_BOSS | MF_ENEMY)
end

--Set skincolor for target mobj based on source
local function SetColorFor(mobj, source)
	if source
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
mobjthinkerfunc[1] = function(mobj) --MobjThinkForEnemy
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
mobjthinkerfunc[2] = function(mobj) --MobjThinkForSphere
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

	--Handle lives here
	if player.lives > 0
	and pci.lastlives > 0
	and not (player.ai and player.ai.synclives)
		if player.lives != pci.lastlives
			teamlives = player.lives
		elseif teamlives > player.lives
			if leveltime and player.jointime > 2
				P_PlayLivesJingle(player)
			end
			P_GivePlayerLives(player, teamlives - player.lives)
		else
			player.lives = teamlives
		end
	end
	pci.lastlives = player.lives

	--Handle exiting here
	if (player.pflags & PF_FINISHED)
	and enemyct < targetenemyct
		pci.lastrings = player.rings
		pci.lastxtralife = player.xtralife
		player.starpostnum = 0
		player.starposttime = 0
		player.pflags = $ & ~PF_FINISHED
		player.playerstate = PST_REBORN
		pci.reborn = true
		return
	end
	if pci.reborn
		pci.reborn = false
		if not (player.ai and player.ai.syncrings)
			player.rings = pci.lastrings
			player.xtralife = pci.lastxtralife
		end
		if player.realmo and player.realmo.valid
			S_StartSound(player.realmo, sfx_mixup)
		end
		P_FlashPal(player, PAL_MIXUP, TICRATE / 4)
	end
end

--Build hudtext for a particular player
local function BuildHudFor(v, stplyr, cam, player, i, namecolor)
	--Ring hud!
	local rcolor = "\x82"
	if player.rings <= 0
	and leveltime % TICRATE < TICRATE / 2
		rcolor = "\x85"
	end
	hudtext[i] = rcolor .. "Rings \x80" .. player.rings
	hudtext[i + 1] = player.name
	if namecolor
		hudtext[i + 1] = namecolor .. $
	end

	--Spectating or dead?
	local pmo = player.realmo
	if player.spectator
	or not (pmo and pmo.valid)
	or pmo.health <= 0
		hudtext[i] = "\x86" .. "Dead.."
		hudtext[i + 2] = ""
		hudtext[i + 3] = ""
		return i + 4
	end

	local bmo = stplyr.realmo
	if bmo and bmo.valid
		--Distance
		local zdist = (pmo.z - bmo.z)
		local dist = FixedHypot(
			R_PointToDist2(
				bmo.x, bmo.y,
				pmo.x, pmo.y
			),
			zdist
		)
		hudtext[i + 2] = "Dist "
		if dist > 9999 * bmo.scale
		or dist < 0
			hudtext[i + 2] = $ .. "Far.."
		else
			hudtext[i + 2] = $ .. dist / bmo.scale
		end

		--Angle (note angleturn is converted to angle by constant of 16, not FRACBITS)
		local angle = stplyr.cmd.angleturn << 16
			- R_PointToAngle2(
				bmo.x, bmo.y,
				pmo.x, pmo.y
			)

		local dir = nil
		if AbsAngle(angle) > ANGLE_135
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
		if abs(zdist) > 256 * bmo.scale
			if dist - abs(zdist) < dist / 8
				dir = "*"
			end
			if zdist < 0
				dir = "-" .. $
			else
				dir = "+" .. $
			end
		end
		hudtext[i + 3] = dir

		--Keep simple foxBot concepts in case player prefers only this hud
		if stplyr.ai
		and player == stplyr.ai.leader
			if stplyr.ai.playernosight
				hudtext[i + 2] = "\x87" .. $
			end
			if stplyr.ai.doteleport
				hudtext[i + 3] = "\x84Teleporting..."
			end
		end
	end
	return i + 4
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
		mobjthinkerfunc[v_func](k_mobj)
	end

	--Handle anything required for (re)joining clients
	--Note that consoleplayer is server for a few tics on new clients
	--Thus, newclient never gets unset on the server itself, but that's ok
	if newclient
	and consoleplayer != server
	and consoleplayer
	and consoleplayer.valid
		newclient = false

		--Fix grey enemies for mid-game joiners
		for mobj in mobjs.iterate()
			if mobj.cd_lastattacker
				SetColorFor(mobj, mobj.cd_lastattacker)
			end
		end
	end
end)

--Handle MapChange for resetting things
addHook("MapChange", function(mapnum)
	for player in players.iterate
		if player.cdinfo
			ResetCDInfo(player.cdinfo)
		end
	end

	--Reset enemy count / notification threshold
	enemyct = 0
	targetenemyct = 0
	notifythreshold = 25

	--Reset mobjthinkers
	mobjthinkers = {}
	collectgarbage()

	--Reset lives if exhausted
	teamlives = max($, 4)
end)

--Handle MapLoad for post-load actions
addHook("MapLoad", function(mapnum)
	--Decrement lives! Oof
	if not G_IsSpecialStage()
		for player in players.iterate
			teamlives = max($ - 1, 1)
		end
	end

	--Count up enemies
	--Only done here to avoid altering targetenemyct mid-game
	for mobj in mobjs.iterate()
		if ValidEnemy(mobj)
		and not mobj.info.cd_skipcount
			targetenemyct = $ + 1

			--Debug
			if CV_CDDebug.value
				mobj.colorized = true
				mobj.color = SKINCOLOR_ORANGE
			end
		end
	end
	targetenemyct = min(
		$ * CV_CDEnemyClearPct.value / 100,
		CV_CDEnemyClearMax.value
	)
end)

--Handle enemy spawning
addHook("MobjSpawn", function(mobj)
	--Flag enemy as "active" to run damage hooks etc. on
	if ValidEnemy(mobj)
		mobj.cd_active = true

		--Debug
		if CV_CDDebug.value
			mobj.colorized = true
			mobj.color = SKINCOLOR_GREEN
		end
	end
end)

--Handle enemy damage (now with more merp)
addHook("MobjDamage", function(target, inflictor, source, damage, damagetype)
	if target.cd_active
	and source and source.valid
		if not target.cd_lastattacker
			target.cd_lastattacker = {}
			target.cd_lastattacker.mo = source
			target.cd_lastattacker.player = source.player

			--Handle colorization
			target.colorized = true
			SetColorFor(target, source)

			--Spawn and immediately destroy a scorebop
			--This gives us POINTS using native scoring
			local scorebop = P_SpawnMobjFromMobj(target, 0, 0, 0, MT_FOXCD_SCOREBOP)
			scorebop.height = target.height
			P_KillMobj(scorebop, inflictor, source, damagetype)

			--Boop!
			mobjthinkers[target] = 1
			target.cd_frettime = TICRATE / 4
			target.flags2 = $ | MF2_FRET
			S_StartSound(target, sfx_dmpain)
			return true
		elseif target.cd_lastattacker.mo == source
		or target.cd_lastattacker.player == source.player
			--Merp
			if not target.cd_frettime
			and inflictor and inflictor.player
				mobjthinkers[target] = 1
				target.cd_frettime = TICRATE / 2
				S_StartSound(target, sfx_s3k7b)

				--Count number of merps, eventually retaliating
				--Bosses are mean and do this immediately
				if target.flags & MF_BOSS
					target.cd_merpcount = 1
				end
				if not target.cd_merpcount
					target.cd_merpcount = 3
				else
					target.cd_merpcount = $ - 1
					if target.cd_merpcount < 2
						--cd_frettime already set above
						target.flags2 = $ | MF2_FRET
					end
					if target.cd_merpcount <= 0
						S_StartSound(inflictor, sfx_shldls)
						P_DoPlayerPain(inflictor.player, target, target)
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
	if target.valid and target.cd_active
		target.cd_active = false
		target.cd_lastattacker = nil
		mobjthinkers[target] = nil

		--Decolorize for proper explosion fx
		target.colorized = false
		target.color = SKINCOLOR_NONE

		--Increment enemy count!
		if not target.info.cd_skipcount
			enemyct = $ + 1

			--Make noises!
			if targetenemyct > 0
			and consoleplayer.realmo
			and consoleplayer.realmo.valid
				if enemyct >= targetenemyct
					S_StartSound(consoleplayer.realmo, sfx_ideya, consoleplayer)
					targetenemyct = 0
				elseif notifythreshold <= 75
				and enemyct * 100 / targetenemyct >= notifythreshold
					S_StartSound(consoleplayer.realmo, sfx_3db06, consoleplayer)
					notifythreshold = 25 * ((enemyct * 100 / targetenemyct / 25) + 1)
				end
			end
		end
	end
end
addHook("MobjDeath", HandleDeath)
addHook("MobjRemoved", HandleDeath)

--Handle player death
addHook("MobjDeath", function(target, inflictor, source, damagetype)
	if CV_CDResetTagsOnDeath.value
		for mobj in mobjs.iterate()
			if mobj.cd_lastattacker
			and (
				mobj.cd_lastattacker.mo == target
				or mobj.cd_lastattacker.player == target.player
			)
				mobj.cd_lastattacker = nil

				--Decolorize
				mobj.colorized = false
				mobj.color = SKINCOLOR_NONE
			end
		end
	end
end, MT_PLAYER)

--Handle special stage spheres (unless we're in CR_NIGHTSMODE)
addHook("TouchSpecial", function(special, toucher)
	if toucher.player and toucher.player.valid
	and toucher.player.powers[pw_carry] == CR_NIGHTSMODE
		return nil
	end
	if not special.cd_lastattacker
		special.cd_lastattacker = {}
		special.cd_lastattacker.mo = toucher
		special.cd_lastattacker.player = toucher.player

		--Handle colorization
		special.colorized = true
		special.color = SKINCOLOR_WHITE

		--*iconic sphere noises*
		mobjthinkers[special] = 2
		special.cd_frettime = TICRATE / 8
		S_StartSound(toucher, sfx_s3k65)
		return true
	elseif special.cd_lastattacker.mo == toucher
	or special.cd_lastattacker.player == toucher.player
	or special.cd_frettime --Simulate MF2_FRET behavior
		return true
	end
end, MT_BLUESPHERE)

--Handle sudden quitting for players
addHook("PlayerQuit", function(player, reason)
	if player.cdinfo
		DestroyCDInfo(player)
	end
end)

--HUD hook!
hud.add(function(v, stplyr, cam)
	--If not previous text in buffer... (e.g. debug)
	if hudtext[1] == nil
		--And we don't want a hud...
		if stplyr.cdinfo == nil
		or CV_CDShowHud.value == 0
			return
		end

		--Otherwise generate a simple coop hud
		local i = 100
		if targetenemyct > 0
			i = enemyct * 100 / targetenemyct
		end
		hudtext[1] = i .. "%"
		hudtext[2] = "Enemy Goal:"
		if i < 25
			hudtext[1] = "\x85" .. $
		elseif i < 50
			hudtext[1] = "\x84" .. $
		elseif i < 75
			hudtext[1] = "\x81" .. $
		elseif i < 100
			hudtext[1] = "\x8A" .. $
		else
			hudtext[1] = "\x83" .. "Done!"
		end

		--Put AI leader up top if using foxBot
		i = 3
		if stplyr.ai
		and stplyr.ai.leader
		and stplyr.ai.leader.valid
		and stplyr.ai.leader.cdinfo
			i = BuildHudFor(v, stplyr, cam, stplyr.ai.leader, i, "\x83")
			stplyr.ai.leader.cdinfo.huddrawn = true

			--And realleader right below if different (e.g. dead)
			if stplyr.ai.realleader != stplyr.ai.leader
			and stplyr.ai.realleader
			and stplyr.ai.realleader.valid
			and stplyr.ai.realleader.cdinfo
				i = BuildHudFor(v, stplyr, cam, stplyr.ai.realleader, i, "\x87")
				stplyr.ai.realleader.cdinfo.huddrawn = true
			end
		end

		--Put any pinned players after
		if stplyr.cd_pinnedplayers
			for _, pin in pairs(stplyr.cd_pinnedplayers)
				if pin.valid
				and pin.cdinfo
				and not pin.cdinfo.huddrawn
					i = BuildHudFor(v, stplyr, cam, pin, i, "\x81")
					pin.cdinfo.huddrawn = true
				end
			end
		end

		--Draw rest of players
		local hudmax = CV_CDHudMaxPlayers.value
		for player in players.iterate
			if player.cdinfo
				if player != stplyr
				and not player.cdinfo.huddrawn
				and player.mo and player.mo.valid --Infers not spectator.. for now
				and player.mo.health > 0
					i = BuildHudFor(v, stplyr, cam, player, i)
				end
				player.cdinfo.huddrawn = false

				--Stop after cd_hudmaxplayers
				if i > hudmax * 4 + 2 --4 hudtext each + 2 for enemyct
					break
				end
			end
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
	for k, s in ipairs(hudtext)
		if k & 1
			v.drawString(320 - x - 30 * scale, y, s, V_SNAPTOTOP | V_SNAPTORIGHT | v.localTransFlag(), size)
		else
			v.drawString(320 - x - 34 * scale, y, s, V_SNAPTOTOP | V_SNAPTORIGHT | v.localTransFlag(), size_r)
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
		"\x87 Coop or Die! v0.x: 2021-XX-XX",
		"",
		"\x87 MP Server Admin:",
		"\x80  cd_enemyclearpct - Required % of enemies for level completion",
		"\x80  cd_enemyclearmax - Maximum # of enemies for level completion",
		"\x80  cd_resettagsondeath - Reset players' enemy tags on death?",
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
