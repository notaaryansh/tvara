// Ghidra Java script — extracts decompiled C-pseudo for the URL parser
// functions in WhatsApp's binary. Runs against an existing analyzed project.
//
// Run with:
//   analyzeHeadless /tmp/ghidra_proj wa_project \
//     -process WhatsApp -postScript DecompileParseURL.java \
//     -scriptPath /Users/.../experiments

import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.util.task.ConsoleTaskMonitor;
import java.util.HashSet;
import java.util.Set;

public class DecompileParseURL extends GhidraScript {

    private static final String[] EXPLICIT_TARGETS = {
        "WADeepLinkRoot",
        "WACTWAParsedDeepLink",
        "WAMessageDeepLink",
        "WASendDeepLink",
        "WAOpenChatDeepLink",
        "WAContactDeepLink",
        "WANavigationDeepLink",
        "WAChatListDeepLink",
        "WAMessageYourselfDeepLink",
        "WAExternalMediaShareDeepLink",
        "WAOAuthCallbackDeepLink",
        "WAStatusShareDeepLink",
        "WAShareWhatsAppWebDeepLink",
        "WACTWADeepLinkValidator",
        "WADeepLinksProvider",
        "scrollToMessage",
        "openChatViewControllerFor",
        "notificationWindow",
        "bannerStateController",
        "cardBannerView",
        "messageNotificationTapped",
        "didReceiveNotificationResponse",
        "wa_contactCode",
        "wa_deepLinkPathComponentAtPosition",
        "wa_isShortAPILink",
        "wa_isSendLinkCustomURL",
        "linkCanBeUsedToOpenChat",
        // Round 2 — high-priority misses (chat/message-aware deep links)
        "WANewsletterDeepLink",
        "WANewsletterStatusDeepLink",
        "WAUsernameDeepLink",
        "WABizUsernameDeepLink",
        "WAGroupInviteDeepLink",
        "WAFavoritesDeepLink",
        "WAListsDeepLink",
        "WAManageListsDeepLink",
        "WAEventsGroupDeepLink",
        "WASharableEventDeepLink",
        "WAParentGroupDeepLink",
        "WACommunitiesFilterDeepLink",
        "WAPhoenixDeepLink",
        "WACustomURLDeepLink",
        "WACrossPostDeepLink",
        "WACallPhoneNumberDeepLink",
        "WAClickToCallDeepLink",
        "WAMODeepLink",
        // Round 3 — registry/dispatcher (find the master list of parsers)
        "DeepLinkTypeRegistry",
        "WADeepLinkParser",
        "allDeepLinkTypes",
        "deepLinkWithURL",
        "deepLinkClassTypesWithContext",
        "canOpenDeepLinkWithURL",
        // Round 6 — the message-jump UI handlers + NSUserActivity entry point
        "jumpToQuotedMessage",
        "jumpToQuotedChatSession",
        "highlightMessageTemporarily",
        "scrollToAndHighlightRow",
        "didTapQuotedItemWithReplyContext",
        "didRequestScrollToQuotedMessage",
        "continueUserActivity",
        "INSearchForMessages",
        // Round 7 — the CoreSpotlight entry point (the REAL doorway)
        "continueSpotlightUserActivityWith",
        "CSSearchableItem",
        "indexableItemForMessage",
        "searchableItemForMessage",
        "uniqueIdentifierForMessage",
        "indexMessage",
        // Round 8 — the message lookup + navigation API surface
        "fetchMessageWithMessageID",
        "fetchMessageWithStanzaID",
        "messageWithMessageID",
        "showMessage:",
        "setTargetMessage",
        "setFocusedMessage",
        "navigateToMessage"
    };

    // Address-based targets (Round 8 additions for methods without unique name match)
    // 0x105ce1d7c — showMessage: (method 180 — big VC class)
    // 0x103ccdbb0 — setTargetMessage:
    // 0x105049130, 0x105805790, 0x10506b240, 0x105071d2c — bubbleTableViewCell:didRequestScrollToQuotedMessage: impls

    // Round 4 — Swift-side registry helpers (no symbols, decompile by VA)
    private static final long[] EXPLICIT_ADDRESSES = {
        0x10197a5f5L, // enum_case → Class mapper called from DeepLinkTypeRegistry.allDeepLinkTypes
        0x10197a682L, // returns Swift array of enum cases (the dynamic registry)
        0x1019bf8bfL, // WANewsletterDeepLink's actual Swift parseURL body
        // Round 5 — WAChatPresenter constructors + scroll/identifier APIs
        0x1055d37ccL, // +[WAChatPresenter forMessage:searchTerms:style:] — the HIGHLIGHT path
        0x1055d3584L, // +[WAChatPresenter forJID:userContext:] — the JID-only path
        0x1055d2f58L, // +[WAChatPresenter forContact:userContext:]
        0x1055d2ec4L, // +[WAChatPresenter forChatSession:]
        0x101dce7dcL, // -[? chatPresenterForIdentifier:] — string-id constructor
        0x1055d46f8L, // -[WAChatPresenter messageToScrollTo] — getter
        // Round 8 — direct addresses
        0x105ce1d7cL, // showMessage: (method 180 — big VC class)
        0x103ccdbb0L, // setTargetMessage:
        0x105049130L, // bubbleTableViewCell:didRequestScrollToQuotedMessage: impl A
        0x105805790L, // bubbleTableViewCell:didRequestScrollToQuotedMessage: impl B
        0x10506b240L, // bubbleTableViewCell:didRequestScrollToQuotedMessage: impl C
        0x105071d2cL, // bubbleTableViewCell:didRequestScrollToQuotedMessage: impl D
        0x1009c7c08L, // Payments.WAPaymentManager fetchMessageWithMessageID:
        0x1015a530cL  // WAHistorySync.HistorySyncCompanionStorageImpl fetchMessageWithMessageID:
    };

    @Override
    public void run() throws Exception {
        DecompInterface ifc = new DecompInterface();
        ifc.openProgram(currentProgram);
        ConsoleTaskMonitor monitor = new ConsoleTaskMonitor();
        FunctionManager fm = currentProgram.getFunctionManager();

        Set<Long> seen = new HashSet<>();
        int totalDecompiled = 0;

        println("############# DECOMPILE TARGETS #############");
        println("Total functions in program: " + fm.getFunctionCount());

        for (String needle : EXPLICIT_TARGETS) {
            int matches = 0;
            for (Function f : fm.getFunctions(true)) {
                String name = f.getName(true);
                if (!name.contains(needle)) continue;
                long entry = f.getEntryPoint().getOffset();
                if (seen.contains(entry)) continue;
                seen.add(entry);
                matches++;

                println("============================================================");
                println("FUNCTION: " + name);
                println("Entry:    0x" + Long.toHexString(entry));
                println("Size:     " + f.getBody().getNumAddresses() + " bytes");
                println("------------------------------------------------------------");

                DecompileResults res = ifc.decompileFunction(f, 180, monitor);
                if (res != null && res.decompileCompleted()) {
                    println(res.getDecompiledFunction().getC());
                    totalDecompiled++;
                } else {
                    println("[decompile FAILED: " +
                        (res != null ? res.getErrorMessage() : "no result") + "]");
                }
                println("");
            }
            if (matches == 0) {
                println(">>> NOT FOUND: " + needle);
            }
        }

        // Address-based decomp (for Swift-side fns that have no usable name)
        for (long va : EXPLICIT_ADDRESSES) {
            Address addr = currentProgram.getAddressFactory()
                                        .getDefaultAddressSpace()
                                        .getAddress(va);
            Function f = fm.getFunctionContaining(addr);
            if (f == null) {
                println(">>> NO FUNCTION AT 0x" + Long.toHexString(va));
                continue;
            }
            long entry = f.getEntryPoint().getOffset();
            if (seen.contains(entry)) continue;
            seen.add(entry);

            println("============================================================");
            println("FUNCTION: " + f.getName(true) + " (by VA 0x" + Long.toHexString(va) + ")");
            println("Entry:    0x" + Long.toHexString(entry));
            println("Size:     " + f.getBody().getNumAddresses() + " bytes");
            println("------------------------------------------------------------");

            DecompileResults res = ifc.decompileFunction(f, 180, monitor);
            if (res != null && res.decompileCompleted()) {
                println(res.getDecompiledFunction().getC());
                totalDecompiled++;
            } else {
                println("[decompile FAILED: " +
                    (res != null ? res.getErrorMessage() : "no result") + "]");
            }
            println("");
        }

        println("############# DONE #############");
        println("Total functions decompiled: " + totalDecompiled);
    }
}
