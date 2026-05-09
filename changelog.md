v1.2 (2026-xx-xx):
------------------
* Fix potential desync issue w/ team revive queue
* Fix team lives persisting across sessions
* Initialize properly if loaded mid-level
* Improve coop HUD issues, sorting by distance w/ default 4p max
* Add `cd_hudsorttime` for HUD sort interval
* Add `pinplayer2` / `unpinplayer2` for splitscreen use
* Allow partial names for `pinplayer` etc. instead of only numbers
* Code cleanup!

v1.1 (2021-06-11):
------------------
* Fix potentially getting stuck in a "warp loop" on custom level exit triggers
* Fix team lives not honoring `startinglives` in multiplayer / saved life count in singleplayer
* Fix Enemy Goal getting incorrectly set after retrying a NoReload level
* Fix always getting a reward shield in singleplayer after retrying a level
* Fix starposts randomly granting team lives after retrying a level
* Allow the team life sound (S3D Chirp) to play any time we've gained a team life
* Add a minor coop HUD notification when enemies are defeated
* Add separate `cd_teamlives` option for team life sharing (instead of it being a `cd_dmflags` flag)
* Add `cd_emeraldbonus` option for bonus ring / shield award on spawn w/ all emeralds

v1.0 (2021-05-09):
------------------
* Initial release
