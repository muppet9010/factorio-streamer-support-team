local LeakyFlamethrower = {}
local Commands = require("utility/commands")
local Logging = require("utility/logging")
local Utils = require("utility/utils")
local EventScheduler = require("utility/event-scheduler")
local Events = require("utility/events")
local Interfaces = require("utility/interfaces")

---@class LeakyFlamethrower_EffectEndStatus
local EffectEndStatus = {completed = "completed", died = "died", invalid = "invalid"}

---@class LeakyFlamethrower_ScheduledEventDetails
---@field target string @ Target player's name.
---@field ammoCount uint

---@class LeakyFlamethrower_ShootFlamethrowerDetails
---@field player LuaPlayer
---@field angle uint
---@field distance uint
---@field currentBurstTicks Tick
---@field burstsDone uint
---@field maxBursts uint

---@class LeakyFlamethrower_AffectedPlayersDetails
---@field flamethrowerGiven boolean @ If a flamethrower weapon had to be given to the player or if they already had one.
---@field burstsLeft uint
---@field removedWeaponDetails GiveItems_RemovedWeaponToEnsureWeapon

LeakyFlamethrower.CreateGlobals = function()
    global.leakyFlamethrower = global.leakyFlamethrower or {}
    global.leakyFlamethrower.affectedPlayers = global.leakyFlamethrower.affectedPlayers or {} ---@type table<PlayerIndex, LeakyFlamethrower_AffectedPlayersDetails>
    global.leakyFlamethrower.nextId = global.leakyFlamethrower.nextId or 0
end

LeakyFlamethrower.OnLoad = function()
    Commands.Register("muppet_streamer_leaky_flamethrower", {"api-description.muppet_streamer_leaky_flamethrower"}, LeakyFlamethrower.LeakyFlamethrowerCommand, true)
    EventScheduler.RegisterScheduledEventType("LeakyFlamethrower.ShootFlamethrower", LeakyFlamethrower.ShootFlamethrower)
    Events.RegisterHandlerEvent(defines.events.on_pre_player_died, "LeakyFlamethrower.OnPrePlayerDied", LeakyFlamethrower.OnPrePlayerDied)
    EventScheduler.RegisterScheduledEventType("LeakyFlamethrower.ApplyToPlayer", LeakyFlamethrower.ApplyToPlayer)
end

LeakyFlamethrower.OnStartup = function()
    local group = game.permissions.get_group("LeakyFlamethrower") or game.permissions.create_group("LeakyFlamethrower")
    group.set_allows_action(defines.input_action.select_next_valid_gun, false)
    group.set_allows_action(defines.input_action.toggle_driving, false)
    group.set_allows_action(defines.input_action.change_shooting_state, false)
end

---@param command CustomCommandData
LeakyFlamethrower.LeakyFlamethrowerCommand = function(command)
    local errorMessageStart = "ERROR: muppet_streamer_leaky_flamethrower command "
    local commandData
    if command.parameter ~= nil then
        commandData = game.json_to_table(command.parameter)
    end
    if commandData == nil or type(commandData) ~= "table" then
        Logging.LogPrint(errorMessageStart .. "requires details in JSON format.")
        return
    end

    local delay = 0
    if commandData.delay ~= nil then
        delay = tonumber(commandData.delay)
        if delay == nil then
            Logging.LogPrint(errorMessageStart .. "delay is Optional, but must be a non-negative number if supplied")
            return
        end
        delay = math.max(delay * 60, 0)
    end

    local target = commandData.target
    if target == nil then
        Logging.LogPrint(errorMessageStart .. "target is mandatory")
        return
    elseif game.get_player(target) == nil then
        Logging.LogPrint(errorMessageStart .. "target is invalid player name")
        return
    end

    local ammoCount = tonumber(commandData.ammoCount)
    if ammoCount == nil then
        Logging.LogPrint(errorMessageStart .. "ammoCount is mandatory as a number")
        return
    elseif ammoCount <= 0 then
        return
    end

    global.leakyFlamethrower.nextId = global.leakyFlamethrower.nextId + 1
    EventScheduler.ScheduleEvent(command.tick + delay, "LeakyFlamethrower.ApplyToPlayer", global.leakyFlamethrower.nextId, {target = target, ammoCount = ammoCount})
end

LeakyFlamethrower.ApplyToPlayer = function(eventData)
    local errorMessageStart = "ERROR: muppet_streamer_leaky_flamethrower command "
    local data = eventData.data ---@type LeakyFlamethrower_ScheduledEventDetails

    local targetPlayer = game.get_player(data.target)
    if targetPlayer == nil or not targetPlayer.valid then
        Logging.LogPrint(errorMessageStart .. "target player not found at creation time: " .. data.target)
        return
    end
    if targetPlayer.controller_type ~= defines.controllers.character or targetPlayer.character == nil then
        game.print({"message.muppet_streamer_leaky_flamethrower_not_character_controller", data.target})
        return
    end
    local targetPlayer_index = targetPlayer.index

    if global.leakyFlamethrower.affectedPlayers[targetPlayer_index] ~= nil then
        return
    end

    targetPlayer.driving = false
    -- removedWeaponDetails is always populated in our use case as we are forcing the weapon to be equiped (not allowing it to go in to the player's inventory).
    ---@typelist boolean, GiveItems_RemovedWeaponToEnsureWeapon
    local flamethrowerGiven, removedWeaponDetails = Interfaces.Call("GiveItems.EnsureHasWeapon", targetPlayer, "flamethrower", true, true)

    targetPlayer.get_inventory(defines.inventory.character_ammo).insert({name = "flamethrower-ammo", count = data.ammoCount})
    global.origionalPlayersPermissionGroup[targetPlayer_index] = global.origionalPlayersPermissionGroup[targetPlayer_index] or targetPlayer.permission_group
    targetPlayer.permission_group = game.permissions.get_group("LeakyFlamethrower")
    global.leakyFlamethrower.affectedPlayers[targetPlayer_index] = {flamethrowerGiven = flamethrowerGiven, burstsLeft = data.ammoCount, removedWeaponDetails = removedWeaponDetails}

    local startingAngle = math.random(0, 360)
    local startingDistance = math.random(2, 10)
    game.print({"message.muppet_streamer_leaky_flamethrower_start", targetPlayer.name})
    LeakyFlamethrower.ShootFlamethrower({tick = game.tick, instanceId = targetPlayer_index, data = {player = targetPlayer, angle = startingAngle, distance = startingDistance, currentBurstTicks = 0, burstsDone = 0, maxBursts = data.ammoCount}})
end

LeakyFlamethrower.ShootFlamethrower = function(eventData)
    ---@typelist LeakyFlamethrower_ShootFlamethrowerDetails, LuaPlayer, PlayerIndex
    local data, player, playerIndex = eventData.data, eventData.data.player, eventData.instanceId
    if player == nil or (not player.valid) or player.character == nil or (not player.character.valid) or player.vehicle ~= nil then
        LeakyFlamethrower.StopEffectOnPlayer(playerIndex, player, EffectEndStatus.invalid)
        return
    end

    local gunInventory, selectedGunInventoryIndex = player.get_inventory(defines.inventory.character_guns), player.character.selected_gun_index
    if gunInventory[selectedGunInventoryIndex] == nil or (not gunInventory[selectedGunInventoryIndex].valid_for_read) or gunInventory[selectedGunInventoryIndex].name ~= "flamethrower" then
        -- Flamethrower has been removed as active weapon by some script.
        LeakyFlamethrower.StopEffectOnPlayer(playerIndex, player, EffectEndStatus.invalid)
        return
    end

    local targetPos = Utils.GetPositionForAngledDistance(player.position, data.distance, data.angle)
    player.shooting_state = {state = defines.shooting.shooting_selected, position = targetPos}

    local delay = 0
    data.currentBurstTicks = data.currentBurstTicks + 1
    if data.currentBurstTicks > 100 then
        data.currentBurstTicks = 0
        data.burstsDone = data.burstsDone + 1
        global.leakyFlamethrower.affectedPlayers[playerIndex].burstsLeft = global.leakyFlamethrower.affectedPlayers[playerIndex].burstsLeft - 1
        if data.burstsDone == data.maxBursts then
            LeakyFlamethrower.StopEffectOnPlayer(playerIndex, player, EffectEndStatus.completed)
            return
        end
        data.angle = math.random(0, 360)
        data.distance = math.random(2, 10)
        player.shooting_state = {state = defines.shooting.not_shooting}
        delay = 180
    else
        data.distance = math.min(math.max(data.distance + ((math.random() * 2) - 1), 2), 10)
        data.angle = data.angle + (math.random(-10, 10))
    end

    EventScheduler.ScheduleEvent(eventData.tick + delay, "LeakyFlamethrower.ShootFlamethrower", playerIndex, data)
end

--- Called when a player has died, but before thier character is turned in to a corpse.
---@param event on_pre_player_died
LeakyFlamethrower.OnPrePlayerDied = function(event)
    LeakyFlamethrower.StopEffectOnPlayer(event.player_index, nil, EffectEndStatus.died)
end

--- Called when the effect has been stopped and the effects state and weapon changes should be undone.
--- Called when the player is alive or if they have died before their character has been affected.
---@param playerIndex PlayerIndex
---@param player LuaPlayer
---@param status LeakyFlamethrower_EffectEndStatus
LeakyFlamethrower.StopEffectOnPlayer = function(playerIndex, player, status)
    local affectedPlayer = global.leakyFlamethrower.affectedPlayers[playerIndex]
    if affectedPlayer == nil then
        return
    end

    player = player or game.get_player(playerIndex)
    local playerHasCharacter = player ~= nil and player.valid and player.character ~= nil and player.character.valid

    -- Take back any weapon and ammo from a player with a character (alive or just dead).
    if playerHasCharacter then
        if affectedPlayer.flamethrowerGiven then
            LeakyFlamethrower.TakeItemFromPlayerOrGround(player, "flamethrower", 1)
        end
        if affectedPlayer.burstsLeft > 0 then
            LeakyFlamethrower.TakeItemFromPlayerOrGround(player, "flamethrower-ammo", affectedPlayer.burstsLeft)
        end
    end

    -- Return the player's weapon and ammo filters (alive or just dead) if there were any.
    ---@typelist LuaInventory,LuaInventory, LuaPlayer
    local playerGunInventory, playerAmmoInventory, playerCharacterInventory
    local removedWeaponDetails = affectedPlayer.removedWeaponDetails
    if removedWeaponDetails.weaponFilterName ~= nil then
        playerGunInventory = playerGunInventory or player.get_inventory(defines.inventory.character_guns)
        playerGunInventory.set_filter(removedWeaponDetails.gunInventoryIndex, removedWeaponDetails.weaponFilterName)
    end
    if removedWeaponDetails.ammoFilterName ~= nil then
        playerAmmoInventory = playerAmmoInventory or player.get_inventory(defines.inventory.character_ammo)
        playerAmmoInventory.set_filter(removedWeaponDetails.gunInventoryIndex, removedWeaponDetails.ammoFilterName)
    end

    -- Return the player's weapon and/or ammo if one was removed for the flamer and the player has a character (alive or just dead).
    if playerHasCharacter then
        -- If a weapon was removed from the slot, so assuming the player still has it in their inventory return it to the weapon slot.
        if removedWeaponDetails.weaponItemName ~= nil then
            playerCharacterInventory = playerCharacterInventory or player.get_main_inventory()
            playerGunInventory = playerGunInventory or player.get_inventory(defines.inventory.character_guns)
            if playerCharacterInventory.get_item_count(removedWeaponDetails.weaponItemName) >= 1 then
                playerCharacterInventory.remove({name = removedWeaponDetails.weaponItemName, count = 1})
                playerGunInventory[removedWeaponDetails.gunInventoryIndex].set_stack({name = removedWeaponDetails.weaponItemName, count = 1})
            end
        end

        -- If an ammo item was removed from the slot, so assuming the player still has it in their inventory return it to the ammo slot.
        if removedWeaponDetails.ammoItemName ~= nil then
            playerCharacterInventory = playerCharacterInventory or player.get_main_inventory()
            playerAmmoInventory = playerAmmoInventory or player.get_inventory(defines.inventory.character_ammo)
            local ammoItemStackToReturn = playerCharacterInventory.find_item_stack(removedWeaponDetails.ammoItemName)
            if ammoItemStackToReturn ~= nil then
                playerAmmoInventory[removedWeaponDetails.gunInventoryIndex].swap_stack(ammoItemStackToReturn)
            end
        end

        -- Restore the player's active weapon back to what it was before. To handle scenarios like we removed a nuke (non active) for the flamer and thne leave them with this.
        player.character.selected_gun_index = removedWeaponDetails.beforeSelectedWeaponGunIndex
    end

    -- Return the player to their initial permission group.
    if player.permission_group.name == "LeakyFlamethrower" then
        -- If the permission group has been changed by something else don't set it back to the last non modded one.
        player.permission_group = global.origionalPlayersPermissionGroup[playerIndex]
        global.origionalPlayersPermissionGroup[playerIndex] = nil
    end

    -- Remove the flag aginst this player as being currently affected by the leaky flamethrower.
    global.leakyFlamethrower.affectedPlayers[playerIndex] = nil

    -- Print a message based on ending status.
    if status == EffectEndStatus.completed then
        game.print({"message.muppet_streamer_leaky_flamethrower_stop", player.name})
    end
end

LeakyFlamethrower.TakeItemFromPlayerOrGround = function(player, itemName, itemCount)
    local removed = 0
    removed = removed + player.remove_item({name = itemName, count = itemCount})
    if itemCount == 0 then
        return removed
    end

    local itemsOnGround = player.surface.find_entities_filtered {position = player.position, radius = 10, name = "item-on-ground"}
    for _, itemOnGround in pairs(itemsOnGround) do
        if itemOnGround.valid and itemOnGround.stack ~= nil and itemOnGround.stack.valid and itemOnGround.stack.name == itemName then
            itemOnGround.destroy()
            removed = removed + 1
            itemCount = itemCount - 1
            if itemCount == 0 then
                break
            end
        end
    end
    return removed
end

return LeakyFlamethrower
