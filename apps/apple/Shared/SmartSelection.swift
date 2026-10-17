import EventKit
import Foundation
import SwiftUI
#if os(macOS)
import CoreServices
#endif

/// A measurement found in selected text and what it is worth in other units. Works offline.
struct UnitConversion: Identifiable, Equatable {
    var id: String { source + "->" + result }
    var source: String
    var result: String
}

enum UnitConverter {
    private struct Unit {
        let names: [String]
        let dimension: Dimension
        let targets: [(Dimension, String)]
    }

    private static let units: [Unit] = [
        .init(names: ["km", "kilometer", "kilometers", "kilometre", "kilometres"], dimension: UnitLength.kilometers, targets: [(UnitLength.miles, "mi")]),
        .init(names: ["mi", "mile", "miles"], dimension: UnitLength.miles, targets: [(UnitLength.kilometers, "km")]),
        .init(names: ["m", "meter", "meters", "metre", "metres"], dimension: UnitLength.meters, targets: [(UnitLength.feet, "ft")]),
        .init(names: ["ft", "foot", "feet"], dimension: UnitLength.feet, targets: [(UnitLength.meters, "m")]),
        .init(names: ["in", "inch", "inches"], dimension: UnitLength.inches, targets: [(UnitLength.centimeters, "cm")]),
        .init(names: ["cm", "centimeter", "centimeters", "centimetre", "centimetres"], dimension: UnitLength.centimeters, targets: [(UnitLength.inches, "in")]),
        .init(names: ["kg", "kilogram", "kilograms"], dimension: UnitMass.kilograms, targets: [(UnitMass.pounds, "lb")]),
        .init(names: ["lb", "lbs", "pound", "pounds"], dimension: UnitMass.pounds, targets: [(UnitMass.kilograms, "kg")]),
        .init(names: ["g", "gram", "grams"], dimension: UnitMass.grams, targets: [(UnitMass.ounces, "oz")]),
        .init(names: ["oz", "ounce", "ounces"], dimension: UnitMass.ounces, targets: [(UnitMass.grams, "g")]),
        .init(names: ["l", "liter", "liters", "litre", "litres"], dimension: UnitVolume.liters, targets: [(UnitVolume.gallons, "US gal")]),
        .init(names: ["gal", "gallon", "gallons"], dimension: UnitVolume.gallons, targets: [(UnitVolume.liters, "L")]),
        .init(names: ["ml", "milliliter", "milliliters", "millilitre", "millilitres"], dimension: UnitVolume.milliliters, targets: [(UnitVolume.fluidOunces, "US fl oz")]),
        .init(names: ["°c", "c", "celsius"], dimension: UnitTemperature.celsius, targets: [(UnitTemperature.fahrenheit, "°F")]),
        .init(names: ["°f", "f", "fahrenheit"], dimension: UnitTemperature.fahrenheit, targets: [(UnitTemperature.celsius, "°C")]),
        .init(names: ["mph"], dimension: UnitSpeed.milesPerHour, targets: [(UnitSpeed.kilometersPerHour, "km/h")]),
        .init(names: ["km/h", "kph", "kmh"], dimension: UnitSpeed.kilometersPerHour, targets: [(UnitSpeed.milesPerHour, "mph")]),
    ]

    private static let pattern = try! NSRegularExpression(pattern: #"(-?\d{1,3}(?:,\d{3})*(?:\.\d+)?|-?\d+(?:\.\d+)?)\s?(°\s?[CcFf]|[A-Za-z]+(?:/[A-Za-z]+)?)"#)

    static func conversions(in text: String) -> [UnitConversion] {
        let range = NSRange(text.startIndex..., in: text)
        var found: [UnitConversion] = []
        for match in pattern.matches(in: text, range: range).prefix(8) {
            guard let numberRange = Range(match.range(at: 1), in: text), let unitRange = Range(match.range(at: 2), in: text),
                  let value = Double(text[numberRange].replacingOccurrences(of: ",", with: "")) else { continue }
            let word = text[unitRange].lowercased().replacingOccurrences(of: " ", with: "")
            guard let unit = units.first(where: { $0.names.contains(word) }) else { continue }
            // A single letter such as "m" or "c" is only a unit when it is written right after the number, like "5m" or "20c".
            if word.count == 1, text[text.index(numberRange.upperBound, offsetBy: 0)..<unitRange.lowerBound].contains(" ") { continue }
            let measurement = Measurement(value: value, unit: unit.dimension)
            for (target, label) in unit.targets {
                let converted = measurement.converted(to: target)
                let number = converted.value.formatted(.number.precision(.fractionLength(0...2)))
                found.append(UnitConversion(source: "\(text[numberRange]) \(text[unitRange])", result: "\(number) \(label)"))
            }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.id).inserted }
    }
}

enum ReminderMaker {
    enum Failure: Error { case denied }

    /// Adds a reminder to the user's default list. The system asks for permission the first time.
    static func add(title: String, notes: String?) async throws {
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else { throw Failure.denied }
        let reminder = EKReminder(eventStore: store)
        reminder.title = String(title.prefix(200))
        reminder.notes = notes
        reminder.calendar = store.defaultCalendarForNewReminders()
        try store.save(reminder, commit: true)
    }
}

@MainActor
func definition(of word: String) -> String? {
    #if os(macOS)
    let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count < 60 else { return nil }
    return DCSCopyTextDefinition(nil, trimmed as CFString, CFRange(location: 0, length: (trimmed as NSString).length))?.takeRetainedValue() as String?
    #else
    return nil
    #endif
}

/// What you can do with the words selected on the page: search, look up, convert, remind, copy.
struct SmartSelectionView: View {
    @EnvironmentObject var model: BrowserModel
    @State private var text = ""
    @State private var definitionText: String?
    @State private var message: String?
    @State private var showDictionary = false

    private var conversions: [UnitConversion] { UnitConverter.conversions(in: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if text.isEmpty {
                ContentUnavailableView("Nothing Selected", systemImage: "text.cursor", description: Text("Select some words on the page, then open this again."))
            } else {
                Text(text).font(.title3).lineLimit(5).textSelection(.enabled)
                HStack {
                    Button("Search") { model.sheet = nil; model.open(urlString: text, newTab: true) }
                    Button("Copy") { copyToPasteboard(text) }
                    if text.count < 60 {
                        #if os(macOS)
                        Button("Define") { definitionText = definition(of: text) ?? "No definition found."; message = nil }
                        #else
                        Button("Define") { showDictionary = true }
                        #endif
                    }
                    Button("Remind Me") { Task { await remind() } }
                }
                .buttonStyle(.bordered)
                if let definitionText { Text(definitionText).font(.callout).foregroundStyle(.secondary).lineLimit(12).textSelection(.enabled) }
                if !conversions.isEmpty {
                    Divider()
                    ForEach(conversions) { item in
                        HStack { Text(item.source); Image(systemName: "arrow.right").foregroundStyle(.secondary); Text(item.result).fontWeight(.medium) }
                    }
                    Text("Unit conversions work offline. Currency needs a live rate, which Browser Setu does not fetch.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                let details = DetailExtractor.find(in: text)
                if !details.isEmpty {
                    Divider()
                    DetailsList(details: details, pageURL: model.active?.url?.absoluteString).frame(minHeight: 120)
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 320, minHeight: 200, alignment: .topLeading)
        .task { text = await model.active?.engine.selectedText() ?? "" }
        #if os(iOS)
        .sheet(isPresented: $showDictionary) { DictionaryView(term: text) }
        #endif
        .accessibilityIdentifier("smart-selection")
    }

    private func remind() async {
        do {
            try await ReminderMaker.add(title: text, notes: model.active?.url?.absoluteString)
            message = "Added to Reminders."
        } catch {
            message = "Reminders access is off. Turn it on for Browser Setu in System Settings → Privacy."
        }
    }
}

#if os(iOS)
import UIKit
struct DictionaryView: UIViewControllerRepresentable {
    let term: String
    func makeUIViewController(context: Context) -> UIReferenceLibraryViewController { UIReferenceLibraryViewController(term: term) }
    func updateUIViewController(_ controller: UIReferenceLibraryViewController, context: Context) {}
}
#endif
