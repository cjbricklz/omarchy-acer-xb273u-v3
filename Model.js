// Pure helpers for the Acer panel: VCP table, parsing, and the coalescing
// write queue's bookkeeping. Kept free of QML so it can be tested with node.

var VCP = {
  brightness: 0x10,
  contrast: 0x12,
  preset: 0x14,     // select color preset, standard MCCS values
  gainR: 0x16,
  gainG: 0x18,
  gainB: 0x1a
}

// MCCS "select color preset" values the XB273U V3 reports (0x06 = 7500 K was
// read from the monitor; the others are the standard MCCS codes).
var PRESETS = [
  { value: 0x01, label: "sRGB" },
  { value: 0x04, label: "5000 K" },
  { value: 0x05, label: "6500 K" },
  { value: 0x06, label: "7500 K" },
  { value: 0x08, label: "9300 K" },
  { value: 0x0b, label: "User" }
]

function clamp(v, lo, hi) {
  var n = Math.round(Number(v))
  if (!isFinite(n)) n = lo
  return Math.max(lo, Math.min(hi, n))
}

// Parses `ddcutil --brief getvcp 10 12 14 16 18 1a` into {code: current}.
//   VCP 10 C 25 100   continuous: current max
//   VCP 14 SNC x06    simple non-continuous
//   VCP xx CNC x00 x02 x00 x02  complex: mh ml sh sl (current = sh*256+sl)
function parseBrief(text) {
  var out = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var f = lines[i].trim().split(/\s+/)
    if (f[0] !== "VCP" || f.length < 4) continue
    var code = parseInt(f[1], 16)
    var v = NaN
    if (f[2] === "C") v = parseInt(f[3], 10)
    else if (f[2] === "SNC") v = parseInt(f[3].replace(/^x/, ""), 16)
    else if (f[2] === "CNC" && f.length >= 7)
      v = parseInt(f[5].replace(/^x/, ""), 16) * 256 + parseInt(f[6].replace(/^x/, ""), 16)
    if (isFinite(code) && isFinite(v)) out[code] = v
  }
  return out
}

// Coalescing queue: one pending value per code. Setting a code again replaces
// its value, so only the newest value is ever sent. Returns a new object.
function enqueue(pending, code, value) {
  var next = {}
  for (var k in pending) next[k] = pending[k]
  next[code] = value
  return next
}

// Takes the next write out of the queue: {code, value, rest} or null.
function takeNext(pending) {
  for (var k in pending) {
    var rest = {}
    for (var j in pending) if (j !== k) rest[j] = pending[j]
    return { code: Number(k), value: pending[k], rest: rest }
  }
  return null
}

// Parses `ddcutil detect --brief` into [{bus, mfg, model}], one per display
// with an I2C bus. Blocks look like:
//   Display 1
//      I2C bus:  /dev/i2c-9
//      DRM connector:  card1-DP-3
//      Monitor:  ACR:XB273U V3:<serial>
function parseDetect(text) {
  var out = []
  var blocks = String(text || "").split(/\n(?=\S)/)
  for (var i = 0; i < blocks.length; i++) {
    var bus = /I2C bus:\s*\/dev\/i2c-(\d+)/.exec(blocks[i])
    if (!bus) continue
    var mon = /Monitor:\s*([^:\n]*):([^:\n]*)/.exec(blocks[i])
    // "card1-DP-3" -> Hyprland's output name "DP-3"
    var conn = /DRM[ _]connector:\s*card\d+-(\S+)/i.exec(blocks[i])
    out.push({ bus: bus[1], mfg: mon ? mon[1].trim() : "", model: mon ? mon[2].trim() : "",
               output: conn ? conn[1] : "" })
  }
  return out
}

// Picks the bus to talk to: the XB273U first, then any Acer display, else "".
function pickBus(displays) {
  for (var i = 0; i < displays.length; i++)
    if (/XB273U/i.test(displays[i].model)) return displays[i].bus
  for (var j = 0; j < displays.length; j++)
    if (displays[j].mfg === "ACR") return displays[j].bus
  return ""
}

// Finds the Hyprland output `name` in `hyprctl monitors -j` and returns what is
// needed to re-apply it at another refresh rate: the geometry to keep, the
// current rate, and the rates the monitor offers at the current resolution.
// Each rate keeps the exact mode text Hyprland lists ("2560x1440@59.95Hz").
function parseMonitor(text, name) {
  var list
  try { list = JSON.parse(String(text || "")) } catch (e) { return null }
  if (!Array.isArray(list)) return null
  for (var i = 0; i < list.length; i++) {
    var m = list[i]
    if (m.name !== name) continue
    var prefix = m.width + "x" + m.height + "@"
    var rates = []
    for (var j = 0; j < (m.availableModes || []).length; j++) {
      var mode = String(m.availableModes[j])
      if (mode.indexOf(prefix) !== 0) continue
      rates.push({ hz: parseFloat(mode.slice(prefix.length)), mode: mode.replace(/Hz$/, "") })
    }
    rates.sort(function(a, b) { return b.hz - a.hz })
    return { name: m.name, width: m.width, height: m.height, x: m.x, y: m.y, scale: m.scale,
             transform: m.transform, refresh: m.refreshRate, rates: rates }
  }
  return null
}

// The rate in `rates` closest to `want`; the highest when `want` is 0 or less.
function nearestRate(rates, want) {
  if (!rates.length) return null
  if (!(want > 0)) return rates[0]
  var best = rates[0]
  for (var i = 1; i < rates.length; i++)
    if (Math.abs(rates[i].hz - want) < Math.abs(best.hz - want)) best = rates[i]
  return best
}

// True when `refresh` is nearer the high-performance rate than the balanced one.
function isHighPerformance(refresh, balanced, performance) {
  return Math.abs(refresh - performance) < Math.abs(refresh - balanced)
}

// Lua for `hyprctl eval` that applies `rate` to `mon`, keeping its position,
// scale and rotation. Returns "" when anything is not a plain value, because
// the monitor name ends up inside a Lua string.
function buildRateEval(mon, rate) {
  if (!mon || !rate) return ""
  if (!/^[A-Za-z0-9._-]+$/.test(mon.name)) return ""
  if (!/^\d+x\d+@[0-9.]+$/.test(rate.mode)) return ""
  var nums = [mon.x, mon.y, mon.scale, mon.transform]
  for (var i = 0; i < nums.length; i++) if (typeof nums[i] !== "number" || !isFinite(nums[i])) return ""
  return 'hl.monitor({ output = "' + mon.name + '", mode = "' + rate.mode + '", position = "' +
         mon.x + "x" + mon.y + '", scale = ' + mon.scale + ", transform = " + mon.transform + " })"
}

function presetLabel(value) {
  for (var i = 0; i < PRESETS.length; i++)
    if (PRESETS[i].value === value) return PRESETS[i].label
  return "0x" + ("0" + Number(value).toString(16)).slice(-2)
}

function hex(code) {
  return "0x" + ("0" + Number(code).toString(16)).slice(-2)
}

if (typeof module !== "undefined") {
  module.exports = { VCP: VCP, PRESETS: PRESETS, clamp: clamp, parseBrief: parseBrief,
                     parseDetect: parseDetect, pickBus: pickBus, presetLabel: presetLabel,
                     parseMonitor: parseMonitor, nearestRate: nearestRate,
                     isHighPerformance: isHighPerformance, buildRateEval: buildRateEval,
                     enqueue: enqueue, takeNext: takeNext, hex: hex }
}
