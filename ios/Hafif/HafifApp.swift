import SwiftUI
import UIKit
import WebKit
import HealthKit
import UserNotifications

@main
struct HafifApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            AppWebView()
                .ignoresSafeArea()
                .background(Color(UIColor.systemBackground))
        }
    }
}

/// Uygulama öndeyken de bildirim göstersin.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

/// Paketteki index.html'i tam ekran açar; sayfadan gelen `hafif` mesajlarını yanıtlar.
struct AppWebView: UIViewRepresentable {
    func makeCoordinator() -> Bridge { Bridge() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "hafif")

        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .systemBackground
        web.scrollView.backgroundColor = .systemBackground
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.allowsLinkPreview = false
        context.coordinator.web = web

        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak web] _ in
            web?.evaluateJavaScript("window.HF_onActive && window.HF_onActive()")
        }
        return web
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}

final class Bridge: NSObject, WKScriptMessageHandler {
    weak var web: WKWebView?
    private let health = HKHealthStore()

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "notify":
            schedule(body["items"] as? [[String: Any]] ?? [])
        case "notifyPermission":
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                self.send(["cmd": "notifyPermission", "granted": granted])
            }
        case "health":
            syncHealth(days: body["days"] as? Int ?? 120, manual: body["manual"] as? Bool ?? false)
        case "share":
            share(name: body["name"] as? String ?? "hafif.json", text: body["text"] as? String ?? "")
        default:
            break
        }
    }

    /// Sayfaya `window.HF_native(...)` ile sonuç gönderir.
    private func send(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        DispatchQueue.main.async {
            self.web?.evaluateJavaScript("window.HF_native && window.HF_native(\(json))")
        }
    }

    // MARK: Hatırlatmalar

    /// Her hatırlatmayı her gün aynı saatte tekrarlayan yerel bildirim olarak kurar.
    private func schedule(_ items: [[String: Any]]) {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        for item in items.prefix(60) {
            guard let id = item["id"] as? String, let h = item["h"] as? Int, let m = item["m"] as? Int else { continue }
            let content = UNMutableNotificationContent()
            content.title = item["title"] as? String ?? "Hafif"
            content.body = item["body"] as? String ?? ""
            content.sound = .default
            var when = DateComponents()
            when.hour = h
            when.minute = m
            if let wd = item["wd"] as? Int { when.weekday = wd + 1 } // JS: 0 = Pazar, iOS: 1 = Pazar
            let trigger = UNCalendarNotificationTrigger(dateMatching: when, repeats: true)
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
    }

    // MARK: Apple Sağlık (akıllı tartı)

    private func syncHealth(days: Int, manual: Bool) {
        guard HKHealthStore.isHealthDataAvailable(),
              let mass = HKQuantityType.quantityType(forIdentifier: .bodyMass),
              let fat = HKQuantityType.quantityType(forIdentifier: .bodyFatPercentage),
              let steps = HKQuantityType.quantityType(forIdentifier: .stepCount) else {
            send(["cmd": "health", "error": "Bu cihazda Apple Sağlık yok"])
            return
        }
        health.requestAuthorization(toShare: nil, read: [mass, fat, steps]) { ok, error in
            guard ok else {
                self.send(["cmd": "health", "error": error?.localizedDescription ?? "İzin verilmedi"])
                return
            }
            let start = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
            let group = DispatchGroup()
            var weights: [String: Double] = [:]
            var fats: [String: Double] = [:]
            var stepMap: [String: Double] = [:]

            group.enter()
            self.firstPerDay(mass, unit: .gramUnit(with: .kilo), since: start) { weights = $0; group.leave() }
            group.enter()
            self.firstPerDay(fat, unit: .percent(), since: start) { fats = $0.mapValues { $0 * 100 }; group.leave() }
            group.enter()
            self.dailySum(steps, unit: .count(), since: Calendar.current.date(byAdding: .day, value: -min(days, 60), to: Date())!) { stepMap = $0; group.leave() }

            group.notify(queue: .main) {
                let list: [[String: Any]] = weights.keys.sorted().map { day in
                    var row: [String: Any] = ["date": day, "kg": weights[day]!]
                    if let f = fats[day] { row["fat"] = f }
                    return row
                }
                self.send(["cmd": "health", "weights": list, "steps": stepMap, "manual": manual])
            }
        }
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Her günün ilk (sabah) ölçümü.
    private func firstPerDay(_ type: HKQuantityType, unit: HKUnit, since: Date, done: @escaping ([String: Double]) -> Void) {
        let predicate = HKQuery.predicateForSamples(withStart: since, end: Date())
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, _ in
            var out: [String: Double] = [:]
            for case let s as HKQuantitySample in samples ?? [] {
                let key = Bridge.dayFormat.string(from: s.startDate)
                if out[key] == nil { out[key] = s.quantity.doubleValue(for: unit) }
            }
            done(out)
        }
        health.execute(query)
    }

    private func dailySum(_ type: HKQuantityType, unit: HKUnit, since: Date, done: @escaping ([String: Double]) -> Void) {
        let anchor = Calendar.current.startOfDay(for: since)
        let query = HKStatisticsCollectionQuery(quantityType: type,
                                                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: anchor, end: Date()),
                                                options: .cumulativeSum, anchorDate: anchor,
                                                intervalComponents: DateComponents(day: 1))
        query.initialResultsHandler = { _, results, _ in
            var out: [String: Double] = [:]
            results?.enumerateStatistics(from: anchor, to: Date()) { stat, _ in
                if let sum = stat.sumQuantity() { out[Bridge.dayFormat.string(from: stat.startDate)] = sum.doubleValue(for: unit) }
            }
            done(out)
        }
        health.execute(query)
    }

    // MARK: Yedek paylaşımı

    private func share(name: String, text: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        DispatchQueue.main.async {
            guard let root = self.web?.window?.rootViewController else { return }
            let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceView = self.web
            root.present(sheet, animated: true)
        }
    }
}
