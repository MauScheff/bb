//
//  PTTViewModel+ProximityAudioRoute.swift
//  Turbo
//
//  Created by Codex on 09.05.2026.
//

import UIKit

extension PTTViewModel {
    func shouldPreserveLiveCallForProximityInactiveTransition(
        applicationState: UIApplication.State
    ) -> Bool {
        guard applicationState == .inactive else { return false }
        guard automaticAudioRouteSwitchingEnabled else { return false }
        guard proximityMonitoringIsActive else { return false }
        guard isPhoneNearEar || UIDevice.current.proximityState else { return false }
        guard isJoined, activeChannelId != nil else { return false }
        return true
    }

    func registerProximityObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleProximityStateDidChangeNotification(_:)),
            name: UIDevice.proximityStateDidChangeNotification,
            object: nil
        )
    }

    @objc func handleProximityStateDidChangeNotification(_ notification: Notification) {
        let _ = notification
        let isNearEar = UIDevice.current.proximityState
        guard isPhoneNearEar != isNearEar else { return }
        isPhoneNearEar = isNearEar
        diagnostics.record(
            .media,
            message: "Proximity state changed",
            metadata: [
                "isNearEar": String(isNearEar),
                "monitoring": String(proximityMonitoringIsActive),
            ].merging(audioSessionDiagnostics()) { _, new in new }
        )
        applyAutomaticAudioRouteForProximity(reason: "proximity-change")
    }

    func updateAutomaticAudioRouteMonitoring(reason: String) {
        let applicationState = currentApplicationState()
        let shouldMonitor =
            automaticAudioRouteSwitchingEnabled
            && (
                applicationState == .active
                    || shouldPreserveLiveCallForProximityInactiveTransition(
                        applicationState: applicationState
                    )
            )
            && isJoined
            && activeChannelId != nil

        guard shouldMonitor else {
            stopAutomaticAudioRouteMonitoring(reason: reason)
            return
        }

        if !proximityMonitoringIsActive {
            UIDevice.current.isProximityMonitoringEnabled = true
            proximityMonitoringIsActive = UIDevice.current.isProximityMonitoringEnabled
            isPhoneNearEar = UIDevice.current.proximityState
            diagnostics.record(
                .media,
                message: proximityMonitoringIsActive
                    ? "Started automatic proximity audio route switching"
                    : "Automatic proximity audio route switching unavailable",
                metadata: [
                    "reason": reason,
                    "isNearEar": String(isPhoneNearEar),
                ]
            )
        }

        applyAutomaticAudioRouteForProximity(reason: reason)
    }

    func stopAutomaticAudioRouteMonitoring(reason: String) {
        if proximityMonitoringIsActive {
            UIDevice.current.isProximityMonitoringEnabled = false
            proximityMonitoringIsActive = false
            isPhoneNearEar = false
            diagnostics.record(
                .media,
                message: "Stopped automatic proximity audio route switching",
                metadata: ["reason": reason]
            )
        }
        restoreAutomaticAudioRoutePreferenceIfNeeded(reason: reason)
    }

    func applyAutomaticAudioRouteForProximity(reason: String) {
        guard proximityMonitoringIsActive else { return }

        if isPhoneNearEar {
            if automaticAudioRouteBasePreference == nil {
                automaticAudioRouteBasePreference = audioOutputPreference
            }
            setAudioOutputPreference(
                .phone,
                persist: false,
                reason: "proximity-near-ear:\(reason)"
            )
        } else {
            restoreAutomaticAudioRoutePreferenceIfNeeded(reason: reason)
        }
    }

    func restoreAutomaticAudioRoutePreferenceIfNeeded(reason: String) {
        guard let basePreference = automaticAudioRouteBasePreference else { return }
        automaticAudioRouteBasePreference = nil
        setAudioOutputPreference(
            basePreference,
            persist: false,
            reason: "proximity-away:\(reason)"
        )
    }
}
