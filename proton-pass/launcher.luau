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
        local vaultName: string? = args[1]
        launcher.setResults(text, { { id = "loading", title = "Loading Vaults…", glyph = "loader" } })

        getVaultsAsync(function(vaults)
            vaults = fuzzyFilter(vaults, vaultName, function(it)
                return it.name
            end)

            launcher.setResults(
                text,
                map(vaults, function(vault)
                    return {
                        id = noctalia.json.encode({ type = "vault", id = vault.name }),
                        title = vault.name,
                        glyph = "folder",
                    }
                end)
            )
        end)
    end

    -- If the user provided a second argument OR typed a space after the vault name
    -- (i.e. an empty second argument), show items for the selected vault.
    if #args >= 2 or (#args == 1 and hasTrailingSpace) then
        local vaultName: string = args[1]
        local itemName: string? = table.concat(args, " ", 2)
        launcher.setResults(text, { { id = "loading", title = "Loading Items…", glyph = "loader" } })

        getItemsAsync(vaultName, function(items)
            items = filter(items, function(item)
                return item.state == "Active"
            end)

            items = fuzzyFilter(items, itemName, function(it)
                return it.title
            end)

            launcher.setResults(
                text,
                map(items, function(item)
                    return {
                        id = noctalia.json.encode({ type = "item", id = item.id }),
                        title = item.title,
                        subtitle = item.item_type,
                        glyph = "lock",
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
    if #cachedVaults ~= 0 then
        return callback(cachedVaults)
    end

    noctalia.runAsync(`pass-cli vault list --output=json`, function(result)
        if result.exitCode ~= 0 then
            return
        end

        local vaults: Vaults = noctalia.json.decode(result.stdout)["vaults"]
        cachedVaults = vaults

        return callback(vaults)
    end)

    return
end

function getItemsAsync(vaultName, callback)
    if cachedItems[vaultName] ~= nil then
        return callback(cachedItems[vaultName])
    end

    noctalia.runAsync(`pass-cli item list {vaultName} --output=json`, function(result)
        if result.exitCode ~= 0 then
            return
        end

        local items: Items = noctalia.json.decode(result.stdout)["items"]
        cachedItems[vaultName] = items

        return callback(items)
    end)

    return
end

function getPasswordAsync(item, callback)
    noctalia.runAsync(`pass-cli item view "pass://{item.share_id}/{item.id}/password" --output=json`, function(result)
        if result.exitCode ~= 0 then
            return
        end

        local password: string = result.stdout

        return callback(password)
    end)

    return
end

function getItemTotpAsync(item, callback)
    noctalia.runAsync(`pass-cli item totp "pass://{item.share_id}/{item.id}" --output=json`, function(result)
        if result.exitCode ~= 0 then
            return
        end

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
            if item.id == item_id then
                return item
            end
        end
    end
    return nil
end

function fuzzyScore(pattern, text)
    if pattern == nil or pattern == "" or text == nil then
        return nil
    end

    local p = string.lower(pattern)
    local t = string.lower(text)
    local pLen = #p
    local tLen = #t
    local pIdx = 1
    local tIdx = 1
    local score = 0
    local consecutive = 0
    local firstPos = nil

    while pIdx <= pLen and tIdx <= tLen do
        if string.sub(p, pIdx, pIdx) == string.sub(t, tIdx, tIdx) then
            if firstPos == nil then
                firstPos = tIdx
            end
            score = score + 10 + consecutive * 5
            consecutive = consecutive + 1
            pIdx = pIdx + 1
        else
            consecutive = 0
            score = score - 1
        end
        tIdx = tIdx + 1
    end

    if pIdx <= pLen then
        return nil
    end

    score = score + math.max(0, 10 - (firstPos or 0))
    return score
end

function fuzzyFilter(list, pattern, extractor)
    if pattern == nil or pattern == "" then
        return list
    end

    local scored = {}
    for _, v in ipairs(list) do
        local text = extractor(v) or ""
        local s = fuzzyScore(pattern, text)
        if s ~= nil then
            table.insert(scored, { item = v, score = s })
        end
    end

    table.sort(scored, function(a, b)
        return a.score > b.score
    end)

    local out = {}
    for _, entry in ipairs(scored) do
        table.insert(out, entry.item)
    end
    return out
end

function filter(sequence, predicate)
    local newlist = {}
    for _, v in ipairs(sequence) do
        if predicate(v) then
            table.insert(newlist, v)
        end
    end
    return newlist
end

function map(sequence, transformation)
    local mapped = {}
    for i, v in pairs(sequence) do
        mapped[i] = transformation(v)
    end
    return mapped
end

function log(obj)
    noctalia.log(noctalia.json.encode(obj))
end
