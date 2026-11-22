import fs from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
const require = createRequire(import.meta.url);
const sharp = require('sharp');
const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const source = process.argv[2];
if (!source) throw new Error('Provide the DuoLayoutRenders directory');
const pages = ['01-today','02-mood','03-sleep','04-trends','05-scenes','06-privacy'];
const labels = ['今日','心情','助眠','趋势','个性化主题','隐私说明'];
const records = [];
const tiles = [];
for (const [row, screen, w, h] of [[0,'outer',1398,2034],[1,'inner',2007,2853]]) {
  await fs.mkdir(path.join(root,screen), {recursive:true});
  for (const [i,page] of pages.entries()) {
    const input = path.join(source,`${screen}-${page}-${w}x${h}.png`);
    const relative = `${screen}/${page}-${w}x${h}.png`;
    const output = path.join(root,relative);
    const before = await sharp(input).metadata();
    if (before.width !== w || before.height !== h) throw new Error(`Incorrect render dimensions: ${input}`);
    await sharp(input).removeAlpha().toColourspace('srgb').png().toFile(output);
    const m = await sharp(output).metadata();
    if (m.hasAlpha || m.channels !== 3 || m.space !== 'srgb') throw new Error(`Unexpected PNG format: ${output}`);
    records.push({file:relative,width:m.width,height:m.height,channels:m.channels,hasAlpha:m.hasAlpha,space:m.space});
    const thumb = await sharp(output).resize({width:300}).png().toBuffer();
    tiles.push({input:thumb,left:54+i*328,top:105+row*550});
  }
}
const text = `<svg width="2048" height="1210" xmlns="http://www.w3.org/2000/svg"><style>text{font-family:-apple-system,'PingFang SC',sans-serif;fill:#243e50} .title{font-size:34px;font-weight:600}.label{font-size:24px}</style><rect width="2048" height="1210" fill="#eef2f5"/><text x="54" y="62" class="title">小晴空 · 外屏界面</text><text x="54" y="612" class="title">小晴空 · 内屏界面</text>${[0,1].map(row=>labels.map((label,i)=>`<text x="${204+i*328}" y="${580+row*550}" text-anchor="middle" class="label">${label}</text>`).join('')).join('')}</svg>`;
await sharp(Buffer.from(text)).composite(tiles).removeAlpha().png().toFile(path.join(root,'overview.png'));
await fs.writeFile(path.join(root,'verification.json'),JSON.stringify({brand:'小晴空',generatedAt:new Date().toISOString(),method:'Existing SwiftUI views rendered at custom canvas sizes on iOS 26.5; not a Duo device capture',nativeDuoVerified:false,visibleMockupWatermark:false,files:records},null,2));
console.log(`Verified ${records.length} pure interface images.`);
