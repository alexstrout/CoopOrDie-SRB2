Coop or Die! v1.0
=================
An experiment in cooperative gameplay mechanics for a 3D platformer (in this case SRB2).

![Coop Bop](Media/srb20229_cf.gif)

Features
--------
* Cooperative HUD displaying teammate location and status information
* "Tagging" mechanics that require two players to damage enemies or collect special stage spheres
* Enemy Goal system requiring a certain percentage of enemies to be defeated in order to progress
* Team life sharing with revive mechanics tied to level progression (Starposts, Enemy Goal, etc.)
* Support for various AI bots like [BuddyEx](https://mb.srb2.org/addons/buddyex.1422/), [ExAI](https://mb.srb2.org/addons/exai-extended-behavior-for-sp-bots.1200/), and [foxBot](https://github.com/alexstrout/foxBot-SRB2)
* Performance-focused with minimal script hooks, to remain playable on low-spec devices
* Highly configurable, with options to toggle all features

Console Commands / Variables
----------------------------
Use `cdhelp` to display this section in-game at any time.

**MP Server Admin:**
* `cd_enemyclearpct` - Required % of enemies for level completion
* `cd_enemyclearmax` - Maximum # of enemies for level completion
* `cd_dmflags` - Difficulty modifier flags:
  * *(1 = Enemies require 2+ hits from different players)*
  * *(2 = Spheres require 2 pickups from different players)*
  * *(4 = Special Stages restrict time based on player count)*
  * *(8 = Team lives are shared using 1up revive mechanics)*
  * *(16 = Players reset their tagged enemy hits on death)*
  * Note: These options can be combined by adding them together!

**MP Client:**
* `cd_showhud` - Draw CoopOrDie info to HUD?
* `cd_hudmaxplayers` - Maximum # of players to draw on HUD
* `pinplayer <player>` - Pin *player* to HUD
* `unpinplayer <player>` - Unpin *player* from HUD *("all" = all players)*
* `listplayers` - List active players"
