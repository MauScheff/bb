import Foundation
import UIKit

extension PTTViewModel {
    var activeIncomingBeep: IncomingBeepSurface? {
        incomingBeepSurfaceState.activeIncomingBeep
    }

    var pendingForegroundBeepSurface: IncomingBeepSurface? {
        incomingBeepSurfaceState.pendingForegroundBeep
    }

    var pendingForegroundBeepAcceptSurface: IncomingBeepSurface? {
        incomingBeepSurfaceState.pendingAcceptBeep
    }

    func reconcileIncomingBeepSurface(
        applicationState: UIApplication.State? = nil,
        presentationPolicy: IncomingBeepSurfacePresentationPolicy = .surfaceEligible,
        allowsSelectedContact: Bool = false,
        allowsAlreadySurfacedBeep: Bool = false
    ) {
        let resolvedApplicationState = applicationState ?? currentApplicationState()
        expirePendingForegroundBeepSurfaceIfNeeded()
        let candidates: [IncomingBeepCandidate] = contacts.compactMap { contact in
            guard contact.handle != currentDevUserHandle else { return nil }
            guard !beepNotificationAlreadyHandled(for: contact.id) else { return nil }
            if let beep = incomingBeepByContactID[contact.id] {
                return IncomingBeepCandidate(contact: contact, beep: beep)
            }
            let relationship = beepThreadProjection(for: contact.id)
            guard relationship.hasIncomingBeep else { return nil }
            return IncomingBeepCandidate(
                contact: contact,
                requestCount: relationship.requestCount ?? 1,
                source: "relationship"
            )
        } + contacts.compactMap { contact in
            guard let pendingSurface = pendingForegroundBeepSurface,
                  pendingSurface.contactID == contact.id,
                  pendingSurface.contactHandle == contact.handle,
                  contact.handle != currentDevUserHandle else {
                return nil
            }
            guard incomingBeepByContactID[contact.id] == nil else {
                clearPendingForegroundBeepSurface(contactID: contact.id)
                return nil
            }
            let relationship = beepThreadProjection(for: contact.id)
            guard !relationship.hasIncomingBeep else {
                clearPendingForegroundBeepSurface(contactID: contact.id)
                return nil
            }
            guard !beepNotificationAlreadyHandled(for: contact.id) else {
                clearPendingForegroundBeepSurface(contactID: contact.id)
                return nil
            }
            return IncomingBeepCandidate(surface: pendingSurface)
        }

        incomingBeepSurfaceState = IncomingBeepSurfaceReducer.reduce(
            state: incomingBeepSurfaceState,
            event: .beepsUpdated(
                candidates: candidates,
                selectedContactID: selectedContactId,
                applicationIsActive: resolvedApplicationState == .active,
                presentationPolicy: presentationPolicy,
                allowsSelectedContact: allowsSelectedContact,
                allowsAlreadySurfacedBeep: allowsAlreadySurfacedBeep
            )
        )
        completePendingForegroundBeepAcceptIfReady(reason: "surface-reconcile")
    }

    func dismissIncomingBeepSurface() {
        if let activeIncomingBeep {
            clearPendingForegroundBeepSurface(contactID: activeIncomingBeep.contactID)
        }
        incomingBeepSurfaceState = IncomingBeepSurfaceReducer.reduce(
            state: incomingBeepSurfaceState,
            event: .incomingBeepDismissed
        )
    }

    func markIncomingBeepSurfaceOpened(
        for contactID: UUID,
        beepID: String?,
        requestCount: Int? = nil
    ) {
        clearPendingForegroundBeepSurface(contactID: contactID, beepID: beepID)
        let resolvedRequestCount = requestCount ?? beepThreadProjection(for: contactID).requestCount
        incomingBeepSurfaceState = IncomingBeepSurfaceReducer.reduce(
            state: incomingBeepSurfaceState,
            event: .contactOpened(
                contactID: contactID,
                beepID: beepID,
                requestCount: resolvedRequestCount
            )
        )
    }

    func acceptActiveIncomingBeep() {
        guard let activeIncomingBeep else {
            dismissIncomingBeepSurface()
            return
        }
        acceptIncomingBeepSurface(activeIncomingBeep)
    }

    func acceptIncomingBeepSurface(_ surface: IncomingBeepSurface) {
        if incomingBeepSurfaceState.isAccepting(surface) {
            diagnostics.record(
                .pushToTalk,
                message: "Ignored repeated foreground incoming Beep banner accept",
                metadata: [
                    "contactId": surface.contactID.uuidString,
                    "beepId": surface.beepID,
                    "acceptIntentState": "in-flight",
                ]
            )
            return
        }
        guard !beepNotificationAlreadyHandled(for: surface.contactID) else {
            markIncomingBeepSurfaceOpened(
                for: surface.contactID,
                beepID: surface.beepID
            )
            diagnostics.record(
                .pushToTalk,
                message: "Ignored repeated foreground incoming Beep banner accept",
                metadata: [
                    "contactId": surface.contactID.uuidString,
                    "beepId": surface.beepID,
                    "acceptIntentState": "already-handled",
                ]
            )
            return
        }
        guard let contact = contacts.first(where: { $0.id == surface.contactID }) else {
            diagnostics.record(
                .pushToTalk,
                level: .notice,
                message: "Ignored foreground incoming Beep banner accept without local contact",
                metadata: [
                    "contactId": surface.contactID.uuidString,
                    "handle": surface.contactHandle,
                    "beepId": surface.beepID,
                ]
            )
            return
        }
        incomingBeepSurfaceState = IncomingBeepSurfaceReducer.reduce(
            state: incomingBeepSurfaceState,
            event: .incomingBeepAcceptStarted(surface)
        )
        markIncomingBeepSurfaceOpened(
            for: surface.contactID,
            beepID: surface.beepID
        )
        diagnostics.record(
            .pushToTalk,
            message: "Foreground incoming Beep banner accept tapped",
            metadata: [
                "contactId": contact.id.uuidString,
                "handle": contact.handle,
                "beepId": surface.beepID,
                "requestCount": "\(surface.requestCount)",
                "acceptIntentState": "pending",
            ]
        )
        guard !completePendingForegroundBeepAcceptIfReady(
            reason: "foreground-banner-accept"
        ) else {
            return
        }
        diagnostics.record(
            .pushToTalk,
            message: "Queued foreground incoming Beep banner accept until incoming Beep projects",
            metadata: [
                "contactId": contact.id.uuidString,
                "handle": contact.handle,
                "beepId": surface.beepID,
                "relationship": String(describing: beepThreadProjection(for: contact.id)),
            ]
        )
        Task { @MainActor [weak self] in
            await self?.resolvePendingForegroundBeepAccept(surface)
        }
    }

    @discardableResult
    func completePendingForegroundBeepAcceptIfReady(reason: String) -> Bool {
        guard let surface = pendingForegroundBeepAcceptSurface else { return false }
        if beepNotificationAlreadyHandled(for: surface.contactID) {
            finishPendingForegroundBeepAccept(surface)
            markIncomingBeepSurfaceOpened(for: surface.contactID, beepID: surface.beepID)
            diagnostics.record(
                .pushToTalk,
                message: "Completed pending foreground incoming Beep banner accept from existing join intent",
                metadata: [
                    "contactId": surface.contactID.uuidString,
                    "beepId": surface.beepID,
                    "reason": reason,
                ]
            )
            return true
        }
        guard let contact = contacts.first(where: { $0.id == surface.contactID }) else {
            finishPendingForegroundBeepAccept(surface)
            diagnostics.record(
                .pushToTalk,
                level: .notice,
                message: "Dropped pending foreground incoming Beep banner accept without local contact",
                metadata: [
                    "contactId": surface.contactID.uuidString,
                    "handle": surface.contactHandle,
                    "beepId": surface.beepID,
                    "reason": reason,
                ]
            )
            return true
        }
        guard beepThreadProjection(for: contact.id).hasIncomingBeep else {
            return false
        }
        diagnostics.record(
            .pushToTalk,
            message: "Completing pending foreground incoming Beep banner accept",
            metadata: [
                "contactId": contact.id.uuidString,
                "handle": contact.handle,
                "beepId": surface.beepID,
                "requestCount": "\(surface.requestCount)",
                "reason": reason,
            ]
        )
        let didAccept = acceptIncomingBeep(
            contact,
            reason: reason
        )
        guard didAccept else { return false }
        finishPendingForegroundBeepAccept(surface)
        markIncomingBeepSurfaceOpened(for: surface.contactID, beepID: surface.beepID)
        diagnostics.record(
            .pushToTalk,
            message: "Foreground incoming Beep banner accepted",
            metadata: [
                "contactId": contact.id.uuidString,
                "handle": contact.handle,
                "beepId": surface.beepID,
                "requestCount": "\(surface.requestCount)",
                "acceptIntentState": "completed",
            ]
        )
        return true
    }

    private func finishPendingForegroundBeepAccept(_ surface: IncomingBeepSurface) {
        incomingBeepSurfaceState = IncomingBeepSurfaceReducer.reduce(
            state: incomingBeepSurfaceState,
            event: .incomingBeepAcceptFinished(surface)
        )
    }

    private func resolvePendingForegroundBeepAccept(
        _ surface: IncomingBeepSurface
    ) async {
        let userInfo = foregroundBeepUserInfo(from: surface)
        await refreshBeepStateAfterNotification(
            userInfo: userInfo,
            reason: "foreground-banner-accept"
        )
        guard !completePendingForegroundBeepAcceptIfReady(
            reason: "foreground-banner-accept-refreshed"
        ) else {
            return
        }
        try? await Task.sleep(nanoseconds: 750_000_000)
        await refreshBeepStateAfterNotification(
            userInfo: userInfo,
            reason: "foreground-banner-accept-retry"
        )
        guard !completePendingForegroundBeepAcceptIfReady(
            reason: "foreground-banner-accept-retry"
        ) else {
            return
        }
        if pendingForegroundBeepAcceptSurface?.surfaceKey == surface.surfaceKey {
            finishPendingForegroundBeepAccept(surface)
        }
        diagnostics.record(
            .pushToTalk,
            level: .notice,
            message: "Pending foreground incoming Beep banner accept is still waiting for incoming Beep projection",
            metadata: [
                "contactId": surface.contactID.uuidString,
                "handle": surface.contactHandle,
                "beepId": surface.beepID,
                "relationship": contacts.first(where: { $0.id == surface.contactID })
                    .map { String(describing: beepThreadProjection(for: $0.id)) } ?? "missing-contact",
            ]
        )
    }

    private func foregroundBeepUserInfo(
        from surface: IncomingBeepSurface
    ) -> [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = [
            "event": TurboNotificationCategory.beepEvent,
            "fromHandle": surface.contactHandle,
            "beepId": surface.beepID,
        ]
        if let channelID = surface.channelID {
            userInfo["channelId"] = channelID
        }
        if let subject = surface.subject {
            userInfo["subject"] = subject
        }
        if let sentAt = surface.sentAt {
            userInfo["sentAt"] = sentAt
        }
        return userInfo
    }

    func openActiveIncomingBeep() {
        acceptActiveIncomingBeep()
    }

    func queuePendingForegroundBeepSurface(
        for contact: Contact,
        beepID: String,
        requestCount: Int,
        subject: String? = nil,
        sentAt: String? = nil,
        reason: String
    ) {
        let normalizedRequestCount = max(requestCount, 1)
        let surface = IncomingBeepSurface(
            contactID: contact.id,
            beepID: beepID,
            contactName: contact.name,
            contactHandle: contact.handle,
            contactIsOnline: contact.isOnline,
            requestCount: normalizedRequestCount,
            recencyKey: "notification:\(normalizedRequestCount):\(beepID)",
            channelID: contact.backendChannelId,
            subject: subject,
            sentAt: sentAt
        )
        incomingBeepSurfaceState = IncomingBeepSurfaceReducer.reduce(
            state: incomingBeepSurfaceState,
            event: .pendingForegroundBeepQueued(
                surface: surface,
                receivedAt: Date()
            )
        )
        diagnostics.record(
            .pushToTalk,
            message: "Queued pending foreground incoming Beep surface from notification",
            metadata: [
                "contactId": contact.id.uuidString,
                "handle": contact.handle,
                "beepId": beepID,
                "reason": reason,
                "requestCount": "\(normalizedRequestCount)",
            ]
        )
    }

    func clearPendingForegroundBeepSurface(contactID: UUID? = nil, beepID: String? = nil) {
        incomingBeepSurfaceState = IncomingBeepSurfaceReducer.reduce(
            state: incomingBeepSurfaceState,
            event: .pendingForegroundBeepCleared(contactID: contactID, beepID: beepID)
        )
    }

    func expirePendingForegroundBeepSurfaceIfNeeded(now: Date = Date()) {
        guard let receivedAt = incomingBeepSurfaceState.pendingForegroundBeepReceivedAt,
              let pendingSurface = pendingForegroundBeepSurface else {
            return
        }
        guard now.timeIntervalSince(receivedAt) >= pendingForegroundBeepSurfaceLifetime else {
            return
        }
        diagnostics.record(
            .pushToTalk,
            message: "Expired pending foreground incoming Beep surface",
            metadata: [
                "contactId": pendingSurface.contactID.uuidString,
                "handle": pendingSurface.contactHandle,
                "beepId": pendingSurface.beepID,
            ]
        )
        incomingBeepSurfaceState = IncomingBeepSurfaceReducer.reduce(
            state: incomingBeepSurfaceState,
            event: .pendingForegroundBeepExpired(
                now: now,
                lifetime: pendingForegroundBeepSurfaceLifetime
            )
        )
    }

    @discardableResult
    func acceptIncomingBeep(
        _ contact: Contact,
        reason: String,
        allowsJoin: Bool = true
    ) -> Bool {
        selectContact(contact, reason: reason)
        let relationship = beepThreadProjection(for: contact.id)
        guard relationship.hasIncomingBeep else {
            diagnostics.record(
                .pushToTalk,
                message: "Ignored Beep accept without incoming Beep",
                metadata: [
                    "contactId": contact.id.uuidString,
                    "handle": contact.handle,
                    "reason": reason,
                    "relationship": String(describing: relationship),
                ]
            )
            return false
        }
        guard contact.isOnline else {
            return false
        }
        if requestedExpandedCallContactID != contact.id {
            requestExpandedCall(for: contact)
        }
        guard allowsJoin else {
            return false
        }
        performConnect(to: contact, intent: .requestConnection)
        return true
    }
}
