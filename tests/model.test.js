const M = require('../Model.js'), a = require('assert')

const real = `Display 1
   I2C bus:          /dev/i2c-9
   DRM connector:    card1-DP-3
   drm_connector_id: 526
   Monitor:          ACR:XB273U V3:1322131231233
`
a.deepStrictEqual(M.parseDetect(real), [{ bus: '9', mfg: 'ACR', model: 'XB273U V3', output: 'DP-3' }], 'real ddcutil detect --brief')
a.strictEqual(M.pickBus(M.parseDetect(real)), '9')

const two = `Display 1
   I2C bus:          /dev/i2c-5
   Monitor:          BOE:NE135:

Display 2
   I2C bus:          /dev/i2c-12
   Monitor:          ACR:XB273K:X

Display 3
   I2C bus:          /dev/i2c-7
   Monitor:          ACR:XB273U V3:Y
`
a.strictEqual(M.pickBus(M.parseDetect(two)), '7', 'XB273U V3 preferred over other Acer')
a.strictEqual(M.pickBus(M.parseDetect(two.replace('XB273U V3', 'XB273K'))), '12', 'Acer fallback')
a.strictEqual(M.pickBus(M.parseDetect('Display 1\n   I2C bus: /dev/i2c-3\n   Monitor: DEL:U2720Q:\n')), '', 'no Acer')
a.strictEqual(M.pickBus(M.parseDetect('No displays found.\n')), '', 'empty')

a.deepStrictEqual(M.parseBrief('VCP 10 C 25 100\nVCP 12 C 50 100\nVCP 14 SNC x06\n'), { 16: 25, 18: 50, 20: 6 })
a.deepStrictEqual(M.parseBrief('VCP 16 C 50 100\nVCP 18 C 50 100\nVCP 1A C 50 100\n'), { 22: 50, 24: 50, 26: 50 })
a.deepStrictEqual(M.parseBrief('VCP 99 CNC x00 x02 x00 x01\nVCP 10 ERR\nnoise\n'), { 153: 1 })
a.deepStrictEqual(M.parseBrief(''), {})
a.deepStrictEqual(M.parseBrief(undefined), {})

a.strictEqual(M.presetLabel(6), '7500 K')
a.strictEqual(M.presetLabel(0x0f), '0x0f')
a.strictEqual(M.hex(0x1a), '0x1a')
a.strictEqual(M.hex(0x10), '0x10')
a.strictEqual(M.clamp(150, 0, 100), 100)
a.strictEqual(M.clamp(-4, 0, 100), 0)
a.strictEqual(M.clamp('x', 0, 100), 0)
a.strictEqual(M.clamp(12.6, 0, 100), 13)

let p = {}
p = M.enqueue(p, 16, 30); p = M.enqueue(p, 16, 40); p = M.enqueue(p, 18, 55)
a.deepStrictEqual(p, { 16: 40, 18: 55 }, 'newest value wins')
const n = M.takeNext(p)
a.deepStrictEqual([n.code, n.value], [16, 40])
a.deepStrictEqual(n.rest, { 18: 55 })
a.strictEqual(M.takeNext({}), null)
a.deepStrictEqual(p, { 16: 40, 18: 55 }, 'enqueue/takeNext do not mutate input')
const mons = JSON.stringify([
  { name: 'eDP-1', width: 1920, height: 1200, x: 0, y: 0, scale: 1, transform: 0, refreshRate: 60,
    availableModes: ['1920x1200@60.00Hz'] },
  { name: 'DP-3', width: 2560, height: 1440, x: 0, y: 0, scale: 1.25, transform: 0, refreshRate: 179.877,
    availableModes: ['2560x1440@179.88Hz', '2560x1440@59.95Hz', '2560x1440@120.00Hz', '1920x1080@120.00Hz'] }
])
const mon = M.parseMonitor(mons, 'DP-3')
a.strictEqual(mon.refresh, 179.877)
a.deepStrictEqual(mon.rates.map(r => r.hz), [179.88, 120, 59.95], 'only current resolution, highest first')
a.strictEqual(mon.rates[2].mode, '2560x1440@59.95')
a.strictEqual(M.parseMonitor(mons, 'HDMI-A-1'), null)
a.strictEqual(M.parseMonitor('not json', 'DP-3'), null)
a.strictEqual(M.parseMonitor('', 'DP-3'), null)

a.strictEqual(M.nearestRate(mon.rates, 60).hz, 59.95)
a.strictEqual(M.nearestRate(mon.rates, 144).hz, 120, 'closest available')
a.strictEqual(M.nearestRate(mon.rates, 0).hz, 179.88, 'zero means highest')
a.strictEqual(M.nearestRate([], 60), null)
a.strictEqual(M.isHighPerformance(179.877, 59.95, 179.88), true)
a.strictEqual(M.isHighPerformance(59.95, 59.95, 179.88), false)
a.strictEqual(M.isHighPerformance(100, 59.95, 179.88), false, 'nearer balanced')
a.strictEqual(M.isHighPerformance(120, 59.95, 179.88), true, 'nearer high performance')

a.strictEqual(M.buildRateEval(mon, mon.rates[2]),
  'hl.monitor({ output = "DP-3", mode = "2560x1440@59.95", position = "0x0", scale = 1.25, transform = 0 })')
a.strictEqual(M.buildRateEval({ ...mon, name: 'DP-3"}) os.execute("x") --' }, mon.rates[2]), '', 'unsafe name refused')
a.strictEqual(M.buildRateEval(mon, { hz: 60, mode: '2560x1440@60"; boom' }), '', 'unsafe mode refused')
a.strictEqual(M.buildRateEval({ ...mon, scale: 'x' }, mon.rates[2]), '', 'non-numeric scale refused')
a.strictEqual(M.buildRateEval(null, mon.rates[2]), '')
console.log('ok')
