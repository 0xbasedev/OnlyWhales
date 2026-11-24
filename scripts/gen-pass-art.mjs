// Generates the ten default pass artworks into public/pass/. Pin that folder to IPFS and put
// the URIs in config/prelaunch.json (tierURIs) before deploying.  node scripts/gen-pass-art.mjs
import { mkdirSync, writeFileSync } from 'node:fs'

const NAMES = ['Krill', 'Sardine', 'Dolphin', 'Orca', 'Humpback', 'Cachalot', 'Fin Whale', 'Blue Whale', 'Leviathan', 'Kraken']
const ROMAN = ['I', 'II', 'III', 'IV', 'V', 'VI', 'VII', 'VIII', 'IX', 'X']

// Steel blue at the shallow end, pale gold at the bottom of the ocean.
const mix = (a, b, t) => a.map((v, i) => Math.round(v + (b[i] - v) * t))
const rgb = (c) => `rgb(${c.join(',')})`

mkdirSync('public/pass', { recursive: true })
for (let i = 0; i < 10; i++) {
  const t = i / 9
  const accent = t < 0.6 ? mix([122, 150, 170], [143, 227, 245], t / 0.6) : mix([143, 227, 245], [232, 204, 146], (t - 0.6) / 0.4)
  const a = rgb(accent)
  const rings = Array.from({ length: i + 2 }, (_, k) => {
    const r = 70 + k * (200 / (i + 2))
    return `<circle cx="240" cy="270" r="${r.toFixed(1)}" fill="none" stroke="${a}" stroke-opacity="${(0.34 - k * (0.26 / (i + 2))).toFixed(3)}" stroke-width="1"/>`
  }).join('')
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 480 600" width="480" height="600">
<defs>
<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#0b1a26"/><stop offset=".55" stop-color="#060d14"/><stop offset="1" stop-color="#020507"/></linearGradient>
<radialGradient id="glow" cx="50%" cy="42%" r="55%"><stop offset="0" stop-color="${a}" stop-opacity="${(0.16 + t * 0.2).toFixed(2)}"/><stop offset="1" stop-color="${a}" stop-opacity="0"/></radialGradient>
<linearGradient id="fluke" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ffffff"/><stop offset="1" stop-color="${a}"/></linearGradient>
</defs>
<rect width="480" height="600" fill="url(#bg)"/>
<rect width="480" height="600" fill="url(#glow)"/>
${rings}
<path d="M240 336c0-46-9-76-56-104-42-25-84-21-112 0 38 0 70 17 93 46 25 32 53 45 75 58Zm0 0c0-46 9-76 56-104 42-25 84-21 112 0-38 0-70 17-93 46-25 32-53 45-75 58Z" fill="url(#fluke)"/>
<path d="M240 336v70" stroke="${a}" stroke-opacity=".5" stroke-width="2" stroke-linecap="round"/>
<path d="M120 420c40-18 80-18 120 0s80 18 120 0" fill="none" stroke="${a}" stroke-opacity=".5" stroke-width="1.5" stroke-linecap="round"/>
<path d="M150 446c30-12 60-12 90 0s60 12 90 0" fill="none" stroke="${a}" stroke-opacity=".25" stroke-width="1.5" stroke-linecap="round"/>
<text x="40" y="66" font-family="Georgia, 'Times New Roman', serif" font-size="22" fill="#eaf2f6" letter-spacing=".5">OnlyWhales</text>
<text x="440" y="66" text-anchor="end" font-family="Georgia, 'Times New Roman', serif" font-style="italic" font-size="30" fill="${a}">${ROMAN[i]}</text>
<text x="40" y="528" font-family="Georgia, 'Times New Roman', serif" font-size="46" fill="#eaf2f6">${NAMES[i]}</text>
<text x="40" y="560" font-family="ui-monospace, Menlo, monospace" font-size="12" fill="#62757f" letter-spacing="2.4">TIER ${i + 1} OF 10 · SOULBOUND</text>
<rect x="12" y="12" width="456" height="576" rx="22" fill="none" stroke="${a}" stroke-opacity=".28"/>
</svg>
`
  writeFileSync(`public/pass/tier-${i + 1}.svg`, svg)
}
console.log('public/pass/tier-1.svg … tier-10.svg')
