// node jump_via_puppeteer.js
// Drives the SAME Chrome user-data-dir whatsapp-web.js already authenticated
// (whatsapp-web.js/whatsapp_profile), injects window.WAJump, and tries to jump
// to the configured message. Designed to verify which MsgKey form works for the
// LID/PN-addressed chat with drishtu.
//
// Why this and not whatsapp-web.js's `openChatWindowAt`?  openChatWindowAt insists
// on a single msgId string the caller already knows is right.  We don't — LID
// addressing means the legacy key form may be wrong.  WAJump tries them all.

const puppeteer = require('puppeteer');
const fs = require('fs');
const path = require('path');

const PROFILE = '/Users/aaryanshsahay/Documents/GitHub/whatsapp-web.js/whatsapp_profile';
const INJECT = fs.readFileSync(path.join(__dirname, 'jump_inject.js'), 'utf8');

const PHONE = '919325525029';
const STANZA = '3A8D5E50D816940D7DC5';
const LID = '198535031029815@lid';

(async () => {
  const browser = await puppeteer.launch({
    headless: false,
    userDataDir: PROFILE,
    args: ['--no-sandbox'],
    defaultViewport: null,
  });
  const [page] = await browser.pages();
  await page.goto('https://web.whatsapp.com/', { waitUntil: 'domcontentloaded' });

  // Wait until WhatsApp Web is ready (Store available). We don't reinject the
  // whole whatsapp-web.js Store — we expect the existing profile to already be
  // running it, OR we hook the page's own require() to grab the modules.
  await page.waitForFunction(
    () => window.require && (window.Store || window.require('WAWebCmd')),
    { timeout: 0 },
  );

  // Build a minimal Store if whatsapp-web.js didn't inject (e.g. fresh profile)
  await page.evaluate(() => {
    if (window.Store && window.Store.Cmd && window.Store.SearchContext) return;
    window.Store = window.Store || {};
    window.Store.Cmd = window.require('WAWebCmd').Cmd;
    window.Store.Msg = window.require('WAWebCollections').Msg;
    window.Store.Chat = window.require('WAWebCollections').Chat;
    window.Store.SearchContext = window.require('WAWebChatMessageSearch');
  });

  await page.evaluate(INJECT);

  const result = await page.evaluate(
    async (p, s, l) => window.WAJump.jumpToMessage(p, s, l),
    PHONE,
    STANZA,
    LID,
  );

  console.log(JSON.stringify(result, null, 2));
  // Keep the browser open so you can SEE whether the chat scrolled+highlighted.
  // Close with ctrl-c.
})();
