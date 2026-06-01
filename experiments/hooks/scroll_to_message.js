// Frida hook to capture WhatsApp's internal message-jump call chain.
// We hook the entry points we found via binary analysis and log every
// invocation with arguments + stack trace.

const TARGETS = [
    'WAChatViewController- scrollToMessage:fromMessage:pushingOnStack:',
    'WAChatViewController- scrollToMessage:fromMessage:pushingOnStack:messagesToHighlightAfterScroll:animated:',
    'WAChatViewController- openChatWithJIDString:prefilledMessage:',
    'WAChatViewController- openChatWithJIDString:prefilledMessage:currentContext:',
    'WAChatViewController- openChatWithChatJID:',
    'WAChatViewController- openChatWithChatJID:completion:',
    'WAChatViewController- openChatWithPresenter:animated:',
    'WADeepLinkRoot- parseURL:context:',
    'WADeepLinkRoot- openChatURL:',
];

function tryHookSelector(className, selector) {
    try {
        const cls = ObjC.classes[className];
        if (!cls) return false;
        const method = cls['- ' + selector];
        if (!method) return false;
        Interceptor.attach(method.implementation, {
            onEnter(args) {
                const argCount = selector.split(':').length - 1;
                const argStrs = [];
                for (let i = 0; i < argCount; i++) {
                    try {
                        const a = new ObjC.Object(args[2 + i]);
                        argStrs.push(a.toString());
                    } catch (e) {
                        argStrs.push(`<${args[2 + i]}>`);
                    }
                }
                send({
                    type: 'call',
                    className,
                    selector,
                    args: argStrs,
                    timestamp: Date.now()
                });
                const bt = Thread.backtrace(this.context, Backtracer.ACCURATE)
                    .slice(0, 12)
                    .map(DebugSymbol.fromAddress)
                    .map(s => `${s.moduleName}!${s.name}+0x${s.address}`);
                send({ type: 'stack', frames: bt });
            }
        });
        send({ type: 'hooked', className, selector });
        return true;
    } catch (e) {
        send({ type: 'hook-error', className, selector, error: e.toString() });
        return false;
    }
}

// Enumerate all classes that look like chat controllers, scroll handlers,
// or deeplink processors so we can adapt our hook set even if class names differ.
function findCandidateClasses() {
    const matches = [];
    for (const name in ObjC.classes) {
        if (/ChatView|ChatVC|ChatController|DeepLink|MessageNavi|MessageNav|ScrollToMessage/i.test(name)) {
            matches.push(name);
        }
    }
    return matches;
}

rpc.exports = {
    init() {
        const candidates = findCandidateClasses();
        send({ type: 'candidates', classes: candidates.slice(0, 40), total: candidates.length });

        // Try the static target list first
        for (const t of TARGETS) {
            const [cls, sel] = t.split('- ');
            tryHookSelector(cls.trim(), sel.trim());
        }

        // Then try every candidate's likely message-jump methods
        for (const cls of candidates) {
            const klass = ObjC.classes[cls];
            const methods = klass.$ownMethods || [];
            for (const m of methods) {
                if (/scrollToMessage|openMessage|jumpToMessage|navigateToMessage|openChatWith/i.test(m)) {
                    tryHookSelector(cls, m.replace(/^- /, ''));
                }
            }
        }

        return 'hooks installed';
    }
};
