-- type returned by `pass-cli vault list --output=json`
type Vault = { name: string, vault_id: string, share_id: string }
type Vaults = { [number]: Vault }

-- type returned by `pass-cli item list <vault_name> --output=json`
type Item = { id: string, share_id: string, vault_id: string, state: string, title: string, item_type: string }
type Items = { [number]: Item }

local cachedVaults: Vaults = {}
local cachedItems: { [string]: Items } = {}

function onQuery(text: string)
    local args: { string } = splitByWhitespace(text)
    local hasTrailingSpace: boolean = text:match("%s$") ~= nil

    -- reset cache
    if text == "" then
        cachedVaults = {}
        cachedItems = {}
    end

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

    -- If the user provided a second argument OR typed a space after the vault name
    -- (i.e. an empty second argument), show items for the selected vault.
    if #args >= 2 or (#args == 1 and hasTrailingSpace) then
        local vaultName = args[1]
        local itemName = table.concat(args, " ", 2) or ""
        launcher.setResults(text, { { id = "loading", title = "Loading Items…", glyph = "loader" } })

        getItemsAsync(vaultName, function(items)
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
                        subtitle = item.item_type,
                        glyph = "lock",
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
    end

    if id.type == "item" then
        local item = searchCachedItems(id.id)

        getPasswordAsync(item, function(password)
            noctalia.copyToClipboard(password, "text/plain")
            noctalia.notify("Proton Pass", `Copied {item.title} password clipboard`)

            getItemTotpAsync(item, function(totp)
                noctalia.notify(`{item.title} TOTP`, totp)
            end)
        end)
    end
end

function getVaultsAsync(callback)
    if #cachedVaults ~= 0 then return callback(cachedVaults) end

    noctalia.runAsync(`pass-cli vault list --output=json`, function(result)
        if result.exitCode ~= 0 then return end
        local vaults: Vaults = noctalia.json.decode(result.stdout)["vaults"]
        cachedVaults = vaults
        return callback(vaults)
    end)

    return
end

function getItemsAsync(vaultName, callback)
    if cachedItems[vaultName] ~= nil then return callback(cachedItems[vaultName]) end

    noctalia.runAsync(`pass-cli item list {vaultName} --output=json`, function(result)
        if result.exitCode ~= 0 then return end
        local items: Items = noctalia.json.decode(result.stdout)["items"]
        cachedItems[vaultName] = items
        return callback(items)
    end)

    return
end

function getPasswordAsync(item, callback)
    noctalia.runAsync(`pass-cli item view "pass://{item.share_id}/{item.id}/password" --output=json`, function(result)
        if result.exitCode ~= 0 then return end
        local password: string = result.stdout
        return callback(password)
    end)

    return
end

function getItemTotpAsync(item, callback)
    noctalia.runAsync(`pass-cli item totp "pass://{item.share_id}/{item.id}" --output=json`, function(result)
        if result.exitCode ~= 0 then return end

        local totp: string = noctalia.json.decode(result.stdout)["totp"]

        return callback(totp)
    end)

    return
end

function splitByWhitespace(str: string): { string }
    local words = {}
    for word in str:gmatch("%S+") do
        table.insert(words, word)
    end
    return words
end

function searchCachedItems(item_id: string): Item?
    for _, vault in pairs(cachedItems) do
        for _, item in ipairs(vault) do
            if item.id == item_id then return item end
        end
    end
    return nil
end

function filter(sequence, predicate)
    local newlist = {}
    for _, v in ipairs(sequence) do
        if predicate(v) then table.insert(newlist, v) end
    end
    return newlist
end

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
