-- Type returned by `pass-cli vault list --output=json`
type Vault = { name: string, vault_id: string, share_id: string }
type Vaults = { [number]: Vault }

-- Type returned by `pass-cli item list <vault_name> --output=json`
type Item = { id: string, share_id: string, vault_id: string, state: string, title: string, item_type: string }
type Items = { [number]: Item }

-- Caches to avoid repeated CLI calls while the launcher session is active
local cachedVaults: Vaults = {}
local cachedItems: { [string]: Items } = {}

function onQuery(text: string)
    local args: { string } = splitByWhitespace(text)
    local hasTrailingSpace: boolean = text:match("%s$") ~= nil

    -- Reset cache when query is empty
    if text == "" then
        cachedVaults = {}
        cachedItems = {}
    end

    -- If only zero/one argument, show vault list
    if #args <= 1 then
        local vaultName = args[1] or ""
        launcher.setResults(text, { { id = "loading", title = "Loading Vaults…", glyph = "loader" } })

        getVaultsAsync(function(vaults)
            launcher.setResults(
                text,
                mapFilter(vaults, function(vault)
                    local score = launcher.fuzzyScore(vaultName, vault.name)
                    if score == nil then return nil end

                    return {
                        id = noctalia.json.encode({ type = "vault", id = vault.name }),
                        title = vault.name,
                        glyph = "folder",
                        score = score,
                    }
                end)
            )
        end)
    end

    -- If a second argument exists, or the user typed a space after the vault name,
    -- show items for the selected vault
    if #args >= 2 or (#args == 1 and hasTrailingSpace) then
        local vaultName = args[1]
        local itemName = table.concat(args, " ", 2) or ""
        launcher.setResults(text, { { id = "loading", title = "Loading Items…", glyph = "loader" } })

        getItemsAsync(vaultName, function(items)
            -- Exclude Trashed items before scoring
            items = filter(items, function(item)
                return item.state == "Active"
            end)

            launcher.setResults(
                text,
                mapFilter(items, function(item)
                    local score = launcher.fuzzyScore(itemName, item.title)
                    if score == nil then return nil end

                    return {
                        id = noctalia.json.encode({ type = "item", id = item.id }),
                        title = item.title,
                        -- subtitle = item.item_type,
                        glyph = glpyhTable(item.item_type),
                        score = score,
                    }
                end)
            )
        end)
    end
end

function onActivate(_id: string)
    local id: { type: string, id: string } = noctalia.json.decode(_id)

    if id.type == "vault" then
        -- TODO: replace IPC call with plugin API once available
        noctalia.runAsync(`noctalia msg panel-toggle launcher "/pass {id.id} "`)
        return
    end

    if id.type == "item" then
        local item = searchCachedItems(id.id)

        if item == nil then
            noctalia.notifyError("Proton Pass", "Item not found")
            return
        end

        getPasswordAsync(item, function(password)
            noctalia.copyToClipboard(password, "text/plain")
            noctalia.notify(`{item.title}`, `Copied password to clipboard`)

            -- Try to fetch TOTP and notify
            getItemTotpAsync(item, function(totp)
                noctalia.notify(`{item.title} TOTP`, totp)
            end)
        end)
    end
end

function glpyhTable(item_type: string)
    local lookupTable: { [string]: string } = {
        alias = "at",
        credit_card = "credit-card",
        custom = "note",
        identity = "user-circle",
        login = "lock",
        ssh_key = "key",
        wifi = "router",
    }

    return lookupTable[item_type] or "question-mark"
end

-- Async helpers ---------------------------------------------------------------

function getVaultsAsync(callback)
    if #cachedVaults ~= 0 then
        callback(cachedVaults)
        return
    end

    noctalia.runAsync(`pass-cli vault list --output=json`, function(result)
        if result.exitCode ~= 0 then
            noctalia.log("proton-pass: failed to list vaults")
            return
        end

        local decoded = noctalia.json.decode(result.stdout)
        local vaults: Vaults = decoded["vaults"] or {}
        cachedVaults = vaults
        callback(vaults)
    end)
end

function getItemsAsync(vaultName: string, callback)
    if cachedItems[vaultName] ~= nil then
        callback(cachedItems[vaultName])
        return
    end

    noctalia.runAsync(`pass-cli item list {vaultName} --output=json`, function(result)
        if result.exitCode ~= 0 then
            noctalia.log(`proton-pass: failed to list items in vault: {vaultName}`)
            return
        end

        local decoded = noctalia.json.decode(result.stdout)
        local items: Items = decoded["items"] or {}
        cachedItems[vaultName] = items
        callback(items)
    end)
end

function getPasswordAsync(item: Item, callback)
    noctalia.runAsync(`pass-cli item view "pass://{item.share_id}/{item.id}/password" --output=json`, function(result)
        if result.exitCode ~= 0 then
            noctalia.log(`proton-pass: no password found for item: {item.title}`)
            return
        end

        local password: string = result.stdout
        callback(password)
    end)
end

function getItemTotpAsync(item: Item, callback)
    noctalia.runAsync(`pass-cli item totp "pass://{item.share_id}/{item.id}" --output=json`, function(result)
        if result.exitCode ~= 0 then
            -- It's not an error if a TOTP is absent; just log for debugging
            noctalia.log(`proton-pass: no TOTP code for item: {item.title}`)
            return
        end

        local decoded = noctalia.json.decode(result.stdout)
        local totp: string = decoded["totp"]
        callback(totp)
    end)
end

-- Utility functions -----------------------------------------------------------

function splitByWhitespace(str: string): { string }
    local words = {}
    for word in str:gmatch("%S+") do
        table.insert(words, word)
    end
    return words
end

-- Search cached items by item id across all cached vaults
function searchCachedItems(item_id: string): Item?
    for _, vault in pairs(cachedItems) do
        for _, item in ipairs(vault) do
            if item.id == item_id then return item end
        end
    end
    return nil
end

-- Filter a sequence keeping only elements where predicate(v) is truthy
function filter(sequence, predicate)
    local newlist = {}
    for _, v in ipairs(sequence) do
        if predicate(v) then table.insert(newlist, v) end
    end
    return newlist
end

-- Map a sequence to a new sequence (keeps order, produces a dense array)
function map(sequence, transformation)
    local mapped = {}
    for _, v in ipairs(sequence) do
        table.insert(mapped, transformation(v))
    end
    return mapped
end

-- Map + filter: transform each element, include only non-nil results
function mapFilter(sequence, fn)
    local out = {}
    for _, v in ipairs(sequence) do
        local res = fn(v)
        if res ~= nil then table.insert(out, res) end
    end
    return out
end

function log(obj)
    noctalia.log(noctalia.json.encode(obj))
end
