--Basic init
-- rawset(_G, "__CoopOrDie_1", {})

--VSCode Lua Language Server hints
---@class player_t
---CoopOrDie info table
---@field cdinfo table
---CoopOrDie currently pinned players
---@field cd_pinnedplayers table

---@class mobj_t
---CoopOrDie enemy "active" for damage hooks etc.
---@field cd_active boolean
---CoopOrDie last attacker
---@field cd_lastattacker table

---@class mobjinfo_t
---CoopOrDie enemies ineligible for enemyct / targetenemyct
---
---These are signified by not having damage mechanics applied
---@field cd_skipcount boolean
---CoopOrDie enemies that bots should spin-attack when tagged
---@field cd_aispinattack boolean
---CoopOrDie enemies that bots should prioritize when tagged
---@field cd_aipriority boolean
