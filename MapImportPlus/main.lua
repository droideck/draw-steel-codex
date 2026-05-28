-- MapImportPlus mod entry point.
--
-- This file is intentionally empty: DMHub auto-loads every .lua file in a
-- mod folder when the mod loads, so we don't need to require sibling files
-- from here. All the import logic lives in MapImportPlus.lua.
--
-- Keep this file as the "main.lua" DMHub expects per-mod, but treat it as
-- a stub. If DMHub-side bootstrap is ever needed, put it here above the
-- separator below.

local mod = dmhub.GetModLoading()
