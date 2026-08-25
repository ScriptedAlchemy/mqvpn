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

        if let activity = Activity<MqvpnNetworkActivityAttributes>.activities.first(where: {
            $0.attributes.mode == mode.rawValue
        }) {
            Task { await activity.update(content) }
            endExtras(keeping: activity.id, state: state)
            return true
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            liveActivityLog.notice("Live Activities unavailable or disabled")
            return false
        }
        do {
            _ = try Activity.request(
                attributes: MqvpnNetworkActivityAttributes(mode: mode.rawValue),
                content: content,
                pushType: nil)
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

    private static func endExtras(keeping activityID: String,
                                  state: LiveActivityContentState) {
        let content = ActivityContent(state: state, staleDate: nil)
        for activity in Activity<MqvpnNetworkActivityAttributes>.activities
            where activity.id != activityID {
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
    private var sampler = LiveActivityRateSampler()
    private var timer: DispatchSourceTimer?
    private var stopped = false

    init(snapshotProvider: @escaping () -> TunnelSnapshot?) {
        self.snapshotProvider = snapshotProvider
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.stopped, self.timer == nil else { return }
            self.publish()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            // Two seconds is responsive enough for a glanceable speed display
            // without mirroring every provider packet into ActivityKit.
            timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(250))
            timer.setEventHandler { [weak self] in self?.publish() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() async {
        queue.sync {
            guard !stopped else { return }
            stopped = true
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
        }
        await MqvpnLiveActivityLifecycle.endImmediately()
    }

    private func publish() {
        guard !stopped, let snapshot = snapshotProvider() else { return }
        let counters = LiveActivityCounterSource.counters(from: snapshot)
        let rates = sampler.sample(timestamp: snapshot.timestamp, counters: counters)
        let state = LiveActivityContentFactory.make(snapshot: snapshot, rates: rates)
        let staleDate = Date(timeIntervalSince1970: snapshot.timestamp + 6)
        let content = ActivityContent(state: state, staleDate: staleDate)
        Task {
            guard let activity = Activity<MqvpnNetworkActivityAttributes>.activities.first else {
                liveActivityLog.notice("no foreground-created Live Activity to update")
                return
            }
            await activity.update(content)
        }
    }
}
