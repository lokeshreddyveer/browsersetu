import Foundation
import SwiftUI

/// Everything here is typed or saved by you and stays on this device. Browser Setu does not look up prices or coupons on its own.
struct ComparedProduct: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var host: String
    var url: String
    var price: Double?
    var note = ""
    var date: Date
}

struct SavedCoupon: Codable, Equatable, Identifiable {
    var id = UUID()
    var host: String
    var code: String
    var note = ""
}

struct Subscription: Codable, Equatable, Identifiable {
    enum Period: String, Codable, CaseIterable, Identifiable { case weekly, monthly, yearly; var id: String { rawValue } }
    var id = UUID()
    var name: String
    var amount: Double
    var period: Period
    var nextRenewal: Date
    var url = ""

    /// The renewal date moved forward by whole periods until it is today or later, so a forgotten entry still shows the next real charge.
    func nextCharge(after now: Date = Date(), calendar: Calendar = .current) -> Date {
        var date = nextRenewal
        let component: Calendar.Component = period == .weekly ? .weekOfYear : period == .monthly ? .month : .year
        var guardCount = 0
        while date < calendar.startOfDay(for: now), guardCount < 1000, let next = calendar.date(byAdding: component, value: 1, to: date) { date = next; guardCount += 1 }
        return date
    }

    var monthlyCost: Double {
        switch period { case .weekly: amount * 52 / 12; case .monthly: amount; case .yearly: amount / 12 }
    }
}

enum SubscriptionMath {
    static func monthlyTotal(_ list: [Subscription]) -> Double { list.reduce(0) { $0 + $1.monthlyCost } }
    static func renewingSoon(_ list: [Subscription], days: Int = 7, now: Date = Date()) -> [Subscription] {
        let limit = Calendar.current.date(byAdding: .day, value: days, to: now) ?? now
        return list.filter { $0.nextCharge(after: now) <= limit }.sorted { $0.nextCharge(after: now) < $1.nextCharge(after: now) }
    }
}

extension BrowserModel {
    func addActiveToComparison() async {
        guard let tab = active, !tab.isPrivate, let url = tab.url else { return }
        let text = await tab.engine.pageText() ?? ""
        comparedProducts.insert(ComparedProduct(title: tab.title, host: displayHost(url), url: url.absoluteString, price: PriceFinder.firstPrice(in: text), date: Date()), at: 0)
        if comparedProducts.count > 40 { comparedProducts.removeLast() }
        notice = "Added to Compare."
    }

    func applyCoupon(_ coupon: SavedCoupon) async {
        let ok = await active?.engine.fillCouponField(coupon.code) ?? false
        notice = ok ? "Entered the code. Press the site’s Apply button." : "No coupon box was found on this page."
    }

    func notifyRenewals() {
        let soon = SubscriptionMath.renewingSoon(subscriptions)
        if let first = soon.first { notice = "\(first.name) renews \(first.nextCharge().formatted(date: .abbreviated, time: .omitted))." }
    }
}

struct ShoppingView: View {
    enum Tab: String, CaseIterable, Identifiable { case compare = "Compare", coupons = "Coupons", subscriptions = "Subscriptions"; var id: String { rawValue } }
    @EnvironmentObject var model: BrowserModel
    @State private var tab: Tab = .compare
    @State private var code = ""
    @State private var newName = ""
    @State private var newAmount = ""
    @State private var newPeriod: Subscription.Period = .monthly
    @State private var newDate = Date()

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden().padding(12)
            Divider()
            switch tab {
            case .compare: compare
            case .coupons: coupons
            case .subscriptions: subscriptions
            }
        }
        .accessibilityIdentifier("shopping")
    }

    private var compare: some View {
        VStack(spacing: 0) {
            Button("Add This Page") { Task { await model.addActiveToComparison() } }.buttonStyle(.borderedProminent).padding(10).disabled(model.active?.isBlank ?? true)
            if model.comparedProducts.isEmpty {
                ContentUnavailableView("Nothing to Compare", systemImage: "scalemass", description: Text("Open a product page and add it. Add the same product from other shops to see them side by side."))
            } else {
                let cheapest = model.comparedProducts.compactMap(\.price).min()
                List {
                    ForEach(model.comparedProducts.sorted { ($0.price ?? .infinity) < ($1.price ?? .infinity) }) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title).lineLimit(2)
                                Text(item.host).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(item.price.map { $0.formatted() } ?? "No price found").fontWeight(item.price == cheapest ? .bold : .regular)
                                .foregroundStyle(item.price == cheapest && item.price != nil ? Color.green : Color.primary)
                        }
                        .contextMenu {
                            Button("Open") { model.open(urlString: item.url, newTab: true) }
                            Button("Remove", role: .destructive) { model.comparedProducts.removeAll { $0.id == item.id } }
                        }
                    }
                }
            }
        }
    }

    private var coupons: some View {
        let host = displayHost(model.active?.url)
        return VStack(spacing: 0) {
            HStack {
                TextField("Coupon code you already have", text: $code)
                Button("Save for \(host)") { model.coupons.append(SavedCoupon(host: host, code: code.trimmingCharacters(in: .whitespaces))); code = "" }
                    .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || model.active?.url == nil)
            }
            .padding(10)
            List {
                ForEach(model.coupons.filter { $0.host == host || host.isEmpty }) { coupon in
                    HStack {
                        Text(coupon.code).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button("Enter") { Task { await model.applyCoupon(coupon) } }.controlSize(.small)
                        Button { model.coupons.removeAll { $0.id == coupon.id } } label: { Image(systemName: "trash").accessibilityLabel("Delete") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                Text("Only codes you saved are used. Browser Setu never searches the web for coupons.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var subscriptions: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Name", text: $newName)
                TextField("Amount", text: $newAmount).frame(width: 70)
                Picker("", selection: $newPeriod) { ForEach(Subscription.Period.allCases) { Text($0.rawValue.capitalized).tag($0) } }.labelsHidden().frame(width: 100)
                DatePicker("", selection: $newDate, displayedComponents: .date).labelsHidden()
                Button("Add") {
                    if let amount = Double(newAmount), !newName.isEmpty {
                        model.subscriptions.append(Subscription(name: newName, amount: amount, period: newPeriod, nextRenewal: newDate, url: model.active?.url?.absoluteString ?? ""))
                        newName = ""; newAmount = ""
                    }
                }
            }
            .padding(10)
            List {
                ForEach(model.subscriptions.sorted { $0.nextCharge() < $1.nextCharge() }) { sub in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(sub.name)
                            Text("Next \(sub.nextCharge().formatted(date: .abbreviated, time: .omitted)) · \(sub.period.rawValue)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(sub.amount.formatted())
                        Button { model.subscriptions.removeAll { $0.id == sub.id } } label: { Image(systemName: "trash").accessibilityLabel("Delete") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                if !model.subscriptions.isEmpty {
                    Text("About \(SubscriptionMath.monthlyTotal(model.subscriptions).formatted(.number.precision(.fractionLength(2)))) a month in total.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}
