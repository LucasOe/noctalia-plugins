local cachedVaults = nil
local cachedItems = {}

function onQuery(text)
    local args = splitByWhitespace(text)
    local hasTrailingSpace = text:match("%s$") ~= nil

    -- reset cache
    if text == "" then
        cachedVaults = nil
        cachedItems = {}
    end

    if #args <= 1 then
        local vaultName = args[1] -- can be nil
        launcher.setResults(text, { { id = "loading", title = "Loading Vaults…", glyph = "loader" } })

        getVaultsAsync(function(vaults)
            vaults = fuzzyFilter(vaults, vaultName, function(it)
                return it.name
            end) -- fuzzy filter

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
        local vaultName = args[1]
        local itemName = table.concat(args, " ", 2)
        launcher.setResults(text, { { id = "loading", title = "Loading Items…", glyph = "loader" } })

        getItemsAsync(vaultName, function(items)
            items = filter(items, function(item)
                return item.state == "Active"
            end) -- filter out Trashed items
            items = fuzzyFilter(items, itemName, function(it)
                return it.title
            end) -- fuzzy filter

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

function onActivate(id)
    id = noctalia.json.decode(id)

    if id.type == "vault" then
        -- TODO: replace IPC call with plugin API once available
        noctalia.runAsync(string.format('noctalia msg panel-toggle launcher "/pass %s "', id.id))
    end

    if id.type == "item" then
        local item = searchCachedItems(cachedItems, id.id)
        if item == nil then
            return
        end

        getPasswordAsync(item, function(password)
            noctalia.copyToClipboard(password, "text/plain")
            noctalia.notify("Proton Pass", string.format("Copied to %s clipboard", item.title))

            getItemTotpAsync(item, function(totp)
                noctalia.notify(string.format("%s TOTP", item.title), totp)
            end)
        end)
    end
end

function getVaultsAsync(callback)
    if cachedVaults ~= nil then
        return callback(cachedVaults)
    end

    local cmd = "pass-cli vault list --output=json"
    noctalia.runAsync(cmd, function(result)
        if result.exitCode ~= 0 then
            return
        end

        local vaults = noctalia.json.decode(result.stdout)["vaults"]
        cachedVaults = vaults

        return callback(vaults)
    end)

    return
end

function getItemsAsync(vaultName, callback)
    if cachedItems[vaultName] ~= nil then
        return callback(cachedItems[vaultName])
    end

    local cmd = string.format("pass-cli item list %s --output=json", vaultName)
    noctalia.runAsync(cmd, function(result)
        if result.exitCode ~= 0 then
            return
        end

        local items = noctalia.json.decode(result.stdout)["items"]
        cachedItems[vaultName] = items

        return callback(items)
    end)

    return
end

function getPasswordAsync(item, callback)
    local cmd = string.format('pass-cli item view "pass://%s/%s/password" --output=json', item.share_id, item.id)
    noctalia.runAsync(cmd, function(result)
        if result.exitCode ~= 0 then
            return
        end

        return callback(result.stdout)
    end)

    return
end

function getItemTotpAsync(item, callback)
    local cmd = string.format('pass-cli item totp "pass://%s/%s" --output=json', item.share_id, item.id)
    noctalia.runAsync(cmd, function(result)
        if result.exitCode ~= 0 then
            return
        end

        local totp = noctalia.json.decode(result.stdout)["totp"]

        return callback(totp)
    end)

    return
end

function splitByWhitespace(str)
    local words = {}
    for word in str:gmatch("%S+") do
        table.insert(words, word)
    end
    return words
end

function searchCachedItems(items, itemId)
    for _, itemList in pairs(items) do
        if type(itemList) == "table" then
            for _, item in ipairs(itemList) do
                if item.id == itemId then
                    return item
                end
            end
        end
    end

    return nil
end

-- Fuzzy matching helpers
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
