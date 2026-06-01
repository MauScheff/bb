import Intents
import UserNotifications

private enum BeepNotificationPayload {
    static let eventName = "beep"
    static let categoryIdentifier = "TURBO_BEEP"
}

final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var didDeliverContent = false

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        guard let bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        self.bestAttemptContent = bestAttemptContent

        if (bestAttemptContent.userInfo["event"] as? String) == BeepNotificationPayload.eventName {
            let handle = (bestAttemptContent.userInfo["fromHandle"] as? String) ?? "Someone"
            bestAttemptContent.title = "\(handle) wants to talk"
            bestAttemptContent.body = "Tap to accept."
            bestAttemptContent.categoryIdentifier = BeepNotificationPayload.categoryIdentifier
            bestAttemptContent.interruptionLevel = .timeSensitive
            updateCommunicationNotificationContent(
                bestAttemptContent,
                request: request,
                handle: handle
            )
            return
        }

        deliver(bestAttemptContent)
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let bestAttemptContent {
            deliver(bestAttemptContent, contentHandler: contentHandler)
        }
    }

    private func updateCommunicationNotificationContent(
        _ content: UNMutableNotificationContent,
        request: UNNotificationRequest,
        handle: String
    ) {
        let intent = callIntent(
            handle: handle,
            userInfo: content.userInfo,
            requestIdentifier: request.identifier
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate { [weak self] _ in
            guard let self else { return }
            do {
                let updatedContent = try content.updating(from: intent)
                self.deliver(updatedContent)
            } catch {
                self.deliver(content)
            }
        }
    }

    private func callIntent(
        handle: String,
        userInfo: [AnyHashable: Any],
        requestIdentifier: String
    ) -> INStartCallIntent {
        let personHandle = INPersonHandle(value: handle, type: .unknown)
        let sender = INPerson(
            personHandle: personHandle,
            nameComponents: nil,
            displayName: handle,
            image: nil,
            contactIdentifier: nil,
            customIdentifier: userInfo["fromDeviceId"] as? String
        )
        let callRecord = INCallRecord(
            identifier: callIdentifier(userInfo: userInfo, requestIdentifier: requestIdentifier),
            dateCreated: Date(),
            caller: sender,
            callRecordType: .ringing,
            callCapability: .audioCall,
            callDuration: nil,
            unseen: true
        )
        return INStartCallIntent(
            callRecordFilter: nil,
            callRecordToCallBack: callRecord,
            audioRoute: .unknown,
            destinationType: .normal,
            contacts: [sender],
            callCapability: .audioCall
        )
    }

    private func callIdentifier(userInfo: [AnyHashable: Any], requestIdentifier: String) -> String {
        if let channelID = userInfo["channelId"] as? String, !channelID.isEmpty {
            return channelID
        }
        if let beepID = userInfo["beepId"] as? String, !beepID.isEmpty {
            return beepID
        }
        return requestIdentifier
    }

    private func deliver(_ content: UNNotificationContent) {
        guard let contentHandler else { return }
        deliver(content, contentHandler: contentHandler)
    }

    private func deliver(
        _ content: UNNotificationContent,
        contentHandler: (UNNotificationContent) -> Void
    ) {
        guard !didDeliverContent else { return }
        didDeliverContent = true
        contentHandler(content)
    }
}
