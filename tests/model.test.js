const M = require('../Model.js'), a = require('assert')

const real = `Display 1
   I2C bus:          /dev/i2c-9
   DRM connector:    card1-DP-3
   drm_connector_id: 526
   Monitor:          ACR:XB273U V3:1322131231233
`
a.deepStrictEqual(M.parseDetect(real), [{ bus: '9', mfg: 'ACR', model: 'XB273U V3' }], 'real ddcutil detect --brief')
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
console.log('ok')
