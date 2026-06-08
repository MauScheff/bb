import Foundation
import UIKit
import UserNotifications

enum AlertNotificationPermissionAction: Equatable {
    case observeOnly
    case requestAuthorization
    case registerForRemoteNotifications
}

enum AlertNotificationPermissionPolicy {
    static func startupAction(for status: UNAuthorizationStatus) -> AlertNotificationPermissionAction {
        switch status {
        case .authorized, .ephemeral, .provisional:
            return .registerForRemoteNotifications
        case .notDetermined, .denied:
            return .observeOnly
        @unknown default:
            return .observeOnly
        }
    }

    static func explicitRequestAction(for status: UNAuthorizationStatus) -> AlertNotificationPermissionAction {
        switch status {
        case .notDetermined:
            return .requestAuthorization
        case .authorized, .ephemeral, .provisional:
            return .registerForRemoteNotifications
        case .denied:
            return .observeOnly
        @unknown default:
            return .observeOnly
        }
    }
}

struct BackgroundDeliveredBeepReceipt: Equatable {
    let handle: String
    let normalizedHandle: String
    let beepID: String?
    let requestCount: Int?
}

extension PTTViewModel {
    var pendingIncomingBeepBadgeCount: Int {
        incomingBeepByContactID.count
    }

    var alertNotificationAuthorizationStatusText: String {
        switch notificationAuthorizationStatus {
        case .notDetermined:
            return "Push notifications not requested"
        case .denied:
            return "Push notifications denied"
        case .authorized:
            return "Push notifications enabled"
        case .provisional:
            return "Push notifications provisional"
        case .ephemeral:
            return "Push notifications ephemeral"
        @unknown default:
            return "Push notifications unknown"
        }
    }

    var needsAlertNotificationPermission: Bool {
        guard hasLoadedNotificationAuthorizationStatus else {
            return false
        }

        switch notificationAuthorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return false
        case .notDetermined, .denied:
            return true
        @unknown default:
            return true
        }
    }

    func configureAlertNotificationsIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        notificationAuthorizationStatus = settings.authorizationStatus
        hasLoadedNotificationAuthorizationStatus = true

        switch AlertNotificationPermissionPolicy.startupAction(for: settings.authorizationStatus) {
        case .registerForRemoteNotifications:
            UIApplication.shared.registerForRemoteNotifications()

        case .observeOnly:
            switch settings.authorizationStatus {
            case .notDetermined:
                diagnostics.record(
                    .pushToTalk,
                    message: "Alert notification authorization not requested yet",
                    metadata: ["requestPolicy": "deferred-until-user-action"]
                )

            case .denied:
                diagnostics.record(
                    .pushToTalk,
                    message: "Alert notifications denied",
                    metadata: [:]
                )

            case .authorized, .ephemeral, .provisional:
                break

            @unknown default:
                diagnostics.record(
                    .pushToTalk,
                    message: "Alert notification authorization unknown",
                    metadata: ["status": "\(settings.authorizationStatus.rawValue)"]
                )
            }

        case .requestAuthorization:
            diagnostics.record(
                .pushToTalk,
                level: .error,
                message: "Startup notification policy attempted to request authorization",
                metadata: ["status": "\(settings.authorizationStatus.rawValue)"]
            )
        }
    }

    func requestAlertNotificationPermissionPreflight() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        notificationAuthorizationStatus = settings.authorizationStatus
        hasLoadedNotificationAuthorizationStatus = true

        switch AlertNotificationPermissionPolicy.explicitRequestAction(for: settings.authorizationStatus) {
        case .requestAuthorization:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
                let refreshedSettings = await center.notificationSettings()
                notificationAuthorizationStatus = refreshedSettings.authorizationStatus
                diagnostics.record(
                    .pushToTalk,
                    message: "Alert notification authorization resolved",
                    metadata: ["granted": granted ? "true" : "false"]
                )
                if granted {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            } catch {
                diagnostics.record(
                    .pushToTalk,
                    level: .error,
                    message: "Alert notification authorization request failed",
                    metadata: ["error": error.localizedDescription]
                )
            }

        case .registerForRemoteNotifications:
            UIApplication.shared.registerForRemoteNotifications()

        case .observeOnly:
            switch settings.authorizationStatus {
            case .denied:
                diagnostics.record(
                    .pushToTalk,
                    message: "Alert notifications denied",
                    metadata: [:]
                )

            case .notDetermined, .authorized, .ephemeral, .provisional:
                break

            @unknown default:
                diagnostics.record(
                    .pushToTalk,
                    message: "Alert notification authorization unknown",
                    metadata: ["status": "\(settings.authorizationStatus.rawValue)"]
                )
            }
        }

        captureDiagnosticsState("alert-notification-permission")
    }

    func requestLocalNetworkPermissionPreflight() async {
        await localNetworkPermissionPreflight.run(
            diagnostics: diagnostics,
            stateDidChange: { [weak self] status in
                self?.localNetworkPreflightStatus = status
            }
        )
        captureDiagnosticsState("local-network-permission")
    }

    func handleReceivedAlertPushToken(_ token: Data) {
        let tokenHex = token.map { String(format: "%02x", $0) }.joined()
        alertPushTokenHex = tokenHex
        diagnostics.record(
            .pushToTalk,
            message: "Received alert push token",
            metadata: ["tokenPrefix": String(tokenHex.prefix(8))]
        )
        Task {
            await refreshDeviceRegistrationWithAlertPushTokenIfPossible()
        }
    }

    func handleFailedToRegisterForRemoteNotifications(_ error: Error) {
        diagnostics.record(
            .pushToTalk,
            level: .error,
            message: "Alert push token registration failed",
            metadata: ["error": error.localizedDescription]
        )
    }

    func handleForegroundBeepNotification(userInfo: [AnyHashable: Any]) async {
        let shouldSurfaceInAppBanner = shouldSurfaceForegroundBeepNotificationAsInAppBanner()
        clearBeepNotifications()
        diagnostics.record(
            .pushToTalk,
            message: "Foreground Beep notification received",
            metadata: beepNotificationDiagnostics(userInfo: userInfo).merging(
                [
                    "applicationState": String(describing: currentApplicationState()),
                    "protectedDataAvailable": String(protectedDataAvailableProvider()),
                    "surfaceInAppBanner": String(shouldSurfaceInAppBanner),
                    "suppressionActive": String(suppressIncomingBeepBannersDuringForegroundActivation),
                ],
                uniquingKeysWith: { _, new in new }
            )
        )

        if !shouldSurfaceInAppBanner {
            consumeDeliveredBeepNotificationUserInfosWithoutForegroundBanner(
                [userInfo],
                reason: "foreground-notification-not-active"
            )
            await refreshBeepStateAfterNotification(
                userInfo: userInfo,
                reason: "foreground-notification-not-active",
                allowsPendingForegroundSurface: false
            )
            reconcileIncomingBeepSurface(
                applicationState: currentApplicationState(),
                presentationPolicy: .markSeenWithoutBanner,
                allowsSelectedContact: true,
                allowsAlreadySurfacedBeep: true
            )
            return
        }

        if let handle = beepNotificationHandle(from: userInfo),
           let contact = openCachedBeepContactFromNotification(
               handle: handle,
               reason: "foreground-notification-immediate"
           ) {
            maybeQueuePendingForegroundBeepSurface(
                contact: contact,
                userInfo: userInfo,
                reason: "foreground-notification-immediate"
            )
        }
        await refreshBeepStateAfterNotification(userInfo: userInfo, reason: "foreground-notification")
        reconcileIncomingBeepSurface(
            applicationState: currentApplicationState(),
            allowsSelectedContact: true,
            allowsAlreadySurfacedBeep: true
        )
        await prewarmForegroundBeepNotificationContactIfIdle(
            userInfo: userInfo,
            reason: "foreground-notification"
        )
    }

    func shouldSurfaceForegroundBeepNotificationAsInAppBanner() -> Bool {
        currentApplicationState() == .active
            && protectedDataAvailableProvider()
            && !suppressIncomingBeepBannersDuringForegroundActivation
    }

    func handleBeepNotificationResponse(
        actionIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) async {
        switch actionIdentifier {
        case TurboNotificationCategory.acceptBeepAction:
            await handleBeepNotificationAcceptResponse(userInfo: userInfo)
        case TurboNotificationCategory.notNowBeepAction:
            await handleBeepNotificationNotNowResponse(userInfo: userInfo)
        default:
            await handleBeepNotificationResponse(userInfo: userInfo)
        }
    }

    func handleBeepNotificationResponse(userInfo: [AnyHashable: Any]) async {
        let metadata = beepNotificationDiagnostics(userInfo: userInfo)
        clearBeepNotifications()
        diagnostics.record(
            .pushToTalk,
            message: "Beep notification opened",
            metadata: metadata
        )
        await openBeepNotification(
            userInfo: userInfo,
            reason: "notification-open",
            shouldAccept: true
        )
    }

    func handleBeepNotificationAcceptResponse(userInfo: [AnyHashable: Any]) async {
        let metadata = beepNotificationDiagnostics(userInfo: userInfo)
        clearBeepNotifications()
        diagnostics.record(
            .pushToTalk,
            message: "Beep notification accepted",
            metadata: metadata
        )
        await openBeepNotification(
            userInfo: userInfo,
            reason: "notification-accept",
            shouldAccept: true
        )
    }

    func handleBeepNotificationNotNowResponse(userInfo: [AnyHashable: Any]) async {
        let metadata = beepNotificationDiagnostics(userInfo: userInfo)
        clearBeepNotifications()
        diagnostics.record(
            .pushToTalk,
            message: "Beep notification declined",
            metadata: metadata
        )
        await refreshContactSummaries()
        await refreshBeeps()

        guard let backend = backendServices else {
            diagnostics.record(
                .backend,
                level: .notice,
                message: "Cannot decline Beep notification before backend is ready",
                metadata: metadata
            )
            return
        }

        let beepID = (userInfo["beepId"] as? String)
            ?? beepNotificationHandle(from: userInfo)
                .flatMap { contactMatchingNormalizedHandle($0) }
                .flatMap { incomingBeepByContactID[$0.id]?.beepId }
        guard let beepID else {
            diagnostics.record(
                .pushToTalk,
                level: .notice,
                message: "Cannot decline Beep notification without beep",
                metadata: metadata
            )
            return
        }

        do {
            if let handle = beepNotificationHandle(from: userInfo),
               let contact = contactMatchingNormalizedHandle(handle) {
                markIncomingBeepHandledLocally(
                    contactID: contact.id,
                    beep: incomingBeepByContactID[contact.id],
                    relationship: beepThreadProjection(for: contact.id),
                    reason: "decline-notification"
                )
            }
            _ = try await backend.declineBeep(beepId: beepID)
            await refreshBeeps()
            await refreshContactSummaries()
            clearBeepNotifications()
            if let handle = beepNotificationHandle(from: userInfo),
               let contact = contactMatchingNormalizedHandle(handle) {
                markIncomingBeepSurfaceOpened(for: contact.id, beepID: beepID)
            }
            captureDiagnosticsState("beep-notification:not-now")
        } catch {
            diagnostics.record(
                .backend,
                level: .error,
                message: "Decline Beep notification failed",
                metadata: metadata.merging(
                    ["error": error.localizedDescription],
                    uniquingKeysWith: { _, new in new }
                )
            )
        }
    }

    func openBeepNotification(
        userInfo: [AnyHashable: Any],
        reason: String,
        shouldAccept: Bool
    ) async {
        guard let handle = beepNotificationHandle(from: userInfo) else { return }
        let immediateContact = openCachedBeepContactFromNotification(
            handle: handle,
            reason: "\(reason)-immediate"
        )
        let joinedFromCachedIncomingBeep = shouldAccept
            && backendServices != nil
            && immediateContact.map {
                acceptIncomingBeep(
                    $0,
                    reason: "\(reason)-cached-accept",
                    allowsJoin: true
                )
            } == true
        await refreshBeepStateAfterNotification(userInfo: userInfo, reason: reason)
        if let openedContact = contactMatchingNormalizedHandle(handle) ?? immediateContact {
            markIncomingBeepSurfaceOpened(
                for: openedContact.id,
                beepID: userInfo["beepId"] as? String,
                requestCount: beepThreadProjection(for: openedContact.id).requestCount
            )
        }
        if joinedFromCachedIncomingBeep {
            return
        }
        let shouldJoin = openBeepFromNotification(
            handle: handle,
            reason: reason,
            allowsJoin: shouldAccept && backendServices != nil,
            cachedContact: immediateContact
        )
        if backendServices == nil {
            pendingBeepNotificationHandle = handle
            pendingBeepNotificationShouldJoin = shouldAccept
            diagnostics.record(
                .pushToTalk,
                message: "Queued Beep notification open until backend is ready",
                metadata: ["handle": handle, "shouldAccept": String(shouldAccept)]
            )
            return
        }
        if shouldAccept && !shouldJoin {
            await openFriend(reference: handle)
        }
    }

    func refreshBeepStateAfterNotification(
        userInfo: [AnyHashable: Any],
        reason: String,
        allowsPendingForegroundSurface: Bool = true
    ) async {
        await refreshContactSummaries()
        await refreshBeeps()
        captureDiagnosticsState("beep-notification:\(reason):beep-state-refreshed")

        guard let handle = beepNotificationHandle(from: userInfo) else { return }
        guard let contact = contactMatchingNormalizedHandle(handle) else {
            recordBeepProjectionInvariant(
                handle: handle,
                reason: reason,
                message: "foreground Beep notification did not resolve to a local contact after Beep-state refresh"
            )
            scheduleBeepProjectionRecovery(userInfo: userInfo, reason: reason)
            return
        }

        guard beepThreadProjection(for: contact.id).hasIncomingBeep else {
            guard !beepNotificationAlreadyHandled(for: contact.id) else {
                clearPendingForegroundBeepSurface(contactID: contact.id)
                diagnostics.record(
                    .pushToTalk,
                    message: "Ignored stale foreground Beep notification after Beep was already handled",
                    metadata: [
                        "handle": handle,
                        "reason": reason,
                        "pendingAction": String(describing: conversationActionCoordinator.pendingAction),
                        "isJoined": String(isJoined && activeChannelId == contact.id),
                        "backendSelfJoined": String(selectedChannelSnapshot(for: contact.id)?.membership.hasLocalMembership ?? false),
                    ]
                )
                return
            }
            if allowsPendingForegroundSurface {
                maybeQueuePendingForegroundBeepSurface(
                    contact: contact,
                    userInfo: userInfo,
                    reason: reason
                )
            }
            recordBeepProjectionInvariant(
                handle: handle,
                reason: reason,
                message: "foreground Beep notification was not projected as an incoming Beep after Beep-state refresh"
            )
            scheduleBeepProjectionRecovery(userInfo: userInfo, reason: reason)
            return
        }

        // Keep the foreground notification edge queued so it can merge with backend snapshots.
        // It expires or clears when the user accepts, opens, or dismisses it.
    }

    func beepNotificationAlreadyHandled(for contactID: UUID) -> Bool {
        if conversationActionCoordinator.pendingAction.pendingConnectContactID == contactID {
            return true
        }
        if isJoined, activeChannelId == contactID {
            return true
        }
        if selectedChannelSnapshot(for: contactID)?.membership.hasLocalMembership == true {
            return true
        }
        return false
    }

    private func scheduleBeepProjectionRecovery(
        userInfo: [AnyHashable: Any],
        reason: String
    ) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard let self else { return }
            await self.refreshContactSummaries()
            await self.refreshBeeps()
            self.captureDiagnosticsState("beep-notification:\(reason):projection-recovery")
        }
    }

    private func recordBeepProjectionInvariant(
        handle: String,
        reason: String,
        message: String
    ) {
        diagnostics.recordInvariantViolation(
            invariantID: "beep.foreground_notification_not_projected",
            scope: .local,
            message: message,
            metadata: [
                "handle": handle,
                "reason": reason,
                "selectedContact": selectedContact?.handle ?? "none",
                "selectedConversationRelationship": selectedConversationDiagnosticsSummary.relationship,
            ]
        )
    }

    private func contactMatchingNormalizedHandle(_ handle: String) -> Contact? {
        let normalizedHandle = Contact.normalizedHandle(handle)
        return contacts.first { Contact.normalizedHandle($0.handle) == normalizedHandle }
    }

    func openPendingBeepNotificationIfNeeded() async {
        guard let handle = pendingBeepNotificationHandle else { return }
        pendingBeepNotificationHandle = nil
        let shouldJoin = pendingBeepNotificationShouldJoin
        pendingBeepNotificationShouldJoin = false
        await refreshBeepStateAfterNotification(
            userInfo: ["event": TurboNotificationCategory.beepEvent, "fromHandle": handle],
            reason: "pending-notification-open"
        )
        let didJoin = openBeepFromNotification(
            handle: handle,
            reason: "pending-notification-open",
            allowsJoin: shouldJoin
        )
        if !didJoin {
            await openFriend(reference: handle)
        }
    }

    func refreshDeviceRegistrationWithAlertPushTokenIfPossible() async {
        guard let backend = backendServices else { return }
        do {
            _ = try await backend.registerDevice(
                label: UIDevice.current.name,
                alertPushToken: alertPushTokenHex.isEmpty ? nil : alertPushTokenHex,
                alertPushEnvironment: alertPushTokenHex.isEmpty
                    ? nil
                    : TurboAPNSEnvironmentResolver.current(),
                directQuicIdentity: currentDirectQuicIdentityRegistrationMetadata(),
                mediaEncryptionIdentity: currentMediaEncryptionIdentityRegistrationMetadata()
            )
            diagnostics.record(
                .backend,
                message: "Refreshed device registration with alert push token",
                metadata: [
                    "tokenPrefix": String(alertPushTokenHex.prefix(8)),
                    "apnsEnvironment": TurboAPNSEnvironmentResolver.current().rawValue,
                ]
            )
        } catch {
            diagnostics.record(
                .backend,
                level: .error,
                message: "Device registration refresh with alert push token failed",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    func syncBeepNotificationBadge(applicationState: UIApplication.State? = nil) {
        if (applicationState ?? currentApplicationState()) == .active {
            clearBeepNotifications()
            return
        }

        setApplicationBadgeCount(pendingIncomingBeepBadgeCount)
    }

    func consumeDeliveredBeepNotificationsWithoutForegroundBanner(reason: String) async {
        let userInfos = await deliveredBeepNotificationUserInfoProvider()
        consumeDeliveredBeepNotificationUserInfosWithoutForegroundBanner(userInfos, reason: reason)
        clearBeepNotifications()
    }

    func consumeDeliveredBeepNotificationUserInfosWithoutForegroundBanner(
        _ userInfos: [[AnyHashable: Any]],
        reason: String
    ) {
        var consumedCount = 0
        for userInfo in userInfos {
            guard let handle = beepNotificationHandle(from: userInfo) else { continue }
            let normalizedHandle = Contact.normalizedHandle(handle)
            let receipt = BackgroundDeliveredBeepReceipt(
                handle: handle,
                normalizedHandle: normalizedHandle,
                beepID: userInfo["beepId"] as? String,
                requestCount: beepNotificationRequestCount(from: userInfo)
            )
            backgroundDeliveredBeepReceiptsByHandle[normalizedHandle] = receipt
            consumedCount += 1
        }

        guard consumedCount > 0 else { return }
        applyBackgroundDeliveredBeepReceiptsToKnownContacts(reason: reason)
        diagnostics.record(
            .pushToTalk,
            message: "Consumed delivered Beep notifications without foreground banner",
            metadata: [
                "reason": reason,
                "count": "\(consumedCount)",
            ]
        )
    }

    func applyBackgroundDeliveredBeepReceiptsToKnownContacts(reason: String) {
        guard !backgroundDeliveredBeepReceiptsByHandle.isEmpty else { return }

        for (normalizedHandle, receipt) in Array(backgroundDeliveredBeepReceiptsByHandle) {
            guard let contact = contacts.first(where: {
                Contact.normalizedHandle($0.handle) == normalizedHandle
            }) else {
                continue
            }
            let projectedIncomingBeep = incomingBeepByContactID[contact.id]
            let relationship = beepThreadProjection(for: contact.id)
            guard let requestCount = receipt.requestCount
                    ?? projectedIncomingBeep?.requestCount
                    ?? relationship.requestCount else {
                continue
            }

            markIncomingBeepSurfaceSeenWithoutBanner(
                for: contact.id,
                beepID: receipt.beepID,
                requestCount: requestCount
            )
            let hasProjectedIncomingBeep = projectedIncomingBeep != nil || relationship.hasIncomingBeep
            if hasProjectedIncomingBeep {
                backgroundDeliveredBeepReceiptsByHandle.removeValue(forKey: normalizedHandle)
            }
            diagnostics.record(
                .pushToTalk,
                message: hasProjectedIncomingBeep
                    ? "Marked background-delivered Beep seen without foreground banner"
                    : "Deferred background-delivered Beep banner suppression until projection",
                metadata: [
                    "contactId": contact.id.uuidString,
                    "handle": contact.handle,
                    "beepId": receipt.beepID ?? "none",
                    "requestCount": "\(requestCount)",
                    "reason": reason,
                ]
            )
        }
    }

    func markIncomingBeepSurfaceSeenWithoutBanner(
        for contactID: UUID,
        beepID: String?,
        requestCount: Int?
    ) {
        incomingBeepSurfaceState = IncomingBeepSurfaceReducer.reduce(
            state: incomingBeepSurfaceState,
            event: .beepSeenWithoutBanner(
                contactID: contactID,
                beepID: beepID,
                requestCount: requestCount
            )
        )
    }

    func clearBeepNotifications() {
        setApplicationBadgeCount(0)
        clearDeliveredNotifications()
    }

    private func beepNotificationHandle(from userInfo: [AnyHashable: Any]) -> String? {
        userInfo["fromHandle"] as? String
    }

    private func beepNotificationRequestCount(from userInfo: [AnyHashable: Any]) -> Int? {
        if let requestCount = userInfo["requestCount"] as? Int {
            return max(requestCount, 1)
        }
        if let requestCount = userInfo["requestCount"] as? NSNumber {
            return max(requestCount.intValue, 1)
        }
        if let requestCount = userInfo["requestCount"] as? String,
           let parsed = Int(requestCount) {
            return max(parsed, 1)
        }
        return nil
    }

    @discardableResult
    private func openBeepFromNotification(
        handle: String,
        reason: String,
        allowsJoin: Bool = true,
        cachedContact: Contact? = nil
    ) -> Bool {
        guard let contact = contactMatchingNormalizedHandle(handle) ?? cachedContact else {
            return false
        }

        diagnostics.record(
            .pushToTalk,
            message: allowsJoin
                ? "Accepting Beep from notification"
                : "Opening Beep from notification",
            metadata: ["handle": contact.handle, "reason": reason]
        )
        return acceptIncomingBeep(
            contact,
            reason: reason,
            allowsJoin: allowsJoin
        )
    }

    @discardableResult
    private func openCachedBeepContactFromNotification(
        handle: String,
        reason: String
    ) -> Contact? {
        guard let contact = contactMatchingNormalizedHandle(handle) else {
            return nil
        }
        openCachedBeepContact(contact, reason: reason)
        return contact
    }

    private func openCachedBeepContact(_ contact: Contact, reason: String) {
        diagnostics.record(
            .pushToTalk,
            message: "Selected contact from Beep notification",
            metadata: ["handle": contact.handle, "reason": reason]
        )
        selectContact(contact, reason: reason)
        let relationship = beepThreadProjection(for: contact.id)
        guard relationship.hasIncomingBeep else {
            diagnostics.record(
                .pushToTalk,
                message: "Ignored cached Beep notification expansion without incoming Beep",
                metadata: [
                    "contactId": contact.id.uuidString,
                    "handle": contact.handle,
                    "reason": reason,
                    "relationship": String(describing: relationship),
                ]
            )
            return
        }
        guard contact.isOnline else {
            return
        }
        requestExpandedCall(for: contact)
    }

    private func maybeQueuePendingForegroundBeepSurface(
        contact: Contact,
        userInfo: [AnyHashable: Any],
        reason: String
    ) {
        guard !beepNotificationAlreadyHandled(for: contact.id) else {
            clearPendingForegroundBeepSurface(contactID: contact.id)
            return
        }
        guard let beepID = userInfo["beepId"] as? String, !beepID.isEmpty else {
            return
        }
        let requestCount = beepNotificationRequestCount(from: userInfo)
            ?? incomingBeepByContactID[contact.id]?.requestCount
            ?? beepThreadProjection(for: contact.id).requestCount
            ?? 1
        queuePendingForegroundBeepSurface(
            for: contact,
            beepID: beepID,
            requestCount: requestCount,
            contactIsOnlineOverride: true,
            subject: userInfo["subject"] as? String,
            sentAt: (userInfo["sentAt"] as? String) ?? (userInfo["createdAt"] as? String),
            reason: reason
        )
    }

    func requestExpandedCall(for contact: Contact) {
        requestedExpandedCallContactID = contact.id
        requestedExpandedCallSequence += 1
    }

    private func beepNotificationDiagnostics(userInfo: [AnyHashable: Any]) -> [String: String] {
        [
            "event": (userInfo["event"] as? String) ?? "unknown",
            "fromHandle": beepNotificationHandle(from: userInfo) ?? "none",
            "beepId": (userInfo["beepId"] as? String) ?? "none",
            "requestCount": beepNotificationRequestCount(from: userInfo).map(String.init) ?? "none",
            "channelId": (userInfo["channelId"] as? String) ?? "none",
            "subject": (userInfo["subject"] as? String) ?? "none",
            "sentAt": ((userInfo["sentAt"] as? String) ?? (userInfo["createdAt"] as? String)) ?? "none",
            "deepLink": (userInfo["deepLink"] as? String) ?? "none",
        ]
    }

    private func prewarmForegroundBeepNotificationContactIfIdle(
        userInfo: [AnyHashable: Any],
        reason: String
    ) async {
        guard let handle = beepNotificationHandle(from: userInfo),
              let contact = contactMatchingNormalizedHandle(handle) else {
            return
        }
        let beepID = (userInfo["beepId"] as? String)
            ?? incomingBeepByContactID[contact.id]?.beepId
        guard beepThreadProjection(for: contact.id).hasIncomingBeep else { return }
        if let beepID,
           foregroundBeepNotificationPrewarmedBeepIDs.contains(beepID) {
            diagnostics.record(
                .media,
                message: "Foreground Beep notification prewarm skipped",
                metadata: [
                    "contactId": contact.id.uuidString,
                    "handle": contact.handle,
                    "beepId": beepID,
                    "reason": reason,
                    "blockReason": "duplicate-beep",
                ]
            )
            return
        }
        guard foregroundBeepNotificationPrewarmBlockReason(for: contact.id) == nil else {
            diagnostics.record(
                .media,
                message: "Foreground Beep notification prewarm skipped",
                metadata: [
                    "contactId": contact.id.uuidString,
                    "handle": contact.handle,
                    "beepId": beepID ?? "none",
                    "reason": reason,
                    "blockReason": foregroundBeepNotificationPrewarmBlockReason(for: contact.id) ?? "unknown",
                ]
            )
            return
        }

        diagnostics.record(
            .media,
            message: "Foreground Beep notification prewarm started",
            metadata: [
                "contactId": contact.id.uuidString,
                "handle": contact.handle,
                "beepId": beepID ?? "none",
                "reason": reason,
            ]
        )

        precreateSelectedContactMediaShellIfNeeded(
            for: contact.id,
            reason: reason
        )
        await publishSelectedFriendPrewarmHintIfPossible(
            for: contact.id,
            reason: reason
        )
        await prewarmForegroundBeepDirectQuicIfPossible(
            for: contact.id,
            reason: reason
        )

        diagnostics.record(
            .media,
            message: "Foreground Beep notification prewarm completed",
            metadata: [
                "contactId": contact.id.uuidString,
                "handle": contact.handle,
                "beepId": beepID ?? "none",
                "reason": reason,
            ]
        )
        if let beepID {
            foregroundBeepNotificationPrewarmedBeepIDs.insert(beepID)
        }
    }

    private func foregroundBeepNotificationPrewarmBlockReason(for contactID: UUID) -> String? {
        if isJoined || activeChannelId != nil {
            return "active-channel"
        }
        if mediaSessionContactID != nil || isPTTAudioSessionActive {
            return "active-media-session"
        }
        if isTransmitting || transmitCoordinator.state.isPressingTalk {
            return "active-transmit"
        }
        guard contacts.contains(where: { $0.id == contactID }) else {
            return "contact-missing"
        }
        return nil
    }

    private func prewarmForegroundBeepDirectQuicIfPossible(
        for contactID: UUID,
        reason: String
    ) async {
        let prewarmReason = "foreground-notification-direct-quic-prewarm-\(reason)"
        if let blockReason = directQuicSelectionPrewarmBlockReason(
            for: contactID,
            requireSelectedContact: false
        ) {
            if blockReason == "relay-only-forced" {
                return
            }
            diagnostics.record(
                .media,
                message: "Foreground Beep Direct QUIC prewarm skipped",
                metadata: [
                    "contactId": contactID.uuidString,
                    "reason": reason,
                    "blockReason": blockReason,
                ]
            )
            if blockReason == "not-listener-offerer" {
                await requestRemoteDirectQuicOfferIfPossible(
                    for: contactID,
                    reason: prewarmReason
                )
            }
            return
        }

        diagnostics.record(
            .media,
            message: "Foreground Beep Direct QUIC prewarm requested",
            metadata: [
                "contactId": contactID.uuidString,
                "reason": reason,
            ]
        )
        await maybeStartDirectQuicProbe(for: contactID)
    }
}
