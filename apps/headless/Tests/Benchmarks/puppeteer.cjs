const fs = require('fs');
const path = require('path');
const {spawn} = require('child_process');
const puppeteer = require('/opt/benchmark/node_modules/puppeteer-core');

(async () => {
  const output = process.env.BENCH_OUTPUT;
  const browser = await puppeteer.launch({
    executablePath: '/usr/bin/chromium',
    headless: true,
    defaultViewport: {width: 1160, height: 673},
    args: ['--disable-background-networking'],
  });
  const page = await browser.newPage();
  const encoder = spawn('ffmpeg', [
    '-hide_banner', '-loglevel', 'error', '-y', '-f', 'image2pipe', '-framerate', '5',
    '-vcodec', 'png', '-i', 'pipe:0', '-an', '-c:v', 'mpeg4', '-q:v', '4',
    '-pix_fmt', 'yuv420p', '-movflags', '+faststart', path.join(output, 'flow.mp4'),
  ], {stdio: ['pipe', 'ignore', 'ignore']});

  const tour = async () => {
    const maximum = await page.evaluate(() => Math.max(0, document.documentElement.scrollHeight - innerHeight));
    for (let step = 0; step <= 5; step++) {
      await page.evaluate(y => scrollTo(0, y), maximum * step / 5);
      encoder.stdin.write(await page.screenshot({type: 'png'}));
      await new Promise(resolve => setTimeout(resolve, 100));
    }
  };

  try {
    await page.goto(process.env.BENCH_URL, {waitUntil: 'load', timeout: 10000});
    await tour();
    const button = await page.waitForSelector(
      '::-p-xpath(//button[normalize-space()="Continue"])', {timeout: 10000});
    await Promise.all([page.waitForNavigation({waitUntil: 'load', timeout: 10000}), button.click()]);
    await page.waitForFunction(() => document.body.innerText.includes('Designer details'));
    await tour();
    await page.screenshot({path: path.join(output, 'final.png')});
  } finally {
    encoder.stdin.end();
    await new Promise((resolve, reject) => {
      encoder.once('exit', code => code === 0 ? resolve() : reject(new Error(`ffmpeg ${code}`)));
    });
    await browser.close();
  }
})().catch(error => { console.error(error); process.exit(1); });
