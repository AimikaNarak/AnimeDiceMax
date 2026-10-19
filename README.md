# AnimeDiceMax

Anime Dice farm + chain builder: farms each account until it is maxed (rebirth, top dice, every upgrade),
then trades its units and gear to the next account in the chain.

## Use

1. Copy `Loader.lua`, edit the `getgenv().AnimeDice` table (comments are in Thai).
2. Put it in your executor's auto-execute (or your account manager's script box) so it runs on every join.

```lua
getgenv().AnimeDice = { --[[ your config, see Loader.lua ]] }
loadstring(game:HttpGet("https://raw.githubusercontent.com/AimikaNarak/AnimeDiceMax/main/AnimeDiceMax.lua"))()
```

- Chain accounts must all run on the same PC (they coordinate through files in the executor workspace `AnimeDice/chain/`).
- Account managers: Horst, Masterp, Storm (`Manager = "Auto" | "Horst" | "Masterp" | "Storm" | "None"`).
- Toggle the window with RightCtrl.
