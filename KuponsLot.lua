_addon.name = 'KuponsLot'
_addon.author = 'n0gr1p + OpenAI'
_addon.version = '0.1.0'
_addon.commands = {'kuponslot', 'kuponlot', 'klot'}

local packets = require('packets')
local res = require('resources')
local config = require('config')
local socket_ok, socket = pcall(require, 'socket')

local KUPON_ITEM_ID = 3442
local KUPON_NAME = 'Kupon I-Seal'

local POOL_DEBOUNCE_SECONDS = 0.30
local STATE_COLLECTION_SECONDS = 1.25
local STATE_REFRESH_SECONDS = 0.35
local LOT_RETRY_SECONDS = 0.80
local LOT_FAIL_SECONDS = 3.00
local ASSIGNMENT_TIMEOUT_SECONDS = 4.00
local TICK_SECONDS = 0.05

local BAG_NAMES = {
    'inventory',
    'safe',
    'safe2',
    'storage',
    'locker',
    'satchel',
    'sack',
    'case',
}

local defaults = {
    Enabled = true,
    Observe = false,
    Verbose = false,
}

local settings = config.load(defaults)
local inventory_id = res.bags:with('english', 'Inventory').id

local pool_check_due = nil
local cycle = nil
local handled_drop_keys = {}
local leader_assignments = {}
local local_pending_lots = {}
local last_tick = 0

local handle_assignment

local function now()
    if socket_ok and socket and socket.gettime then
        return socket.gettime()
    end
    return os.clock()
end

local function chat(message, color)
    windower.add_to_chat(color or 207, '[KuponsLot] ' .. tostring(message))
end

local function verbose(message)
    if settings.Verbose then
        chat(message, 160)
    end
end

local function player_name()
    local player = windower.ffxi.get_player()
    return player and player.name or nil
end

local function current_zone()
    local info = windower.ffxi.get_info()
    return info and info.logged_in and tonumber(info.zone) or nil
end

local function tokenize(message)
    local result = {}
    for token in tostring(message):gmatch('%S+') do
        result[#result + 1] = token
    end
    return result
end

local function local_mode()
    if not settings.Enabled then
        return 'off'
    end
    if settings.Observe then
        return 'observe'
    end
    return 'auto'
end

local function bool_arg(value)
    if value == nil then return nil end
    value = tostring(value):lower()
    if value == 'on' or value == '1' or value == 'true' or value == 'yes' then
        return true
    end
    if value == 'off' or value == '0' or value == 'false' or value == 'no' then
        return false
    end
    return nil
end

local function stack_size()
    local item = res.items[KUPON_ITEM_ID]
    return (item and tonumber(item.stack)) or 99
end

local function physical_total()
    local total = 0
    local items = windower.ffxi.get_items() or {}

    for _, bag_name in ipairs(BAG_NAMES) do
        local bag = items[bag_name]
        if type(bag) == 'table' then
            for _, item in pairs(bag) do
                if type(item) == 'table' and tonumber(item.id) == KUPON_ITEM_ID then
                    total = total + (tonumber(item.count) or 0)
                end
            end
        end
    end

    return total
end

local function inventory_capacity()
    local inventory = windower.ffxi.get_items(inventory_id)
    if type(inventory) ~= 'table' then
        return nil
    end

    local per_stack = stack_size()
    local room_in_stacks = 0

    for _, item in pairs(inventory) do
        if type(item) == 'table' and tonumber(item.id) == KUPON_ITEM_ID then
            local count = tonumber(item.count) or 0
            if count < per_stack then
                room_in_stacks = room_in_stacks + (per_stack - count)
            end
        end
    end

    local maximum = tonumber(inventory.max) or 0
    local used = tonumber(inventory.count) or 0
    local free_slots = math.max(0, maximum - used)
    return room_in_stacks + (free_slots * per_stack)
end

local function state_for_local()
    local capacity = inventory_capacity()
    return {
        name = player_name(),
        zone = current_zone(),
        mode = local_mode(),
        valid = capacity ~= nil,
        capacity = math.max(0, tonumber(capacity) or 0),
        total = physical_total(),
    }
end

local function current_pool_entries()
    local items = windower.ffxi.get_items() or {}
    local treasure = items.treasure or {}
    local entries = {}

    for slot = 0, 9 do
        local item = treasure[slot]
        if type(item) == 'table' and tonumber(item.item_id) == KUPON_ITEM_ID then
            local timestamp = tonumber(item.timestamp) or 0
            local drop_key = string.format('%d-%d-%d', slot, KUPON_ITEM_ID, timestamp)
            entries[#entries + 1] = {
                slot = slot,
                item_id = KUPON_ITEM_ID,
                timestamp = timestamp,
                drop_key = drop_key,
            }
        end
    end

    table.sort(entries, function(a, b)
        if a.slot ~= b.slot then return a.slot < b.slot end
        if a.timestamp ~= b.timestamp then return a.timestamp < b.timestamp end
        return a.item_id < b.item_id
    end)

    return entries
end

local function pool_signature(entries)
    if not entries or #entries == 0 then
        return nil
    end

    local zone = current_zone()
    if not zone then return nil end

    local parts = {tostring(zone)}
    for _, entry in ipairs(entries) do
        parts[#parts + 1] = entry.drop_key
    end
    return table.concat(parts, '|')
end

local function find_pool_entry(slot, drop_key)
    for _, entry in ipairs(current_pool_entries()) do
        if tonumber(entry.slot) == tonumber(slot) and
           (not drop_key or entry.drop_key == drop_key) then
            return entry
        end
    end
    return nil
end

local function schedule_pool_check(delay)
    local due = now() + (delay or POOL_DEBOUNCE_SECONDS)
    if not pool_check_due or due > pool_check_due then
        pool_check_due = due
    end
end

local function handle_state(args)
    local signature = args[3]
    local name = args[4]
    local zone = tonumber(args[5])
    local mode = args[6]
    local valid = tonumber(args[7]) == 1
    local capacity = tonumber(args[8]) or 0
    local total = tonumber(args[9]) or 0

    if not cycle or cycle.signature ~= signature or not name or not zone then
        return
    end
    if tonumber(zone) ~= tonumber(cycle.zone) then
        return
    end
    if mode ~= 'auto' and mode ~= 'observe' and mode ~= 'off' then
        return
    end

    cycle.states[name:lower()] = {
        name = name,
        zone = zone,
        mode = mode,
        valid = valid,
        capacity = math.max(0, capacity),
        total = math.max(0, total),
        received_at = now(),
    }
end

local function send_local_state()
    if not cycle then return end

    local state = state_for_local()
    if not state.name or not state.zone then return end

    local fields = {
        'KUPONLOT',
        'STATE',
        cycle.signature,
        state.name,
        tostring(state.zone),
        state.mode,
        state.valid and '1' or '0',
        tostring(state.capacity or 0),
        tostring(state.total or 0),
    }

    local message = table.concat(fields, ' ')
    handle_state(tokenize(message))
    windower.send_ipc_message(message)
    cycle.last_state_sent_at = now()
end

local function activate_cycle(entries, signature, announce)
    local t = now()
    cycle = {
        signature = signature,
        zone = current_zone(),
        entries = entries,
        started_at = t,
        collect_deadline = t + STATE_COLLECTION_SECONDS,
        next_state_refresh_at = t + STATE_REFRESH_SECONDS,
        last_state_sent_at = nil,
        states = {},
        finalized = false,
        leader = nil,
        dry_run = false,
        candidate_states = nil,
        virtual = nil,
        capacity = nil,
    }

    send_local_state()

    if announce then
        windower.send_ipc_message(string.format(
            'KUPONLOT REQUEST %s %s',
            signature,
            tostring(cycle.zone)))
    end
end

local function start_cycle()
    pool_check_due = nil

    local entries = current_pool_entries()
    if #entries == 0 then
        return
    end

    local signature = pool_signature(entries)
    if not signature then
        return
    end

    if cycle and cycle.signature == signature and not cycle.finalized then
        send_local_state()
        return
    end

    activate_cycle(entries, signature, true)
    verbose(string.format(
        'Collecting local client state for %d %s drop%s.',
        #entries,
        KUPON_NAME,
        #entries == 1 and '' or 's'))
end

local function handle_request(args)
    local signature = args[3]
    local zone = tonumber(args[4])
    if not signature or not zone or tonumber(current_zone()) ~= zone then
        return
    end

    local entries = current_pool_entries()
    local current_signature = pool_signature(entries)
    if current_signature ~= signature then
        return
    end

    if not cycle or cycle.signature ~= signature then
        activate_cycle(entries, signature, false)
    else
        send_local_state()
    end
end

local function stable_hash(value)
    local hash = 5381
    value = tostring(value or '')
    for i = 1, #value do
        hash = (hash * 33 + value:byte(i)) % 2147483647
    end
    return hash
end

local function rank_candidates(candidate_states, virtual, capacity, seed, excluded)
    local ranked = {}

    for name_key, state in pairs(candidate_states or {}) do
        if state.valid and
           (capacity[name_key] or 0) > 0 and
           not (excluded and excluded[name_key]) then
            ranked[#ranked + 1] = {
                key = name_key,
                name = state.name,
                count = virtual[name_key] or 0,
                tie = stable_hash(seed .. '|' .. name_key),
            }
        end
    end

    table.sort(ranked, function(a, b)
        if a.count ~= b.count then
            return a.count < b.count
        end
        if a.tie ~= b.tie then
            return a.tie < b.tie
        end
        return a.key < b.key
    end)

    return ranked
end

local function choose_leader_and_candidates()
    local auto = {}
    local observe = {}

    for key, state in pairs(cycle.states) do
        if state.valid and state.mode == 'auto' and state.capacity > 0 then
            auto[key] = state
        elseif state.valid and state.mode == 'observe' and state.capacity > 0 then
            observe[key] = state
        end
    end

    local candidates
    local dry_run
    if next(auto) then
        candidates = auto
        dry_run = false
    elseif next(observe) then
        candidates = observe
        dry_run = true
    else
        return nil, nil, false
    end

    local keys = {}
    for key in pairs(candidates) do
        keys[#keys + 1] = key
    end
    table.sort(keys)

    return candidates[keys[1]].name, candidates, dry_run
end

local function emit_assignment(assignment, reason)
    local message = table.concat({
        'KUPONLOT',
        'ASSIGN',
        assignment.signature,
        assignment.drop_key,
        tostring(assignment.slot),
        assignment.winner,
        assignment.dry_run and '1' or '0',
        tostring(assignment.total_before or 0),
        reason or 'initial',
    }, ' ')

    windower.send_ipc_message(message)

    local me = player_name()
    if me and me:lower() == assignment.winner:lower() then
        handle_assignment(tokenize(message))
    elseif settings.Verbose then
        chat(string.format(
            '%s slot %d -> %s (%d owned).',
            KUPON_NAME,
            assignment.slot,
            assignment.winner,
            assignment.total_before),
            160)
    end
end

local function finalize_cycle()
    if not cycle or cycle.finalized then return end

    local entries = current_pool_entries()
    local signature = pool_signature(entries)
    if signature ~= cycle.signature then
        verbose('Treasure pool changed while collecting state; restarting allocation.')
        schedule_pool_check(0.05)
        cycle = nil
        return
    end

    cycle.finalized = true

    local leader, candidate_states, dry_run = choose_leader_and_candidates()
    cycle.leader = leader
    cycle.candidate_states = candidate_states
    cycle.dry_run = dry_run

    if not leader then
        chat('No eligible local clients can receive Kupon I-Seals; leaving them untouched.', 167)
        return
    end

    local me = player_name()
    if not me or me:lower() ~= leader:lower() then
        verbose('Coordinator for this pool: ' .. leader .. '.')
        return
    end

    local virtual = {}
    local capacity = {}
    for key, state in pairs(candidate_states) do
        virtual[key] = tonumber(state.total) or 0
        capacity[key] = tonumber(state.capacity) or 0
    end
    cycle.virtual = virtual
    cycle.capacity = capacity

    if dry_run then
        chat('Observe-only pool: computing assignments without lotting.')
    end

    for _, entry in ipairs(entries) do
        if not handled_drop_keys[entry.drop_key] then
            local seed = cycle.signature .. '|' .. entry.drop_key
            local ranked = rank_candidates(
                candidate_states,
                virtual,
                capacity,
                seed,
                nil)

            if #ranked == 0 then
                chat(string.format(
                    'No eligible client can receive %s in slot %d; leaving it untouched.',
                    KUPON_NAME,
                    entry.slot),
                    167)
            else
                local winner = ranked[1]
                local assignment = {
                    signature = cycle.signature,
                    drop_key = entry.drop_key,
                    slot = entry.slot,
                    winner = winner.name,
                    winner_key = winner.key,
                    total_before = winner.count,
                    dry_run = dry_run,
                    confirmed = dry_run,
                    deadline = dry_run and nil or (now() + ASSIGNMENT_TIMEOUT_SECONDS),
                    tried = {},
                }

                virtual[winner.key] = virtual[winner.key] + 1
                capacity[winner.key] = math.max(0, capacity[winner.key] - 1)
                handled_drop_keys[entry.drop_key] = true

                if not dry_run then
                    leader_assignments[entry.slot] = assignment
                end

                chat(string.format(
                    '%s%s slot %d -> %s (%d owned).',
                    dry_run and '[observe] ' or '',
                    KUPON_NAME,
                    entry.slot,
                    winner.name,
                    winner.count))
                emit_assignment(assignment, 'initial')
            end
        end
    end
end

local function reassign(assignment, reason)
    if not assignment or assignment.confirmed or assignment.dry_run then
        return
    end

    local entry = find_pool_entry(assignment.slot, assignment.drop_key)
    if not entry then
        leader_assignments[assignment.slot] = nil
        return
    end

    local active_cycle = cycle
    if not active_cycle or
       active_cycle.signature ~= assignment.signature or
       not active_cycle.candidate_states or
       not active_cycle.virtual or
       not active_cycle.capacity then
        chat(string.format(
            'Could not safely reassign %s slot %d after %s; leaving it untouched.',
            KUPON_NAME,
            assignment.slot,
            reason or 'failure'),
            167)
        leader_assignments[assignment.slot] = nil
        return
    end

    if assignment.winner_key and active_cycle.virtual[assignment.winner_key] then
        active_cycle.virtual[assignment.winner_key] =
            math.max(0, active_cycle.virtual[assignment.winner_key] - 1)
        active_cycle.capacity[assignment.winner_key] =
            (active_cycle.capacity[assignment.winner_key] or 0) + 1
        assignment.tried[assignment.winner_key] = true
    end

    local seed = assignment.signature .. '|' .. assignment.drop_key .. '|fallback'
    local ranked = rank_candidates(
        active_cycle.candidate_states,
        active_cycle.virtual,
        active_cycle.capacity,
        seed,
        assignment.tried)

    if #ranked == 0 then
        chat(string.format(
            'No fallback client available for %s slot %d after %s.',
            KUPON_NAME,
            assignment.slot,
            reason or 'failure'),
            167)
        leader_assignments[assignment.slot] = nil
        return
    end

    local winner = ranked[1]
    assignment.winner = winner.name
    assignment.winner_key = winner.key
    assignment.total_before = winner.count
    assignment.confirmed = false
    assignment.deadline = now() + ASSIGNMENT_TIMEOUT_SECONDS

    active_cycle.virtual[winner.key] = active_cycle.virtual[winner.key] + 1
    active_cycle.capacity[winner.key] =
        math.max(0, (active_cycle.capacity[winner.key] or 0) - 1)

    chat(string.format(
        'Reassigning %s slot %d -> %s after %s.',
        KUPON_NAME,
        assignment.slot,
        assignment.winner,
        reason or 'failure'),
        167)
    emit_assignment(assignment, 'fallback')
end

handle_assignment = function(args)
    local signature = args[3]
    local drop_key = args[4]
    local slot = tonumber(args[5])
    local winner = args[6]
    local dry_run = tonumber(args[7]) == 1
    local total_before = tonumber(args[8]) or 0

    local me = player_name()
    if not signature or not drop_key or not slot or not winner or not me then
        return
    end

    handled_drop_keys[drop_key] = true

    if winner:lower() ~= me:lower() then
        return
    end

    if local_pending_lots[drop_key] then
        return
    end

    local entry = find_pool_entry(slot, drop_key)
    if not entry then
        windower.send_ipc_message(string.format(
            'KUPONLOT FAIL %s %s %d %s stale',
            signature,
            drop_key,
            slot,
            me))
        return
    end

    if dry_run then
        chat(string.format(
            '[observe] Would lot %s in slot %d (%d owned before assignment).',
            KUPON_NAME,
            slot,
            total_before))
        return
    end

    if local_mode() ~= 'auto' then
        windower.send_ipc_message(string.format(
            'KUPONLOT FAIL %s %s %d %s not_auto',
            signature,
            drop_key,
            slot,
            me))
        return
    end

    if (inventory_capacity() or 0) <= 0 then
        windower.send_ipc_message(string.format(
            'KUPONLOT FAIL %s %s %d %s inventory_full',
            signature,
            drop_key,
            slot,
            me))
        return
    end

    local party = windower.ffxi.get_party() or {}
    local lots = party.p0 and party.p0.lots or {}
    local existing = lots and lots[slot] or nil

    if type(existing) == 'number' then
        windower.send_ipc_message(string.format(
            'KUPONLOT LOTOK %s %s %d %s',
            signature,
            drop_key,
            slot,
            me))
        return
    elseif existing ~= nil then
        windower.send_ipc_message(string.format(
            'KUPONLOT FAIL %s %s %d %s already_passed',
            signature,
            drop_key,
            slot,
            me))
        return
    end

    chat(string.format(
        'Lotting %s in slot %d (%d owned before assignment).',
        KUPON_NAME,
        slot,
        total_before))
    windower.ffxi.lot_item(slot)

    local t = now()
    local_pending_lots[drop_key] = {
        signature = signature,
        drop_key = drop_key,
        slot = slot,
        started_at = t,
        retry_at = t + LOT_RETRY_SECONDS,
        fail_at = t + LOT_FAIL_SECONDS,
        retried = false,
    }
end

local function handle_lotok(args)
    local signature = args[3]
    local drop_key = args[4]
    local slot = tonumber(args[5])
    local name = args[6]
    local assignment = slot and leader_assignments[slot] or nil

    if not assignment or
       assignment.signature ~= signature or
       assignment.drop_key ~= drop_key or
       not name then
        return
    end
    if assignment.winner:lower() ~= name:lower() then
        return
    end

    assignment.confirmed = true
    assignment.deadline = nil
    verbose(string.format(
        'Confirmed lot from %s for %s slot %d.',
        assignment.winner,
        KUPON_NAME,
        assignment.slot))
end

local function handle_fail(args)
    local signature = args[3]
    local drop_key = args[4]
    local slot = tonumber(args[5])
    local name = args[6]
    local reason = args[7] or 'client_failure'
    local assignment = slot and leader_assignments[slot] or nil

    if not assignment or
       assignment.signature ~= signature or
       assignment.drop_key ~= drop_key or
       not name then
        return
    end
    if assignment.winner:lower() ~= name:lower() then
        return
    end

    reassign(assignment, reason)
end

local function process_local_pending_lots(t)
    local party = windower.ffxi.get_party() or {}
    local lots = party.p0 and party.p0.lots or {}
    local me = player_name()

    for drop_key, pending in pairs(local_pending_lots) do
        local existing = lots and lots[pending.slot] or nil

        if type(existing) == 'number' then
            windower.send_ipc_message(string.format(
                'KUPONLOT LOTOK %s %s %d %s',
                pending.signature,
                pending.drop_key,
                pending.slot,
                me or 'unknown'))
            local_pending_lots[drop_key] = nil
        elseif existing ~= nil then
            windower.send_ipc_message(string.format(
                'KUPONLOT FAIL %s %s %d %s already_passed',
                pending.signature,
                pending.drop_key,
                pending.slot,
                me or 'unknown'))
            local_pending_lots[drop_key] = nil
        elseif not find_pool_entry(pending.slot, pending.drop_key) then
            local_pending_lots[drop_key] = nil
        elseif not pending.retried and t >= pending.retry_at then
            verbose(string.format(
                'Retrying lot for %s slot %d.',
                KUPON_NAME,
                pending.slot))
            windower.ffxi.lot_item(pending.slot)
            pending.retried = true
        elseif t >= pending.fail_at then
            windower.send_ipc_message(string.format(
                'KUPONLOT FAIL %s %s %d %s no_lot_ack',
                pending.signature,
                pending.drop_key,
                pending.slot,
                me or 'unknown'))
            local_pending_lots[drop_key] = nil
        end
    end
end

local function process_assignment_timeouts(t)
    for slot, assignment in pairs(leader_assignments) do
        if not assignment.confirmed and assignment.deadline and t >= assignment.deadline then
            reassign(assignment, 'timeout')
        end

        if not find_pool_entry(slot, assignment.drop_key) then
            leader_assignments[slot] = nil
        end
    end
end

local function reset_runtime()
    cycle = nil
    pool_check_due = nil
    leader_assignments = {}
    local_pending_lots = {}
    handled_drop_keys = {}
end

local function show_status()
    local capacity = inventory_capacity()

    chat(string.format(
        'Mode=%s, local total=%d, Inventory receive capacity=%s.',
        local_mode(),
        physical_total(),
        capacity ~= nil and tostring(capacity) or 'unavailable'))

    if cycle then
        local state_count = 0
        for _ in pairs(cycle.states) do
            state_count = state_count + 1
        end
        chat(string.format(
            'Pool cycle: %d Kupon drop%s, %d peer state%s, leader=%s, finalized=%s.',
            #cycle.entries,
            #cycle.entries == 1 and '' or 's',
            state_count,
            state_count == 1 and '' or 's',
            cycle.leader or '?',
            tostring(cycle.finalized)))
    else
        chat('No active Kupon I-Seal pool cycle.')
    end
end

local function show_totals()
    chat(string.format(
        'Local %s total: %d across tracked bags.',
        KUPON_NAME,
        physical_total()))
end

local function show_peers()
    if not cycle then
        chat('No active pool cycle / peer snapshot.')
        return
    end

    local keys = {}
    for key in pairs(cycle.states) do
        keys[#keys + 1] = key
    end
    table.sort(keys)

    if #keys == 0 then
        chat('No peer states collected yet.')
        return
    end

    for _, key in ipairs(keys) do
        local state = cycle.states[key]
        chat(string.format(
            '%s [%s%s,capacity=%d] %d %s',
            state.name,
            state.mode,
            state.valid and '' or ',invalid',
            state.capacity or 0,
            state.total or 0,
            KUPON_NAME))
    end
end

local function show_help()
    chat('//kuponlot status - show mode, local total/capacity, and current pool state.')
    chat('//kuponlot totals - show this character\'s Kupon I-Seal total.')
    chat('//kuponlot peers - show local-client totals collected for the current/most recent pool.')
    chat('//kuponlot on | off - enable or disable participation on this client.')
    chat('//kuponlot observe [on|off] - compute/log assignments but do not lot on this client.')
    chat('//kuponlot verbose [on|off] - toggle coordination diagnostics.')
    chat('Short alias: //klot')
end

windower.register_event('incoming chunk', function(id, data)
    if id == 0x0D2 then
        local ok, packet = pcall(packets.parse, 'incoming', data)
        if not ok or not packet then return end

        if tonumber(packet.Item) == KUPON_ITEM_ID then
            schedule_pool_check(POOL_DEBOUNCE_SECONDS)
        end
        return
    end

    if id == 0x0D3 then
        local ok, packet = pcall(packets.parse, 'incoming', data)
        if not ok or not packet then return end

        local slot = tonumber(packet.Index)
        if not slot then return end

        local assignment = leader_assignments[slot]
        local current_lotter = packet['Current Lotter Name']
        local current_lot = tonumber(packet['Current Lot'])
        local drop = tonumber(packet.Drop) or 0

        if assignment then
            if drop ~= 0 then
                leader_assignments[slot] = nil
            elseif current_lotter and
                   current_lotter ~= '' and
                   current_lotter:lower() == assignment.winner:lower() then
                if current_lot == 0xFFFF then
                    reassign(assignment, 'winner_passed')
                else
                    assignment.confirmed = true
                    assignment.deadline = nil
                    verbose(string.format(
                        'Server confirmed %s lotting %s slot %d.',
                        assignment.winner,
                        KUPON_NAME,
                        assignment.slot))
                end
            end
        end

        local me = player_name()
        if me and
           current_lotter and
           current_lotter ~= '' and
           current_lotter:lower() == me:lower() then
            for drop_key, pending in pairs(local_pending_lots) do
                if pending.slot == slot then
                    if current_lot == 0xFFFF then
                        windower.send_ipc_message(string.format(
                            'KUPONLOT FAIL %s %s %d %s winner_passed',
                            pending.signature,
                            pending.drop_key,
                            pending.slot,
                            me))
                    else
                        windower.send_ipc_message(string.format(
                            'KUPONLOT LOTOK %s %s %d %s',
                            pending.signature,
                            pending.drop_key,
                            pending.slot,
                            me))
                    end
                    local_pending_lots[drop_key] = nil
                end
            end
        end

        if drop ~= 0 then
            for drop_key, pending in pairs(local_pending_lots) do
                if pending.slot == slot then
                    local_pending_lots[drop_key] = nil
                end
            end
        end
    end
end)

windower.register_event('ipc message', function(message)
    local args = tokenize(message)
    if args[1] ~= 'KUPONLOT' then return end

    local kind = args[2]
    if kind == 'REQUEST' then
        handle_request(args)
    elseif kind == 'STATE' then
        handle_state(args)
    elseif kind == 'ASSIGN' then
        handle_assignment(args)
    elseif kind == 'LOTOK' then
        handle_lotok(args)
    elseif kind == 'FAIL' then
        handle_fail(args)
    end
end)

windower.register_event('prerender', function()
    local t = now()
    if t - last_tick < TICK_SECONDS then return end
    last_tick = t

    if pool_check_due and t >= pool_check_due then
        start_cycle()
    end

    if cycle and not cycle.finalized then
        if cycle.next_state_refresh_at and t >= cycle.next_state_refresh_at then
            send_local_state()
            cycle.next_state_refresh_at = t + STATE_REFRESH_SECONDS
        end

        if t >= cycle.collect_deadline then
            finalize_cycle()
        end
    end

    process_local_pending_lots(t)
    process_assignment_timeouts(t)
end)

windower.register_event('load', function()
    local info = windower.ffxi.get_info()
    if info and info.logged_in then
        schedule_pool_check(0.50)
    end
end)

windower.register_event('login', function()
    reset_runtime()
    schedule_pool_check(1.00)
end)

windower.register_event('zone change', function()
    reset_runtime()
    schedule_pool_check(1.25)
end)

windower.register_event('logout', function()
    reset_runtime()
end)

windower.register_event('addon command', function(command, argument)
    command = command and tostring(command):lower() or 'help'
    argument = argument and tostring(argument):lower() or nil

    if command == 'status' then
        show_status()
    elseif command == 'totals' then
        show_totals()
    elseif command == 'peers' then
        show_peers()
    elseif command == 'on' then
        settings.Enabled = true
        config.save(settings)
        chat('Participation enabled.')
        if cycle and not cycle.finalized then send_local_state() end
    elseif command == 'off' then
        settings.Enabled = false
        config.save(settings)
        chat('Participation disabled; this client will not be assigned Kupons.')
        if cycle and not cycle.finalized then send_local_state() end
    elseif command == 'observe' then
        local requested = bool_arg(argument)
        if requested == nil then
            requested = not settings.Observe
        end
        settings.Observe = requested
        settings.Enabled = true
        config.save(settings)
        chat('Observe mode ' ..
            (settings.Observe and
                'enabled (no automatic lots).' or
                'disabled (automatic lots allowed).'))
        if cycle and not cycle.finalized then send_local_state() end
    elseif command == 'verbose' then
        local requested = bool_arg(argument)
        if requested == nil then
            requested = not settings.Verbose
        end
        settings.Verbose = requested
        config.save(settings)
        chat('Verbose diagnostics ' ..
            (settings.Verbose and 'enabled.' or 'disabled.'))
    else
        show_help()
    end
end)
