local Events = require("utility/events")
local Freeplay = require("scripts/freeplay")
local TeamMember = require("scripts/team-member")
local ExplosiveDelivery = require("scripts/explosive-delivery")
local LeakyFlamethrower = require("scripts/leaky-flamethrower")
local EventScheduler = require("utility/event-scheduler")

local function CreateGlobals()
    TeamMember.CreateGlobals()
    ExplosiveDelivery.CreateGlobals()
    LeakyFlamethrower.CreateGlobals()
end

local function OnLoad()
    --Any Remote Interface registration calls can go in here or in root of control.lua
    remote.remove_interface("muppet_streamer")
    Freeplay.OnLoad()
    TeamMember.OnLoad()
    ExplosiveDelivery.OnLoad()
    LeakyFlamethrower.OnLoad()
end

local function OnStartup()
    CreateGlobals()
    OnLoad()
    Events.RaiseInternalEvent({name = defines.events.on_runtime_mod_setting_changed})

    Freeplay.OnStartup()
    TeamMember.OnStartup()
end

script.on_init(OnStartup)
script.on_configuration_changed(OnStartup)
script.on_load(OnLoad)
EventScheduler.RegisterScheduler()
