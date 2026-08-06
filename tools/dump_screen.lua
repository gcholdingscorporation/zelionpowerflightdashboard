-- Dumps what the widget actually builds, as a flat list a renderer can draw.
--
-- Dumps what the code built, not what a design says it should have. That gap
-- is where the bugs lived: the mock-up's "small" was a 9pt font while EdgeTX's
-- SMLSIZE is 23px on a TX16S, which is how every panel ended up with its
-- header inside its own value.
--
--   lua tools/dump_screen.lua <width> <height> [dash|empty|safe] > screen.txt

package.path = "./tools/?.lua;" .. package.path

local Mock   = dofile("tools/mock_edgetx.lua")
local Loader = dofile("tools/loader.lua")

local w    = tonumber(arg[1]) or 800
local h    = tonumber(arg[2]) or 480
local kind = arg[3] or "dash"

Mock.reset()
Mock.removeRf2()
Mock.state.lcdW, Mock.state.lcdH = w, h
Mock.state.modelName = "GOBLIN 700"

if kind ~= "empty" then
  for _, s in ipairs({
    {"Hspd", 18, 1850}, {"Vcel", 1, 3.94}, {"Vbat", 1, 47.3},
    {"Bat%", 13, 68},   {"Curr", 2, 42},   {"Tesc", 11, 71},
    {"Vbec", 1, 8.1},   {"Gov", nil, 4},   {"Capa", 14, 1240},
    {"RQly", 12, 92},   {"Tx", 1, 7.9},    {"Cels", nil, 12},
  }) do
    Mock.addSensor(s[1], s[2], s[3])
  end
end

Mock.install()
Mock.installLvgl()
Mock.installLogos()

local ZD = Loader.load()
ZD.State.reloadModel()
Mock.advanceSeconds(0.2)
ZD.State.service(Mock.state.time)
-- Session extremes, so the min/max footnotes carry something to look at.
ZD.State.setExtremesForPreview = nil
Mock.setSensor("Hspd", 2150); Mock.setSensor("Vcel", 4.05)
Mock.setSensor("Vbat", 49.2); Mock.setSensor("Curr", 96)
Mock.advanceSeconds(0.2); ZD.State.service(Mock.state.time)
Mock.setSensor("Hspd", 1850); Mock.setSensor("Vcel", 3.94)
Mock.setSensor("Vbat", 47.3); Mock.setSensor("Curr", 42)
Mock.advanceSeconds(0.2); ZD.State.service(Mock.state.time)

if kind == "safe" then
  ZD.Dashboard.buildMinimal(w, h)
else
  ZD.Dashboard.build(w, h)
end
ZD.Dashboard.update()

local function esc(s)
  return (tostring(s):gsub("\\", "\\\\"):gsub("\t", " "):gsub("\n", " "))
end

print(string.format("SCREEN\t%d\t%d\t%s\t%s", w, h, kind, ZD.Theme.metrics))
for _, o in ipairs(Mock.lv.objects) do
  local p = o.props
  print(table.concat({
    o.kind,
    tostring(p.x or 0), tostring(p.y or 0),
    tostring(p.w or 0), tostring(p.h or 0),
    tostring(p.color or 0),
    tostring(p.font or 0),
    tostring(p.align or 0),
    tostring(p.rounded or 0),
    tostring(p.filled or 0),
    esc(p.text or p.file or ""),
  }, "\t"))
end
