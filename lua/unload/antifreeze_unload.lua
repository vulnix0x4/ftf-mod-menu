--!nocheck
-- Flee the Facility - anti-freeze teardown
-- Stops the rescue loop and puts every pod we opened back the way it was.

if _G.__ftfAntiFreezeStop then
    _G.__ftfAntiFreezeStop()
else
    _G.__ftfAntiFreeze = nil
    _G.__ftfAntiFreezeInstance = nil
    print("[FTF-ANTIFREEZE] nothing running")
end
