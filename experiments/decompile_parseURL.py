# Ghidra headless script — extracts decompiled C-pseudo for every function
# we care about in WhatsApp's binary. Runs after the (slow) initial
# auto-analysis pass.
#
# Targets:
#   1. Every DeepLink subclass's parseURL:context: — the URL parsers
#   2. scrollToMessage: variants — the scroll-and-highlight method
#   3. notificationWindow:openChatWithMessage:inputText: — the path that
#      gets called from a real notification tap (gold standard)
#   4. bannerStateControllerDidTapOnChatPreviewWithTargetMessage:inputText:
#   5. openChatViewControllerFor:userContext:message:
#   6. Catch-all: any function whose name contains parseURL, DeepLink,
#      scrollToMessage, openChat with message, notification with message.
#
# Output goes to stdout; the calling Python wraps it.

from ghidra.app.decompiler import DecompInterface
from ghidra.util.task import ConsoleTaskMonitor

# Exact selector signatures we explicitly want
EXPLICIT_TARGETS = [
    "-[WADeepLinkRoot parseURL:context:]",
    "-[WACTWAParsedDeepLink parseURL:context:]",
    "-[WAMessageDeepLink parseURL:context:]",
    "-[WASendDeepLink parseURL:context:]",
    "-[WAOpenChatDeepLink parseURL:context:]",
    "-[WAContactDeepLink parseURL:context:]",
    "-[WANavigationDeepLink parseURL:context:]",
    "-[WAChatListDeepLink parseURL:context:]",
    "-[WAMessageYourselfDeepLink parseURL:context:]",
    "-[WAOpenChatDeepLink handleDeepLinkWithRootVC:]",
    "-[WADeepLinkRoot openChatURL:]",
    "-[WADeepLinksProvider contactCodeForMessageDeepLinkWithUrl:context:]",
    "-[WACTWADeepLinkValidator linkCanBeUsedToOpenChat]",
    "-[WACTWADeepLinkValidator sanitizedText:]",
    "scrollToMessage:fromMessage:pushingOnStack:",
    "scrollToMessage:fromMessage:pushingOnStack:messagesToHighlightAfterScroll:animated:",
    "notificationWindow:openChatWithMessage:inputText:",
    "bannerStateControllerDidTapOnChatPreviewWithTargetMessage:inputText:",
    "cardBannerViewControllerDidTapOnChatPreviewWithTargetMessage:inputText:",
    "openChatViewControllerFor:userContext:message:",
    "application:openURL:options:",
    "application:openURL:sourceApplication:annotation:",
    "userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:",
    "messageNotificationTappedWithAccountUUID:notificationID:",
    "wa_contactCode",
    "wa_isShortAPILink",
    "wa_isSendLinkCustomURL",
    "wa_deepLinkPathComponentAtPosition:",
]

# Pattern fallback — any function name containing these substrings
PATTERN_MATCHES = [
    "parseURL",
    "scrollToMessage",
    "openChatWithMessage",
    "notificationCenter",
    "didReceiveNotificationResponse",
    "DeepLinkValidator",
    "DeepLinksStore",
    "ContactCodeFromUrl",
    "ContactCode",
]

prog = currentProgram
fm = prog.getFunctionManager()
ifc = DecompInterface()
ifc.openProgram(prog)
monitor = ConsoleTaskMonitor()


def find_functions(needle):
    res = []
    for f in fm.getFunctions(True):
        n = f.getName(True)
        if needle in n:
            res.append(f)
    return res


def dump_function(func):
    print("=" * 78)
    print("FUNCTION: " + func.getName(True))
    print("Entry:    " + str(func.getEntryPoint()))
    print("Size:     " + str(func.getBody().getNumAddresses()) + " bytes")
    print("-" * 78)
    res = ifc.decompileFunction(func, 180, monitor)
    if res and res.decompileCompleted():
        print(res.getDecompiledFunction().getC())
    else:
        print("Decompile failed: " + (res.getErrorMessage() if res else "no result"))
    print("")


seen_entries = set()

# Phase 1: explicit targets
print("\n\n############# PHASE 1: explicit targets ############\n")
for needle in EXPLICIT_TARGETS:
    funcs = find_functions(needle)
    if not funcs:
        print(">>> NOT FOUND: " + needle + "\n")
        continue
    for f in funcs:
        ep = f.getEntryPoint()
        if ep in seen_entries:
            continue
        seen_entries.add(ep)
        dump_function(f)

# Phase 2: pattern matches
print("\n\n############# PHASE 2: pattern matches ############\n")
for needle in PATTERN_MATCHES:
    funcs = find_functions(needle)
    for f in funcs[:8]:  # cap to avoid runaway output per pattern
        ep = f.getEntryPoint()
        if ep in seen_entries:
            continue
        seen_entries.add(ep)
        dump_function(f)

print("\n\n############# DONE ############\n")
print("Total functions decompiled: " + str(len(seen_entries)))
