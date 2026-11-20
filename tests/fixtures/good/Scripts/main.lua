-- A clean mod script: UE4SS globals only, no lint findings.
local M = {}

function M.start()
    RegisterHook("/Script/Engine.PlayerController:ClientRestart", function(ctx)
        print("[Fixture] restart " .. tostring(ctx))
    end)
end

ModRef.OnUnload = function() end

return M
