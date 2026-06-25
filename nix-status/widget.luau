local firstRun = true

local function isShortHash(text)
    return #text == 7 and text:match("^[0-9a-fA-F]+$") ~= nil
end

local function render(localRevision: string, remoteRevision: string)
    if not localRevision or not remoteRevision then return end

    barWidget.setTooltip({
        { key = "Local", value = localRevision },
        { key = "Remote", value = remoteRevision },
    })

    if localRevision == remoteRevision then
        barWidget.setGlyph("check")
        barWidget.setGlyphColor("tertiary")
        barWidget.setText(localRevision)
        barWidget.setColor("tertiary")

        -- if barWidget.getConfig("hide") then barWidget.setVisible(false) end
    else
        barWidget.setGlyph("alert-circle")
        barWidget.setGlyphColor("error")
        barWidget.setText(`{localRevision} → {remoteRevision}`)
        barWidget.setColor("error")
    end
end

function update()
    noctalia.setUpdateInterval(1000 * barWidget.getConfig("updateInterval"))

    if firstRun then
        firstRun = false
        barWidget.setGlyph("loader")
        barWidget.setText("-------")
    end

    local localRevision
    local remoteRevision

    noctalia.runAsync(barWidget.getConfig("localRevisionCommand"), function(result)
        if result.exitCode ~= 0 or not isShortHash(result.stdout) then
            noctalia.log("nix-status: Failed to fetch local revision")
            noctalia.log(`nix-status: {noctalia.json.encode(result)}`)

            barWidget.setGlyph("alert-circle")
            barWidget.setGlyphColor("error")
            barWidget.setText("Failed to fetch local revision")
            barWidget.setColor("error")
            return
        end
        localRevision = result.stdout
        render(localRevision, remoteRevision)
    end, 30000) -- 30s timeout

    noctalia.runAsync(barWidget.getConfig("remoteRevisionCommand"), function(result)
        if result.exitCode ~= 0 or not isShortHash(result.stdout) then
            noctalia.log("nix-status: Failed to fetch remote revision:")
            noctalia.log(`nix-status: {noctalia.json.encode(result)}`)

            barWidget.setGlyph("alert-circle")
            barWidget.setGlyphColor("error")
            barWidget.setText("Failed to fetch remote revision")
            barWidget.setColor("error")
            return
        end
        remoteRevision = result.stdout
        render(localRevision, remoteRevision)
    end, 30000) -- 30s timeout
end
