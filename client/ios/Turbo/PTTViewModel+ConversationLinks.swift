import Foundation
import Intents

extension PTTViewModel {
    func handleStartCallUserActivity(_ userActivity: NSUserActivity) async {
        guard let intent = TurboIncomingLink.conversationOpenIntent(fromStartCallUserActivity: userActivity) else {
            diagnostics.record(
                .pushToTalk,
                level: .notice,
                message: "Ignored start call user activity without conversation intent",
                metadata: ["activityType": userActivity.activityType]
            )
            return
        }
        diagnostics.record(
            .pushToTalk,
            message: "Start call user activity accepted",
            metadata: ["handle": intent.reference]
        )
        await handleConversationOpenIntent(intent)
    }

    func handleStartCallIntent(_ startCallIntent: INStartCallIntent) async {
        guard let intent = TurboIncomingLink.conversationOpenIntent(fromStartCallIntent: startCallIntent) else {
            diagnostics.record(
                .pushToTalk,
                level: .notice,
                message: "Ignored start call intent without conversation intent"
            )
            return
        }
        diagnostics.record(
            .pushToTalk,
            message: "Start call intent accepted",
            metadata: ["handle": intent.reference]
        )
        await handleConversationOpenIntent(intent)
    }

    func handleConversationOpenIntent(_ intent: ConversationOpenIntent) async {
        var userInfo: [AnyHashable: Any] = [
            "event": TurboNotificationCategory.beepEvent,
            "fromHandle": intent.reference,
        ]
        if let beepID = intent.beepID {
            userInfo["beepId"] = beepID
        }
        if let channelID = intent.channelID {
            userInfo["channelId"] = channelID
        }

        switch intent.action {
        case .open:
            if let contact = contactMatchingNormalizedHandleForLink(intent.reference) {
                openCachedConversationContact(contact, reason: "conversation-link-open")
            } else {
                await openFriend(reference: intent.reference)
            }

        case .accept:
            await handleBeepNotificationAcceptResponse(userInfo: userInfo)

        case .end:
            if let contact = contactMatchingNormalizedHandleForLink(intent.reference) {
                selectContact(contact)
                requestExpandedCall(for: contact)
                await requestDisconnectSelectedConversation()
            } else {
                await openFriend(reference: intent.reference)
            }
        }
    }

    private func contactMatchingNormalizedHandleForLink(_ handle: String) -> Contact? {
        let normalizedHandle = Contact.normalizedHandle(handle)
        return contacts.first { Contact.normalizedHandle($0.handle) == normalizedHandle }
    }

    private func openCachedConversationContact(_ contact: Contact, reason: String) {
        diagnostics.record(
            .app,
            message: "Selected contact from conversation link",
            metadata: ["handle": contact.handle, "reason": reason]
        )
        selectContact(contact)
        requestExpandedCall(for: contact)
    }
}
