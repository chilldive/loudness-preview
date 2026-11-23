// Packs PNGs into a Windows .ico (PNG-compressed entries)
import fs from 'fs'
const sizes = [16, 24, 32, 48, 64, 128, 256]
const pngs = sizes.map((s) => fs.readFileSync(new URL(`./app/assets/icon${s}.png`, import.meta.url)))
const head = Buffer.alloc(6 + 16 * sizes.length)
head.writeUInt16LE(0, 0); head.writeUInt16LE(1, 2); head.writeUInt16LE(sizes.length, 4)
let off = head.length
sizes.forEach((s, i) => {
  const o = 6 + 16 * i
  head.writeUInt8(s >= 256 ? 0 : s, o); head.writeUInt8(s >= 256 ? 0 : s, o + 1)
  head.writeUInt16LE(1, o + 4); head.writeUInt16LE(32, o + 6)
  head.writeUInt32LE(pngs[i].length, o + 8); head.writeUInt32LE(off, o + 12)
  off += pngs[i].length
})
fs.writeFileSync(new URL('./app/assets/icon.ico', import.meta.url), Buffer.concat([head, ...pngs]))
