--!strict
--[[
	Server entry point. This Script lives at ServerScriptService.Server.
	It loads every ModuleScript under Server/Services as a Knit service,
	then starts Knit. Add a service by dropping a new file in Services/.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Packages.Knit)

Knit.AddServices(script.Services)

Knit.Start()
	:andThen(function()
		print("[MotoJoust] Server started")
	end)
	:catch(function(err)
		warn("[MotoJoust] Server failed to start: " .. tostring(err))
	end)
