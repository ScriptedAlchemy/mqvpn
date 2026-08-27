// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 mp0rta and mqvpn contributors

import Foundation
import ActivityKit
import os

private let liveActivityLog = Logger(subsystem: "mqvpn.poc", category: "live-activity")

/// App-process lifecycle entry points. ActivityKit requires a foreground app
/// to create a standard Live Activity, so Start requests it before launching
/// the packet tunnel. The provider process subsequently updates that same
/// activity from real counters while the app is backgrounded.
@available(iOS 16.2, *)
enum MqvpnLiveActivityLifecycle {
    @discardableResult
    static func begin(mode: OperatingMode, timestamp: Double = Date().timeIntervalSince1970) -> Bool {
        let state = LiveActivityContentState.lifecycle(.connecting, timestamp: timestamp)
        let content = ActivityContent(state: state, staleDate: Date(timeIntervalSince1970: timestamp + 10))
        let activities = Activity<MqvpnNetworkActivityAttributes>.activities
        let plan = selectionPlan(activities: activities, desiredMode: mode.rawValue)
        if let currentID = plan.currentID,
           let activity = activities.first(where: { $0.id == currentID }) {
            Task { await activity.update(content) }
            endActivities(activities, ids: plan.endIDs, state: state)
            liveActivityLog.notice("reusing exact-mode Live Activity mode=\(mode.rawValue, privacy: .public) extras=\(plan.endIDs.count)")
            return true
        }

        // A prior-mode or crash-duplicate activity is never allowed to pose as
        // the new session if the new request fails.
        endActivities(activities, ids: plan.endIDs, state: state)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            liveActivityLog.notice("Live Activities unavailable or disabled")
            return false
        }
        do {
            let activity = try Activity.request(
                attributes: MqvpnNetworkActivityAttributes(mode: mode.rawValue),
                content: content,
                pushType: nil)
            endExtras(keeping: activity.id, state: state)
            liveActivityLog.notice("requested Live Activity mode=\(mode.rawValue, privacy: .public)")
            return true
        } catch {
            liveActivityLog.error("Live Activity request failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static func markStopping(timestamp: Double = Date().timeIntervalSince1970) {
        let state = LiveActivityContentState.lifecycle(.stopping, timestamp: timestamp)
        let content = ActivityContent(state: state, staleDate: Date(timeIntervalSince1970: timestamp + 3))
        for activity in Activity<MqvpnNetworkActivityAttributes>.activities {
            Task { await activity.update(content) }
        }
    }

    static func endImmediately(timestamp: Double = Date().timeIntervalSince1970) async {
        let state = LiveActivityContentState.lifecycle(.stopping, timestamp: timestamp)
        let content = ActivityContent(state: state, staleDate: nil)
        for activity in Activity<MqvpnNetworkActivityAttributes>.activities {
            await activity.end(content, dismissalPolicy: .immediate)
        }
    }

    static func updateExisting(mode: OperatingMode,
                               state: LiveActivityContentState,
                               staleDate: Date) async -> Bool {
        let activities = Activity<MqvpnNetworkActivityAttributes>.activities
        let plan = selectionPlan(activities: activities, desiredMode: mode.rawValue)
        guard let currentID = plan.currentID,
              let current = activities.first(where: { $0.id == currentID }) else {
            liveActivityLog.notice("no exact-mode foreground-created Live Activity to update")
            return false
        }
        guard LiveActivityUpdateOrder.shouldApply(
            currentSampledAt: current.content.state.sampledAt,
            candidateSampledAt: state.sampledAt) else {
            liveActivityLog.debug("discarded stale Live Activity update mode=\(mode.rawValue, privacy: .public)")
            return false
        }
        let final = ActivityContent(state: state, staleDate: nil)
        for activity in activities where plan.endIDs.contains(activity.id) {
            await activity.end(final, dismissalPolicy: .immediate)
        }
        await current.update(ActivityContent(state: state, staleDate: staleDate))
        liveActivityLog.debug("Live Activity update completed mode=\(mode.rawValue, privacy: .public) phase=\(state.phase.rawValue, privacy: .public) extras=\(plan.endIDs.count)")
        return true
    }

    private static func selectionPlan(
        activities: [Activity<MqvpnNetworkActivityAttributes>],
        desiredMode: String
    ) -> LiveActivitySelectionPlan {
        LiveActivitySelection.plan(
            activities: activities.map {
                LiveActivityDescriptor(id: $0.id, mode: $0.attributes.mode)
            }, desiredMode: desiredMode)
    }

    private static func endExtras(keeping activityID: String,
                                  state: LiveActivityContentState) {
        let activities = Activity<MqvpnNetworkActivityAttributes>.activities
        let ids = activities.compactMap { $0.id == activityID ? nil : $0.id }
        endActivities(activities, ids: ids, state: state)
    }

    private static func endActivities(
        _ activities: [Activity<MqvpnNetworkActivityAttributes>],
        ids: [String],
        state: LiveActivityContentState
    ) {
        let ids = Set(ids)
        let content = ActivityContent(state: state, staleDate: nil)
        for activity in activities where ids.contains(activity.id) {
            Task { await activity.end(content, dismissalPolicy: .immediate) }
        }
    }
}

protocol MqvpnLiveActivityReporting: AnyObject {
    func start()
    func stop() async
}

/// Packet-provider rate reporter. It reads only the lock-protected production
/// snapshot, samples at a bounded cadence, and updates an activity that the
/// foreground app already created. It never fabricates an activity in the
/// background if ActivityKit has none to update.
@available(iOS 16.2, *)
final class MqvpnLiveActivityReporter: MqvpnLiveActivityReporting {
    private let queue = DispatchQueue(label: "mqvpn.live-activity")
    private let snapshotProvider: () -> TunnelSnapshot?
    private let mode: OperatingMode
    private var sampler = LiveActivityRateSampler()
    private var timer: DispatchSourceTimer?
    private var stopped = false

    init(mode: OperatingMode,
         snapshotProvider: @escaping () -> TunnelSnapshot?) {
        self.mode = mode
        self.snapshotProvider = snapshotProvider
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.stopped, self.timer == nil else { return }
            self.publish()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            // One-second cadence: the target carries frequent-updates
            // entitlement, and a speed readout that trails the line by
            // several seconds reads as wrong rather than smoothed.
            timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.publish() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() async {
        let shouldEnd: Bool = queue.sync {
            guard !stopped else { return false }
            stopped = true
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            return true
        }
        guard shouldEnd else { return }
        await MqvpnLiveActivityLifecycle.endImmediately()
        liveActivityLog.notice("provider Live Activity cleanup completed after transport stop")
    }

    private func publish() {
        guard !stopped, let snapshot = snapshotProvider() else { return }
        let activities = Activity<MqvpnNetworkActivityAttributes>.activities
        let plan = LiveActivitySelection.plan(
            activities: activities.map {
                LiveActivityDescriptor(id: $0.id, mode: $0.attributes.mode)
            }, desiredMode: mode.rawValue)
        guard LiveActivityReporterPublish.shouldUpdateExisting(currentID: plan.currentID)
        else { return }
        let published = LiveActivityContentFactory.make(snapshot: snapshot, sampler: &sampler)
        Task {
            _ = await MqvpnLiveActivityLifecycle.updateExisting(
                mode: mode, state: published.state, staleDate: published.staleDate)
        }
    }
}
