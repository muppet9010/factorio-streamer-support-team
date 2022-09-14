local PlayerDropInventory = {} ---@class PlayerDropInventory
local CommandsUtils = require("utility.helper-utils.commands-utils")
local EventScheduler = require("utility.manager-libraries.event-scheduler")
local Events = require("utility.manager-libraries.events")
local Common = require("scripts.common")
local MathUtils = require("utility.helper-utils.math-utils")
local math_rad, math_sin, math_cos, math_pi, math_random, math_ceil, math_sqrt, math_log = math.rad, math.sin, math.cos, math.pi, math.random, math.ceil, math.sqrt, math.log

---@enum PlayerDropInventory_QuantityType
local QuantityType = {
    constant = "constant",
    startingPercentage = "startingPercentage",
    realtimePercentage = "realtimePercentage"
}

---@class PlayerDropInventory_ApplyDropItemsData
---@field target string
---@field quantityType PlayerDropInventory_QuantityType
---@field quantityValue uint
---@field dropOnBelts boolean
---@field gap uint # Must be > 0.
---@field occurrences uint
---@field dropEquipment boolean
---@field distributionInnerDensity double # 0 to 1.
---@field distributionOuterDensity double # 0 to 1.
---@field suppressMessages boolean

---@class PlayerDropInventory_ScheduledDropItemsData
---@field player_index uint
---@field player LuaPlayer
---@field gap uint # Must be > 0.
---@field totalOccurrences uint
---@field dropOnBelts boolean
---@field dropEquipment boolean
---@field staticItemCount uint|nil
---@field dynamicPercentageItemCount uint|nil
---@field currentOccurrences uint
---@field distributionInnerDensity double # 0 to 1.
---@field distributionOuterDensity double # 0 to 1.
---@field suppressMessages boolean

---@alias PlayerDropInventory_InventoryItemCounts table<defines.inventory|"cursorStack", uint> # Dictionary of each inventory to a cached total count across all items (count of each item all added together) were in that inventory.
---@alias PlayerDropInventory_InventoryContents table<defines.inventory|"cursorStack", table<string, uint>> # Dictionary of each inventory to a cached list of item name and counts in that inventory.

local commandName = "muppet_streamer_player_drop_inventory"

PlayerDropInventory.CreateGlobals = function()
    global.playerDropInventory = global.playerDropInventory or {}
    global.playerDropInventory.affectedPlayers = global.playerDropInventory.affectedPlayers or {} ---@type table<uint, true> # A dictionary of player indexes that have the effect active on them currently.
    global.playerDropInventory.nextId = global.playerDropInventory.nextId or 0 ---@type uint
end

PlayerDropInventory.OnLoad = function()
    CommandsUtils.Register("muppet_streamer_player_drop_inventory", { "api-description.muppet_streamer_player_drop_inventory" }, PlayerDropInventory.PlayerDropInventoryCommand, true)
    EventScheduler.RegisterScheduledEventType("PlayerDropInventory.PlayerDropItems_Scheduled", PlayerDropInventory.PlayerDropItems_Scheduled)
    Events.RegisterHandlerEvent(defines.events.on_pre_player_died, "PlayerDropInventory.OnPrePlayerDied", PlayerDropInventory.OnPrePlayerDied)
    EventScheduler.RegisterScheduledEventType("PlayerDropInventory.ApplyToPlayer", PlayerDropInventory.ApplyToPlayer)
    MOD.Interfaces.Commands.PlayerDropInventory = PlayerDropInventory.PlayerDropInventoryCommand
end

---@param command CustomCommandData
PlayerDropInventory.PlayerDropInventoryCommand = function(command)
    local commandData = CommandsUtils.GetSettingsTableFromCommandParameterString(command.parameter, true, commandName, { "delay", "target", "quantityType", "quantityValue", "dropOnBelts", "gap", "occurrences", "dropEquipment", "distributionInnerDensity", "distributionOuterDensity", "suppressMessages" })
    if commandData == nil then
        return
    end

    local delaySeconds = commandData.delay
    if not CommandsUtils.CheckNumberArgument(delaySeconds, "double", false, commandName, "delay", 0, nil, command.parameter) then
        return
    end ---@cast delaySeconds double|nil
    local scheduleTick = Common.DelaySecondsSettingToScheduledEventTickValue(delaySeconds, command.tick, commandName, "delay")

    local target = commandData.target
    if not Common.CheckPlayerNameSettingValue(target, commandName, "target", command.parameter) then
        return
    end ---@cast target string

    local quantityType_string = commandData.quantityType
    if not CommandsUtils.CheckStringArgument(quantityType_string, true, commandName, "quantityType", QuantityType, command.parameter) then
        return
    end ---@cast quantityType_string string
    local quantityType = QuantityType[quantityType_string] ---@type PlayerDropInventory_QuantityType

    local quantityValue = commandData.quantityValue
    if not CommandsUtils.CheckNumberArgument(quantityValue, "int", true, commandName, "quantityValue", 1, MathUtils.uintMax, command.parameter) then
        return
    end ---@cast quantityValue uint

    local dropOnBelts = commandData.dropOnBelts
    if not CommandsUtils.CheckBooleanArgument(dropOnBelts, false, commandName, "dropOnBelts", command.parameter) then
        return
    end ---@cast dropOnBelts boolean|nil
    if dropOnBelts == nil then
        dropOnBelts = false
    end

    local gapSeconds = commandData.gap
    if not CommandsUtils.CheckNumberArgument(gapSeconds, "double", true, commandName, "gap", 1 / 60, math.floor(MathUtils.uintMax / 60), command.parameter) then
        return
    end ---@cast gapSeconds double
    local gap = math.floor(gapSeconds * 60) --[[@as uint # gapSeconds was validated as not exceeding a uint during input validation.]]

    local occurrences = commandData.occurrences
    if not CommandsUtils.CheckNumberArgument(occurrences, "int", true, commandName, "occurrences", 1, MathUtils.uintMax, command.parameter) then
        return
    end ---@cast occurrences uint

    local dropEquipment = commandData.dropEquipment
    if not CommandsUtils.CheckBooleanArgument(dropEquipment, false, commandName, "dropEquipment", command.parameter) then
        return
    end ---@cast dropEquipment boolean|nil
    if dropEquipment == nil then
        dropEquipment = true
    end

    local distributionInnerDensity = commandData.distributionInnerDensity
    if not CommandsUtils.CheckNumberArgument(distributionInnerDensity, "double", false, commandName, "distributionInnerDensity", 0, 1, command.parameter) then
        return
    end ---@cast distributionInnerDensity double
    if distributionInnerDensity == nil then
        distributionInnerDensity = 1
    end

    local distributionOuterDensity = commandData.distributionOuterDensity
    if not CommandsUtils.CheckNumberArgument(distributionOuterDensity, "double", false, commandName, "distributionOuterDensity", 0, 1, command.parameter) then
        return
    end ---@cast distributionOuterDensity double
    if distributionOuterDensity == nil then
        distributionOuterDensity = 0
    end

    local suppressMessages = commandData.suppressMessages
    if not CommandsUtils.CheckBooleanArgument(suppressMessages, false, commandName, "suppressMessages", command.parameter) then
        return
    end ---@cast suppressMessages boolean|nil
    if suppressMessages == nil then
        suppressMessages = false
    end

    global.playerDropInventory.nextId = global.playerDropInventory.nextId + 1
    ---@type PlayerDropInventory_ApplyDropItemsData
    local applyDropItemsData = { target = target, quantityType = quantityType, quantityValue = quantityValue, dropOnBelts = dropOnBelts, gap = gap, occurrences = occurrences, dropEquipment = dropEquipment, distributionInnerDensity = distributionInnerDensity, distributionOuterDensity = distributionOuterDensity, suppressMessages = suppressMessages }
    EventScheduler.ScheduleEventOnce(scheduleTick, "PlayerDropInventory.ApplyToPlayer", global.playerDropInventory.nextId, applyDropItemsData)
end

--- Prepare to apply the effect to the player.
PlayerDropInventory.ApplyToPlayer = function(event)
    local data = event.data ---@type PlayerDropInventory_ApplyDropItemsData

    local targetPlayer = game.get_player(data.target)
    if targetPlayer == nil then
        CommandsUtils.LogPrintWarning(commandName, nil, "Target player has been deleted since the command was run.", nil)
        return
    end
    local targetPlayer_index = targetPlayer.index
    if targetPlayer.controller_type ~= defines.controllers.character or targetPlayer.character == nil then
        -- Player not alive or in non playing mode.
        if not data.suppressMessages then game.print({ "message.muppet_streamer_player_drop_inventory_not_character_controller", data.target }) end
        return
    end

    -- If the effect is always set on this player don't start a new one.
    if global.playerDropInventory.affectedPlayers[targetPlayer_index] ~= nil then
        if not data.suppressMessages then game.print({ "message.muppet_streamer_duplicate_command_ignored", "Player Drop Inventory", data.target }) end
        return
    end

    -- Work out how many items to drop per cycle here if its a starting number type.
    ---@type uint|nil, uint|nil
    local staticItemCount, dynamicPercentageItemCount
    if data.quantityType == QuantityType.constant then
        staticItemCount = data.quantityValue
    elseif data.quantityType == QuantityType.startingPercentage then
        local totalItemCount = PlayerDropInventory.GetPlayersItemCount(targetPlayer, data.dropEquipment)
        staticItemCount = math.max(1, math.floor(totalItemCount / (100 / data.quantityValue))) -- Output will always be a uint based on the input values prior validation.
    elseif data.quantityType == QuantityType.realtimePercentage then
        dynamicPercentageItemCount = data.quantityValue
    end

    -- Record the player as having this effect running on them so it can't be started a second time.
    global.playerDropInventory.affectedPlayers[targetPlayer_index] = true

    -- Do the first effect now.
    if not data.suppressMessages then game.print({ "message.muppet_streamer_player_drop_inventory_start", targetPlayer.name }) end
    ---@type PlayerDropInventory_ScheduledDropItemsData
    local scheduledDropItemsData = {
        player_index = targetPlayer_index,
        player = targetPlayer,
        gap = data.gap,
        totalOccurrences = data.occurrences,
        dropOnBelts = data.dropOnBelts,
        dropEquipment = data.dropEquipment,
        staticItemCount = staticItemCount,
        dynamicPercentageItemCount = dynamicPercentageItemCount,
        currentOccurrences = 0,
        distributionInnerDensity = data.distributionInnerDensity,
        distributionOuterDensity = data.distributionOuterDensity,
        suppressMessages = data.suppressMessages
    }
    PlayerDropInventory.PlayerDropItems_Scheduled({ tick = event.tick, instanceId = scheduledDropItemsData.player_index, data = scheduledDropItemsData })
end

--- Apply the drop item effect to the player.
---@param event UtilityScheduledEvent_CallbackObject
PlayerDropInventory.PlayerDropItems_Scheduled = function(event)
    local data = event.data ---@type PlayerDropInventory_ScheduledDropItemsData
    local player, playerIndex = data.player, data.player_index
    if player == nil or (not player.valid) or player.character == nil or (not player.character.valid) then
        PlayerDropInventory.StopEffectOnPlayer(playerIndex)
        return
    end

    -- Get the details about the items in the inventory. This allows us to do most of the processing off this cached data.
    -- Updates these item stats as it loops over them and drops one item at a time.
    -- Includes:
    --      - total items in all inventories - used to work out the range of our random item selection (by index).
    --      - total items in each inventory - used to work out which inventory has the item we want as can just use these totals, rather than having to repeatedly count the cached contents counts.
    --      - item name and count in each inventory - used to define what item to drop for a given index in an inventory.
    local totalItemCount, itemsCountsInInventories, inventoriesContents = PlayerDropInventory.GetPlayersInventoryItemDetails(player, data.dropEquipment)

    -- Get the number of items to drop this event.
    local itemCountToDrop
    if data.staticItemCount ~= nil then
        itemCountToDrop = data.staticItemCount

        -- Cap the itemCountToDrop at the totalItemCount if it's lower. Makes later logic simpler.
        itemCountToDrop = math.min(itemCountToDrop, totalItemCount)
    else
        itemCountToDrop = math.max(1, math.floor(totalItemCount / (100 / data.dynamicPercentageItemCount))) --[[@as uint # End value will always end up as a uint from the validated input values.]]
    end ---@cast itemCountToDrop -nil

    -- Only try and drop items if there are any to drop in the player's inventories. We want the code to keep on running for future iterations until the occurrence count has completed.
    if totalItemCount > 0 and itemCountToDrop > 0 then
        local itemCountDropped = 1
        local surface = player.surface
        local position = player.position
        local centerPosition_x, centerPosition_y = position.x, position.y
        local maxRadius = math.ceil(math.sqrt(itemCountToDrop) * 0.5)
        -- TODO: this should be a setting passed in.
        -- TODO: there's no hard edge limit with this, so it always softens out.
        -- TODO: not sure if this truly scales right with max radius, as it looks like more over compression in center. Maybe need even higher min density value. The max radius doesn't seem to grow enough with larger quantities and so more ends up near the center thus making the density higher.
        local density = 0.25 -- Max non overlapping density is 0.175. But this does have a lot of overlap in placing items and so higher UPS hit. A value of like 0.25 seems to avoid this lag spike from overlapping items having to look for new places to go.

        -- Drop a single random item from across the range of inventories at a time until the required number of items have been dropped.
        -- CODE NOTE: This is quite Lua code inefficient, but does ensure truly random items are dropped.
        while itemCountDropped <= itemCountToDrop do
            -- Select the single random item number to be dropped from across the total item count.
            local itemNumberToDrop = math.random(1, totalItemCount)

            -- Find the inventory with this item number in it. Update the per inventory total item counts.
            local inventoryNameOfItemNumberToDrop, itemNumberInSpecificInventory
            local itemCountedUpTo = 0
            for inventoryName, countInInventory in pairs(itemsCountsInInventories) do
                itemCountedUpTo = itemCountedUpTo + countInInventory
                if itemCountedUpTo >= itemNumberToDrop then
                    inventoryNameOfItemNumberToDrop = inventoryName
                    itemNumberInSpecificInventory = itemNumberToDrop - (itemCountedUpTo - countInInventory)
                    itemsCountsInInventories[inventoryName] = countInInventory - 1
                    break
                end
            end
            if inventoryNameOfItemNumberToDrop == nil then
                CommandsUtils.LogPrintError(commandName, nil, "didn't find item number " .. itemNumberToDrop .. " when looking over " .. player.name .. "'s inventories.", nil)
                return
            end

            -- Find the name of the numbered item in the specific inventory. Update the cached lists to remove 1 from this item's count.
            local itemNameToDrop
            local inventoryItemsCounted = 0
            for itemName, itemCount in pairs(inventoriesContents[inventoryNameOfItemNumberToDrop]) do
                inventoryItemsCounted = inventoryItemsCounted + itemCount
                if inventoryItemsCounted >= itemNumberInSpecificInventory then
                    itemNameToDrop = itemName
                    inventoriesContents[inventoryNameOfItemNumberToDrop][itemName] = itemCount - 1
                    break
                end
            end
            if itemNameToDrop == nil then
                CommandsUtils.LogPrintError(commandName, nil, "didn't find item name for number " .. itemNumberToDrop .. " in " .. player.name .. "'s inventory id " .. inventoryNameOfItemNumberToDrop, nil)
                return
            end

            -- Identify and record the specific item being dropped.
            local itemStackToDropFrom ---@type LuaItemStack|nil
            if inventoryNameOfItemNumberToDrop == "cursorStack" then
                -- Special case as not a real inventory.
                itemStackToDropFrom = player.cursor_stack ---@cast itemStackToDropFrom -nil # We know the cursor_stack is populated if its gone down this logic path.
            else
                local inventory = player.get_inventory(inventoryNameOfItemNumberToDrop)
                if inventory == nil then
                    CommandsUtils.LogPrintError(commandName, nil, "didn't find inventory id " .. inventoryNameOfItemNumberToDrop .. "' for " .. player.name, nil)
                    return
                end
                itemStackToDropFrom = inventory.find_item_stack(itemNameToDrop)
                if itemStackToDropFrom == nil then
                    CommandsUtils.LogPrintError(commandName, nil, "didn't find item stack for item '" .. itemNameToDrop .. "' in " .. player.name .. "'s inventory id " .. inventoryNameOfItemNumberToDrop, nil)
                    return
                end
            end
            local itemStackToDropFrom_count = itemStackToDropFrom.count
            local itemToPlaceOnGround
            if itemStackToDropFrom_count == 1 then
                -- Single item in the itemStack so drop it and all done. This handles any extra attributes the itemStack may have naturally.
                itemToPlaceOnGround = itemStackToDropFrom
            else
                -- Multiple items in the itemStack so can just drop 1 copy of the itemStack details and remove 1 from count.
                -- CODE NOTE: ItemStacks are grouped by Factorio in to full health or damaged (health averaged across all items in itemStack).
                -- CODE NOTE: ItemStacks have a single durability and ammo stat which effectively is for the first item in the itemStack, with the other items in the itemStack all being full.
                -- CODE NOTE: when the itemStack's count is reduced by 1 the itemStacks durability and ammo fields are reset to full. As the first item is considered to be the partially used items.
                itemToPlaceOnGround = { name = itemStackToDropFrom.name, count = 1, health = itemStackToDropFrom.health, durability = itemStackToDropFrom.durability }
                if itemStackToDropFrom.type == "ammo" then
                    itemToPlaceOnGround.ammo = itemStackToDropFrom.ammo
                end
                if itemStackToDropFrom.is_item_with_tags then
                    itemToPlaceOnGround.tags = itemStackToDropFrom.tags
                end
            end

            -- Work out where to put the item on the ground.
            local angle = math_pi * 2 * math_random()
            local radius = (maxRadius * math_sqrt(-density * math_log(math_random())))
            local position = { x = centerPosition_x + radius * math_cos(angle), y = centerPosition_y + radius * math_sin(angle) }
            surface.spill_item_stack(position, itemToPlaceOnGround, false, nil, data.dropOnBelts)

            -- Remove 1 from the source item stack. This may make it 0, so have to this after placing it on the ground as in some cases we reference it.
            itemStackToDropFrom.count = itemStackToDropFrom_count - 1

            -- Count that the item was dropped and update the total items in all inventory count.
            itemCountDropped = itemCountDropped + 1
            totalItemCount = totalItemCount - 1

            -- If no items left stop trying to drop things this event and await the next one.
            if totalItemCount == 0 then
                itemCountDropped = itemCountToDrop + 1
            end
        end
    end

    -- Schedule the next occurrence if we haven't completed them all yet.
    data.currentOccurrences = data.currentOccurrences + 1
    if data.currentOccurrences < data.totalOccurrences then
        EventScheduler.ScheduleEventOnce(event.tick + data.gap, "PlayerDropInventory.PlayerDropItems_Scheduled", playerIndex, data)
    else
        PlayerDropInventory.StopEffectOnPlayer(playerIndex)
        if not data.suppressMessages then game.print({ "message.muppet_streamer_player_drop_inventory_stop", player.name }) end
    end
end

---@param event on_pre_player_died
PlayerDropInventory.OnPrePlayerDied = function(event)
    PlayerDropInventory.StopEffectOnPlayer(event.player_index)
end

---@param playerIndex uint
PlayerDropInventory.StopEffectOnPlayer = function(playerIndex)
    if global.playerDropInventory.affectedPlayers[playerIndex] == nil then
        return
    end

    global.playerDropInventory.affectedPlayers[playerIndex] = nil
    EventScheduler.RemoveScheduledOnceEvents("PlayerDropInventory.PlayerDropItems_Scheduled", playerIndex)
end

---@param player LuaPlayer
---@param includeEquipment boolean
---@return uint totalItemsCount
PlayerDropInventory.GetPlayersItemCount = function(player, includeEquipment)
    local totalItemsCount = 0 ---@type uint
    for _, inventoryName in pairs({ defines.inventory.character_main, defines.inventory.character_trash }) do
        for _, count in pairs(player.get_inventory(inventoryName).get_contents()) do
            totalItemsCount = totalItemsCount + count
        end
    end
    local cursorStack = player.cursor_stack
    if cursorStack ~= nil and cursorStack.valid_for_read then
        totalItemsCount = totalItemsCount + cursorStack.count
    end

    if includeEquipment then
        for _, inventoryName in pairs({ defines.inventory.character_armor, defines.inventory.character_guns, defines.inventory.character_ammo }) do
            for _, count in pairs(player.get_inventory(inventoryName).get_contents()) do
                totalItemsCount = totalItemsCount + count
            end
        end
    end

    return totalItemsCount
end

---@param player LuaPlayer
---@param includeEquipment boolean
---@return uint totalItemsCount
---@return PlayerDropInventory_InventoryItemCounts inventoryItemCounts
---@return PlayerDropInventory_InventoryContents inventoryContents
PlayerDropInventory.GetPlayersInventoryItemDetails = function(player, includeEquipment)
    local totalItemsCount = 0 ---@type uint
    local inventoryItemCounts = {} ---@type PlayerDropInventory_InventoryItemCounts
    local inventoryContents = {} ---@type PlayerDropInventory_InventoryContents
    for _, inventoryName in pairs({ defines.inventory.character_main, defines.inventory.character_trash }) do
        local contents = player.get_inventory(inventoryName).get_contents()
        inventoryContents[inventoryName] = contents
        local inventoryTotalCount = 0 ---@type uint
        for _, count in pairs(contents) do
            inventoryTotalCount = inventoryTotalCount + count
        end
        totalItemsCount = totalItemsCount + inventoryTotalCount
        inventoryItemCounts[inventoryName] = inventoryTotalCount
    end
    local cursorStack = player.cursor_stack
    if cursorStack ~= nil and cursorStack.valid_for_read then
        local count = cursorStack.count
        totalItemsCount = totalItemsCount + count
        inventoryItemCounts["cursorStack"] = count
        inventoryContents["cursorStack"] = { [cursorStack.name] = count }
    end

    if includeEquipment then
        for _, inventoryName in pairs({ defines.inventory.character_armor, defines.inventory.character_guns, defines.inventory.character_ammo }) do
            local contents = player.get_inventory(inventoryName).get_contents()
            inventoryContents[inventoryName] = contents
            local inventoryTotalCount = 0 ---@type uint
            for _, count in pairs(contents) do
                inventoryTotalCount = inventoryTotalCount + count
            end
            totalItemsCount = totalItemsCount + inventoryTotalCount
            inventoryItemCounts[inventoryName] = inventoryTotalCount
        end
    end

    return totalItemsCount, inventoryItemCounts, inventoryContents
end

--[[
    -- Using Gaussian model. Seems very middle focused. This would then need to be converted in to circles on a map somehow...

    function gaussian (mean, variance)
        return math.sqrt(-2 * variance * math.log(math.random())) * math.cos(2 * math.pi * math.random()) + mean
    end

    function showHistogram (t)
        local lo = math.ceil(math.min(table.unpack(t)))
        local hi = math.floor(math.max(table.unpack(t)))
        local hist, barScale = {}, 200
        for i = lo, hi do
            hist[i] = 0
            for k, v in pairs(t) do
                if math.ceil(v - 0.5) == i then
                    hist[i] = hist[i] + 1
                end
            end
            io.write(i .. "\t" .. string.rep('=', math.ceil(hist[i] / #t * barScale)))
            print(" " .. hist[i])
        end
    end

    -- These 2 values control the shape of it.
    local t, average, variance = {}, 50, 10
    for i = 1, 1000 do
        table.insert(t, gaussian(average, variance))
    end
    showHistogram(t)
]]

--[[
    -- Lua Demo

    local itemsPerTileCircumference = 12

    local distanceDensities = {
      {distance = 3, density = 1},
      {distance = 5, density = 0.8},
      {distance = 7, density = 0.6},
      {distance = 9, density = 0.4},
      {distance = 11, density = 0.2}
    }

    local totalRings, totalItems = 0, 0
    for ringIndex , data in pairs(distanceDensities) do
      local currentDistanceFromCenter, currentDensity = data.distance, data.density
      local itemsInThisRadius = math.ceil((tonumber(currentDistanceFromCenter) * 2 *
    math.pi) * (itemsPerTileCircumference * currentDensity))
      io.write(currentDistanceFromCenter .. " = " .. itemsInThisRadius .. "\r\n")
      totalRings = ringIndex
      totalItems = totalItems + itemsInThisRadius
    end

    io.write("\r\n")
    io.write("totalRings" .. " = " .. totalRings .. "\r\n")
    io.write("totalItems" .. " = " .. totalItems .. "\r\n")

    io.write("\r\n")
    local itemCount = 150
    local testDensity = itemCount / ((3* 2 * math.pi) * (itemsPerTileCircumference))
    local itemsInThisRadius = math.ceil((3 * 2 *
    math.pi) * (itemsPerTileCircumference * testDensity ))
    io.write("test - density = " .. testDensity .. "   items = " .. itemsInThisRadius .. "\r\n")
]]

return PlayerDropInventory
