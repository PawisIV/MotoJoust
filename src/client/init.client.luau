--!strict
--[[
	Client entry point. This LocalScript lives at
	StarterPlayer.StarterPlayerScripts.Client. It loads every ModuleScript
	under Client/Controllers as a Knit controller, then starts Knit.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Packages.Knit)

Knit.AddControllers(script.Controllers)

Knit.Start()
	:andThen(function()
		print("[MotoJoust] Client started")
	end)
	:catch(function(err)
		warn("[MotoJoust] Client failed to start: " .. tostring(err))
	end)
