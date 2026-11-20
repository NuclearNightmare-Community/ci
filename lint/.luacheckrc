-- Shared luacheck settings for every mod repo; ci/check.ps1 runs luacheck --config lint/.luacheckrc <files>.
-- check.ps1 lists the files itself and skips the folders below for both linters; exclude_files repeats them for
-- running luacheck by hand from a mod repo's root. Every global rule exclusion carries a one-line reason.
std = "lua54"

-- Folders that hold no Lua of the mod's own: build output, other worktrees, the Unreal and native projects, the
-- UE4SS source checkout, and the ci and Nucleus checkouts the workflow places beside the mod.
exclude_files = { "build/**", ".worktrees/**", "unreal/**", "native/**", "ue4ss-src/**", "ci/**", "nucleus/**" }

ignore = {
    "631", -- line too long: the repos keep long lines on purpose (one statement, one line, wide editors).
    "212", -- unused argument: callbacks and hooks must take the parameters their caller passes.
    "42",  -- shadowing a local or argument (421, 423): deliberate in nested helpers; reviewed, not linted.
    "43",  -- shadowing an upvalue (431-433): same.
    "411", -- redefining a local in the same scope: a style choice, never a behaviour change.
    "542", -- empty if branch: used to document a case that deliberately does nothing.
    "581", -- 'not (x <= y)' style hint: NaN-safe comparisons are written that way on purpose.
}

-- UE4SS's Lua API: globals the runtime provides to every mod.
read_globals = {
    "RegisterHook", "UnregisterHook", "RegisterLoadMapPostHook", "RegisterInitGameStatePostHook", "RegisterKeyBind",
    "NotifyOnNewObject", "StaticFindObject", "StaticConstructObject", "FindAllOf", "FindFirstOf", "LoadAsset",
    "FName", "FText", "ExecuteInGameThread", "ExecuteWithDelay", "ExecuteInGameThreadWithDelay",
    "ExecuteInGameThreadAfterFrames", "CancelDelayedAction", "LoopAsync", "LoopInGameThreadWithDelay",
    "IterateGameDirectories", "print",
    -- A mod sets ModRef.OnUnload and similar fields.
    ModRef = { other_fields = true, read_only = false },
}

-- Tests (unit tests and in-game test mods): they stub the UE4SS globals above and define their own, and keep
-- values and names that mirror the code under test.
files["**/test/**"] = {
    allow_defined = true,
    ignore = {
        "121", "122", -- setting a UE4SS global or its field: the stubs.
        "111", "112", "113", "131", -- non-standard globals: fakes for natives and other mods' globals.
        "211", "213", "231", "241", "311", "331", -- unused locals and values: harmless in code that never ships.
    },
}
