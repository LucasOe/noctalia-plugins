local LOCAL_REVISION_COMMAND = --
    "nixos-version --revision 2>/dev/null | cut -c 1-7 || echo 'N/A'"
local REMOTE_REVISION_COMMAND = --
    "git ls-remote https://github.com/NixOS/nixpkgs.git nixos-unstable 2>/dev/null | cut -c 1-7 || echo 'N/A'"

local firstRun = true
local hide = barWidget.getConfig("hide")

local function log(obj)
    noctalia.log(noctalia.json.encode(obj))
end

local function render(localRevision: string, remoteRevision: string)
    if not localRevision or not remoteRevision then return end

    barWidget.setTooltip(`Local: {localRevision}\nRemote: {remoteRevision}`)

    if localRevision == remoteRevision then
        barWidget.setGlyph("check")
        barWidget.setGlyphColor("tertiary")
        barWidget.setText(localRevision)
        barWidget.setColor("tertiary")

        if not hide then barWidget.setVisible(true) end
    else
        barWidget.setGlyph("alert-circle")
        barWidget.setGlyphColor("error")
        barWidget.setText(`{localRevision} → {remoteRevision}`)
        barWidget.setColor("error")

        barWidget.setVisible(true)
    end
end

function update()
    noctalia.setUpdateInterval(60000 * 5) -- update every 5m

    if firstRun then
        firstRun = false
        barWidget.setVisible(false)
    end

    local localRevision
    local remoteRevision

    noctalia.runAsync(LOCAL_REVISION_COMMAND, function(result)
        if result.exitCode ~= 0 then return end
        localRevision = result.stdout
        render(localRevision, remoteRevision)
    end, 10000) -- 10s timeout

    noctalia.runAsync(REMOTE_REVISION_COMMAND, function(result)
        if result.exitCode ~= 0 then return end
        remoteRevision = result.stdout
        render(localRevision, remoteRevision)
    end, 10000) -- 10s timeout
end
