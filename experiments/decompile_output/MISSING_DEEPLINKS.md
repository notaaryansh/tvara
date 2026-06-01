# DeepLink subclasses we never decompiled

Total inheriting from WADeepLinkRoot: **120**
Decompiled in `decompiled_20260530-182958.txt`: **11**
Missing parseURL bodies: **109**

The 11 we have: WAChatListDeepLink, WAContactDeepLink, WAExternalMediaShareDeepLink,
WAMessageDeepLink, WAMessageYourselfDeepLink, WANavigationDeepLink, WAOAuthCallbackDeepLink,
WAOpenChatDeepLink, WASendDeepLink, WAShareWhatsAppWebDeepLink, WAStatusShareDeepLink.

---

## High-priority for the message-jump hunt

These look most likely to accept a message reference, chat reference, or
chat-jumping behavior — fold them into the next Ghidra run first.

- **WANewsletterDeepLink** ← `whatsapp://c/<X>` channel handler (your finding)
- **WANewsletterStatusDeepLink** ← channel status posts
- **WAUsernameDeepLink** ← username-routed chat opens (new 2026 feature)
- **WAUsernameCreationDeepLink**
- **WABizUsernameDeepLink**
- **WAFavoritesDeepLink** ← favorites tab w/ chat refs
- **WAListsDeepLink** ← lists tab w/ chat refs
- **WAManageListsDeepLink**
- **WAGroupInviteDeepLink** ← chat.whatsapp.com/<code> handler
- **WAEventsGroupDeepLink** ← may include message anchor for event posts
- **WASharableEventDeepLink**
- **WAGroupParticipantPickerDeepLink**
- **WAParentGroupDeepLink** ← community parent group opens
- **WACommunitiesFilterDeepLink**
- **WAPhoenixDeepLink** ← Bloks dispatcher; WANavigationDeepLink defers here
- **WACustomURLDeepLink** ← catch-all custom URL handler
- **WACrossPostDeepLink** ← cross-post from another surface w/ msg ref
- **WACallPhoneNumberDeepLink**
- **WAClickToCallDeepLink**
- **WACallingLink.CallLinkDeepLink**
- **WACallHistoryTabDeepLink**

---

## SMB / Business — lower priority for message jump

Mostly route to business-tool surfaces, not chat.

- WAAdvertiseDeepLink
- WABizCatalogAddProductDeepLink
- WABizCatalogBoostDeepLink
- WABizCatalogSettingsDeepLink
- WABizProfileDeepLink
- WABizTabDeepLink
- WABizToolsDeepLink
- WACatalogDeepLink
- WAProductDeepLink
- WASMBAiAdSuggestionDeepLink
- WASMBAIAgentOnboardingFromConsumerDeepLink
- WASMBBillingHubDeepLink
- WASMBBizLinkFacebookDeepLink
- WASMBBizLinkInstagramDeepLink
- WASMBBusinessSearchDeepLink
- WASMBConnectedProfilesDeepLink
- WASMBDailyAdsSummaryDeepLink
- WASMBDeepLinks.SMBMetaProEngagement
- WASMBDraftAdDeepLink
- WASMBEditProfileDeepLink
- WASMBInstallDeepLink
- WASMBManageAdsDeepLink
- WASMBMetaVerifiedDeepLink
- WASMBMetaVerifiedNotificationDeepLink
- WASMBPremiumBroadcastDeepLink
- WASMBPremiumDeepLink
- WASMBRecreateAdDeepLink
- WASMBScaleGoodCampaignDeepLink
- WASMBToolsDeepLink

---

## Settings / account / onboarding — low priority

- WAAboutPrivateProcessingDeepLink
- WAABPropDeepLink
- WAAccountsCenterAddAccountDeepLink
- WAAIDeepLink
- WAAIInGroupsDeepLink
- WAApplicationDeepLink
- WAAvatarEditorDeepLink
- WABillReminderCampaignDeepLink
- WACalendarAuthDeepLink
- WAChatPSATryItDeepLink
- WAConsentFlowDeepLink
- WADeepLinks.WAFOADeepLinkHandler
- WADeepLinks.WAMODeepLink     ← WAMO server flow; might intercept message URLs
- WADeepLinkWithStandardAppSwitcher
- WADefaultMessagingDeepLink
- WADownloadDeepLink
- WAFileDeepLink
- WAFirstPartyStickerPackDeepLink
- WAFPMDeepLink
- WAHatchLinkDeepLink           ← experimental
- WAHelpDeepLink
- WALinkAccountsDeepLink
- WAManusLinkDeepLink           ← experimental
- WAMultiAccountSwitcherDeepLink
- WANovaWaitlistDeepLink
- WAPAALinkingDeepLink
- WAPaymentDeepLink
- WAPaymentUPIDeepLink
- WAPrivacyDisclosureDeepLink
- WAProxyV2DeepLink
- WASetAboutDeepLink
- WASettingsLinkedDevicesDeepLink
- WAShareExtensionMediaShareDeepLink
- WAShareExtensionStatusMediaShareDeepLink
- WASideChatImagineDeepLink
- WASilverstoneDeepLink         ← experimental
- WASSOCallbackDeepLink
- WAStickerStoreDeepLink
- WASubscriptionHubDeepLink
- WASubscriptionsDeepLink
- WASupportDeepLink
- WASurveyDeepLink
- WAThirdPartyLinkingDeepLink
- WAThirdPartyStickerPackDeepLink
- WAThreePGroupCreateDeepLink
- WAThunderstormDeepLink        ← experimental
- WAUnknownDeepLink             ← fallback for unrecognized URLs
- WAVerificationOTPDeepLink
- WAWaffleDeepLink              ← experimental
- WAWaMeDownloadDeepLink
- WAWaMeSubscriptionDeepLink
- WAWAMOAFSConsentFlowDeepLink
- WAWAMOAFSOverpaymentDeepLink
- WAWAMOAFSTOSDeepLink
- WAWAMOAFSUnlinkYouthCancelSubscriptionDeepLink
- WAWatchUpsellBottomSheetDeeplink
- WAWidgetDeepLink
- WAXPlatformMigrationDeepLink
- WACalling.GroupCallPSADeepLink
