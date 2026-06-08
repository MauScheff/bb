//
//  TurboApp.swift
//  Turbo
//
//  Created by Maurice on 20.03.2026.
//

import SwiftUI
import UIKit
import AVFAudio
import UserNotifications

private enum AppRuntimeEnvironment {
    static var isRunningAutomatedTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

private enum AppAudioSessionBootstrapper {
    @MainActor
    static func configureCategoryForPushToTalk() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: MediaSessionAudioPolicy.routeCapableOptions
            )
        } catch {
            print("Failed to configure launch audio session category:", error.localizedDescription)
        }
    }
}

enum TurboNotificationCategory {
    static let beep = "TURBO_BEEP"
    static let beepEvent = "beep"
    static let acceptBeepAction = "TURBO_ACCEPT_BEEP"
    static let notNowBeepAction = "TURBO_NOT_NOW_BEEP"

    struct DeliveredNotificationSnapshot {
        let identifier: String
        let categoryIdentifier: String
        let userInfo: [AnyHashable: Any]
    }

    static func register(on center: UNUserNotificationCenter = .current()) {
        let accept = UNNotificationAction(
            identifier: acceptBeepAction,
            title: "Connect",
            options: [.foreground]
        )
        let notNow = UNNotificationAction(
            identifier: notNowBeepAction,
            title: "Not Now",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: beep,
            actions: [accept, notNow],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    static func shouldCompleteBeepResponseAfterHandling(actionIdentifier: String) -> Bool {
        true
    }

    static func deliveredBeepNotificationIdentifiers(
        from deliveredNotifications: [DeliveredNotificationSnapshot]
    ) -> [String] {
        deliveredNotifications.compactMap { notification in
            guard isBeepNotification(
                categoryIdentifier: notification.categoryIdentifier,
                userInfo: notification.userInfo
            ) else {
                return nil
            }
            return notification.identifier
        }
    }

    static func clearDeliveredBeepNotifications(
        deliveredNotifications: [DeliveredNotificationSnapshot],
        additionalIdentifiers: [String] = [],
        removeDeliveredIdentifiers: ([String]) -> Void,
        setBadgeCount: (Int) -> Void
    ) {
        let identifiers = Array(
            Set(
                deliveredBeepNotificationIdentifiers(from: deliveredNotifications)
                + additionalIdentifiers
            )
        )
        if !identifiers.isEmpty {
            removeDeliveredIdentifiers(identifiers)
        }
        setBadgeCount(0)
    }

    static func clearDeliveredBeepNotifications(
        including additionalIdentifiers: [String] = [],
        on center: UNUserNotificationCenter = .current()
    ) {
        center.getDeliveredNotifications { notifications in
            let deliveredNotifications = notifications.map {
                DeliveredNotificationSnapshot(
                    identifier: $0.request.identifier,
                    categoryIdentifier: $0.request.content.categoryIdentifier,
                    userInfo: $0.request.content.userInfo
                )
            }
            clearDeliveredBeepNotifications(
                deliveredNotifications: deliveredNotifications,
                additionalIdentifiers: additionalIdentifiers,
                removeDeliveredIdentifiers: { center.removeDeliveredNotifications(withIdentifiers: $0) },
                setBadgeCount: { center.setBadgeCount($0) }
            )
        }
    }

    static func deliveredBeepNotificationUserInfos(
        on center: UNUserNotificationCenter = .current()
    ) async -> [[AnyHashable: Any]] {
        await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { notifications in
                let userInfos = notifications.compactMap { notification -> [AnyHashable: Any]? in
                    let userInfo = notification.request.content.userInfo
                    guard isBeepNotification(
                        categoryIdentifier: notification.request.content.categoryIdentifier,
                        userInfo: userInfo
                    ) else {
                        return nil
                    }
                    return userInfo
                }
                continuation.resume(returning: userInfos)
            }
        }
    }

    static func isBeepNotification(
        categoryIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> Bool {
        categoryIdentifier == beep || (userInfo["event"] as? String) == beepEvent
    }
}

final class TurboAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {
        AppAudioSessionBootstrapper.configureCategoryForPushToTalk()
        UNUserNotificationCenter.current().delegate = self
        TurboNotificationCategory.register()
        Task { @MainActor in
            await PTTViewModel.shared.initializeIfNeeded()
            await PTTViewModel.shared.consumeDeliveredBeepNotificationsWithoutForegroundBanner(reason: "application-launch")
            if !AppRuntimeEnvironment.isRunningAutomatedTests {
                await PTTViewModel.shared.configureAlertNotificationsIfNeeded()
            }
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            PTTViewModel.shared.handleReceivedAlertPushToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            PTTViewModel.shared.handleFailedToRegisterForRemoteNotifications(error)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        if TurboNotificationCategory.isBeepNotification(
            categoryIdentifier: notification.request.content.categoryIdentifier,
            userInfo: userInfo
        ) {
            TurboNotificationCategory.clearDeliveredBeepNotifications(
                including: [notification.request.identifier],
                on: center
            )
            completionHandler([])
            Task { @MainActor in
                await PTTViewModel.shared.handleForegroundBeepNotification(userInfo: userInfo)
            }
            return
        }
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if TurboNotificationCategory.isBeepNotification(
            categoryIdentifier: response.notification.request.content.categoryIdentifier,
            userInfo: userInfo
        ) {
            TurboNotificationCategory.clearDeliveredBeepNotifications(
                including: [response.notification.request.identifier],
                on: center
            )
            let completesAfterHandling =
                TurboNotificationCategory.shouldCompleteBeepResponseAfterHandling(
                    actionIdentifier: response.actionIdentifier
                )
            Task { @MainActor in
                await PTTViewModel.shared.handleBeepNotificationResponse(
                    actionIdentifier: response.actionIdentifier,
                    userInfo: userInfo
                )
                if completesAfterHandling {
                    completionHandler()
                }
            }
            return
        }
        completionHandler()
    }
}

@main
struct TurboApp: App {
    @UIApplicationDelegateAdaptor(TurboAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: .shared)
        }
    }
}
