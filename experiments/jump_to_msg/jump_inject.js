// Drop this into a puppeteer page.evaluate() against an authenticated web.whatsapp.com tab
// (e.g. the one whatsapp-web.js drives). It tries every candidate MsgKey._serialized
// form for a (phone, stanza, lid) triple and invokes the same internal jump-to-message
// path that whatsapp-web.js's openChatWindowAt uses:
//
//   Store.SearchContext.getSearchContext(chat, msg.id)  ──►  Store.Cmd.openChatAt({chat, msgContext})
//
// Returns {ok, used, tried} so the caller knows which key resolved.

window.WAJump = window.WAJump || {};

window.WAJump.candidates = function (phone, stanza, lid) {
  phone = String(phone).replace(/[^0-9]/g, '');
  lid = String(lid).split('@')[0];
  const remotes = [
    `${phone}@c.us`,
    `${phone}@s.whatsapp.net`,
    `${lid}@lid`,
  ];
  const out = [];
  for (const fromMe of ['false', 'true']) {
    for (const remote of remotes) {
      out.push(`${fromMe}_${remote}_${stanza}`);
    }
  }
  return out;
};

window.WAJump.findMsg = async function (key) {
  const Store = window.Store;
  let msg = Store.Msg.get(key);
  if (msg) return { msg, source: 'cache' };
  try {
    const res = await Store.Msg.getMessagesById([key]);
    if (res && res.messages && res.messages[0]) return { msg: res.messages[0], source: 'server' };
  } catch (_) {}
  return null;
};

window.WAJump.jumpToMessage = async function (phone, stanza, lid) {
  if (!window.Store || !window.Store.Cmd || !window.Store.SearchContext) {
    throw new Error('Store not injected — open the whatsapp-web.js page first');
  }
  const tried = [];
  for (const key of window.WAJump.candidates(phone, stanza, lid)) {
    tried.push(key);
    const hit = await window.WAJump.findMsg(key);
    if (!hit) continue;
    const remote = hit.msg.id.remote && hit.msg.id.remote._serialized
      ? hit.msg.id.remote._serialized
      : hit.msg.id.remote;
    const chat = window.Store.Chat.get(remote) || (await window.Store.Chat.find(remote));
    const ctx = await window.Store.SearchContext.getSearchContext(chat, hit.msg.id);
    await window.Store.Cmd.openChatAt({ chat, msgContext: ctx });
    return { ok: true, used: key, source: hit.source, tried };
  }
  return { ok: false, used: null, tried };
};
