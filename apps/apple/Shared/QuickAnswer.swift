import Foundation

/// Answers typed into the address bar that need no network: sums ("12 * (3 + 4)", "15% of 80", "sqrt(2)") and unit conversions ("5 km to miles", "72 f in c").
enum QuickAnswer {
    struct Result: Equatable {
        /// What to show and copy: "35.0", "3.10686 mi".
        let text: String
        /// How the question was understood: "5 km → mi".
        let reading: String
    }

    static func answer(for input: String) -> Result? {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count <= 120 else { return nil }
        return conversion(text) ?? percentOf(text) ?? arithmetic(text)
    }

    // MARK: Sums

    /// Shown only when there is something to work out: an operator, a function or a constant. A bare number is not a question.
    private static func arithmetic(_ text: String) -> Result? {
        // A plain number, or a date such as 2024-10-17, is not a sum.
        guard Double(text) == nil, text.range(of: #"^\d{1,4}[-/.]\d{1,2}[-/.]\d{1,4}$"#, options: .regularExpression) == nil else { return nil }
        var parser = Parser(text)
        guard parser.hasOperation, let value = parser.parse(), value.isFinite else { return nil }
        return Result(text: format(value), reading: text)
    }

    private static func percentOf(_ text: String) -> Result? {
        let lower = text.lowercased()
        guard let range = lower.range(of: "% of ") else { return nil }
        guard let percent = Double(lower[..<range.lowerBound].trimmingCharacters(in: .whitespaces)) else { return nil }
        var parser = Parser(String(lower[range.upperBound...]))
        guard let base = parser.parse(), base.isFinite else { return nil }
        return Result(text: format(percent / 100 * base), reading: "\(format(percent))% of \(format(base))")
    }

    struct Parser {
        private let chars: [Character]
        private var at = 0
        private(set) var hasOperation = false

        init(_ text: String) {
            let swapped = text.lowercased().replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/").replacingOccurrences(of: "−", with: "-")
            chars = Array(swapped.filter { !$0.isWhitespace })
            hasOperation = chars.contains { "+-*/^%(".contains($0) } || chars.contains("x")
        }

        mutating func parse() -> Double? {
            guard let value = expression(), at == chars.count else { return nil }
            return value
        }

        private func peek() -> Character? { at < chars.count ? chars[at] : nil }

        private mutating func expression() -> Double? {
            guard var left = term() else { return nil }
            while let c = peek(), c == "+" || c == "-" {
                at += 1
                guard let right = term() else { return nil }
                left = c == "+" ? left + right : left - right
            }
            return left
        }

        private mutating func term() -> Double? {
            guard var left = power() else { return nil }
            while let c = peek(), c == "*" || c == "/" || c == "x" {
                at += 1
                guard let right = power() else { return nil }
                if c == "/" { guard right != 0 else { return nil }; left /= right } else { left *= right }
            }
            return left
        }

        private mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if peek() == "^" {
                at += 1
                guard let exponent = power() else { return nil }      // right to left: 2^3^2 is 2^(3^2)
                return Foundation.pow(base, exponent)
            }
            return base
        }

        private mutating func unary() -> Double? {
            if peek() == "-" { at += 1; return unary().map { -$0 } }
            if peek() == "+" { at += 1; return unary() }
            guard var value = primary() else { return nil }
            while peek() == "%" { at += 1; value /= 100 }
            return value
        }

        private mutating func primary() -> Double? {
            guard let c = peek() else { return nil }
            if c == "(" {
                at += 1
                guard let inner = expression(), peek() == ")" else { return nil }
                at += 1
                return inner
            }
            if c.isNumber || c == "." { return number() }
            if c.isLetter { return name() }
            return nil
        }

        private mutating func number() -> Double? {
            let start = at
            var dots = 0
            while let c = peek(), c.isNumber || c == "." || c == "," { if c == "." { dots += 1 }; at += 1 }
            guard dots <= 1 else { return nil }
            return Double(String(chars[start..<at]).replacingOccurrences(of: ",", with: ""))
        }

        private mutating func name() -> Double? {
            let start = at
            while let c = peek(), c.isLetter { at += 1 }
            let word = String(chars[start..<at])
            switch word {
            case "pi": return Double.pi
            case "e": return M_E
            default: break
            }
            guard peek() == "(" else { return nil }
            at += 1
            guard let argument = expression(), peek() == ")" else { return nil }
            at += 1
            switch word {
            case "sqrt": return argument >= 0 ? argument.squareRoot() : nil
            case "sin": return Foundation.sin(argument * .pi / 180)
            case "cos": return Foundation.cos(argument * .pi / 180)
            case "tan": return Foundation.tan(argument * .pi / 180)
            case "ln": return argument > 0 ? Foundation.log(argument) : nil
            case "log": return argument > 0 ? Foundation.log10(argument) : nil
            case "abs": return Swift.abs(argument)
            case "round": return argument.rounded()
            case "floor": return Foundation.floor(argument)
            case "ceil": return Foundation.ceil(argument)
            default: return nil
            }
        }
    }

    /// Ten significant digits, no trailing zeros, grouped by nothing so it pastes anywhere.
    static func format(_ value: Double) -> String {
        if value == value.rounded(), Swift.abs(value) < 1e15 { return String(Int64(value)) }
        if Swift.abs(value) >= 1e15 || Swift.abs(value) < 1e-6 { return String(format: "%.6e", value) }
        var text = String(format: "%.10g", value)
        if text.contains("e") { text = String(format: "%.6f", value) }
        if text.contains("."), !text.contains("e") { while text.hasSuffix("0") { text.removeLast() }; if text.hasSuffix(".") { text.removeLast() } }
        return text
    }

    // MARK: Units

    private enum Kind { case length, mass, volume, speed, area, time, data, temperature }
    /// Each unit: its kind and how many of the kind's base unit it is (metre, gram, litre, metre per second, square metre, second, byte).
    private static let units: [String: (Kind, Double, String)] = {
        var table: [String: (Kind, Double, String)] = [:]
        func add(_ names: [String], _ kind: Kind, _ factor: Double, _ label: String) { for name in names { table[name] = (kind, factor, label) } }
        add(["mm", "millimeter", "millimeters", "millimetre", "millimetres"], .length, 0.001, "mm")
        add(["cm", "centimeter", "centimeters", "centimetre", "centimetres"], .length, 0.01, "cm")
        add(["m", "meter", "meters", "metre", "metres"], .length, 1, "m")
        add(["km", "kilometer", "kilometers", "kilometre", "kilometres"], .length, 1000, "km")
        add(["in", "inch", "inches"], .length, 0.0254, "in")
        add(["ft", "foot", "feet"], .length, 0.3048, "ft")
        add(["yd", "yard", "yards"], .length, 0.9144, "yd")
        add(["mi", "mile", "miles"], .length, 1609.344, "mi")
        add(["mg", "milligram", "milligrams"], .mass, 0.001, "mg")
        add(["g", "gram", "grams"], .mass, 1, "g")
        add(["kg", "kilo", "kilos", "kilogram", "kilograms"], .mass, 1000, "kg")
        add(["t", "tonne", "tonnes"], .mass, 1_000_000, "t")
        add(["oz", "ounce", "ounces"], .mass, 28.349523125, "oz")
        add(["lb", "lbs", "pound", "pounds"], .mass, 453.59237, "lb")
        add(["st", "stone"], .mass, 6350.29318, "st")
        add(["ml", "milliliter", "milliliters", "millilitre", "millilitres"], .volume, 0.001, "ml")
        add(["l", "liter", "liters", "litre", "litres"], .volume, 1, "l")
        add(["tsp", "teaspoon", "teaspoons"], .volume, 0.00492892159375, "tsp")
        add(["tbsp", "tablespoon", "tablespoons"], .volume, 0.01478676478125, "tbsp")
        add(["floz", "fl oz"], .volume, 0.0295735295625, "fl oz")
        add(["cup", "cups"], .volume, 0.2365882365, "cup")
        add(["pt", "pint", "pints"], .volume, 0.473176473, "pt")
        add(["qt", "quart", "quarts"], .volume, 0.946352946, "qt")
        add(["gal", "gallon", "gallons"], .volume, 3.785411784, "gal")
        add(["m/s", "mps"], .speed, 1, "m/s")
        add(["km/h", "kmh", "kph"], .speed, 1000.0 / 3600, "km/h")
        add(["mph"], .speed, 0.44704, "mph")
        add(["kn", "knot", "knots"], .speed, 1852.0 / 3600, "kn")
        add(["m2", "sqm"], .area, 1, "m²")
        add(["km2", "sqkm"], .area, 1_000_000, "km²")
        add(["ft2", "sqft"], .area, 0.09290304, "ft²")
        add(["ha", "hectare", "hectares"], .area, 10_000, "ha")
        add(["acre", "acres"], .area, 4046.8564224, "acres")
        add(["ms", "millisecond", "milliseconds"], .time, 0.001, "ms")
        add(["s", "sec", "second", "seconds"], .time, 1, "s")
        add(["min", "minute", "minutes"], .time, 60, "min")
        add(["h", "hr", "hour", "hours"], .time, 3600, "h")
        add(["d", "day", "days"], .time, 86_400, "days")
        add(["wk", "week", "weeks"], .time, 604_800, "weeks")
        add(["byte", "bytes"], .data, 1, "bytes")
        add(["kb"], .data, 1000, "KB")
        add(["mb"], .data, 1_000_000, "MB")
        add(["gb"], .data, 1_000_000_000, "GB")
        add(["tb"], .data, 1_000_000_000_000, "TB")
        add(["kib"], .data, 1024, "KiB")
        add(["mib"], .data, 1_048_576, "MiB")
        add(["gib"], .data, 1_073_741_824, "GiB")
        add(["c", "celsius", "°c"], .temperature, 1, "°C")
        add(["f", "fahrenheit", "°f"], .temperature, 1, "°F")
        add(["k", "kelvin"], .temperature, 1, "K")
        return table
    }()

    private static func conversion(_ text: String) -> Result? {
        let lower = text.lowercased()
        var amount = "", rest = Substring(lower)
        while let c = rest.first, c.isNumber || c == "." || c == "-" || c == "," { amount.append(c); rest = rest.dropFirst() }
        guard let value = Double(amount.replacingOccurrences(of: ",", with: "")) else { return nil }
        let words = rest.split(separator: " ").map(String.init)
        guard words.count >= 3 else { return nil }
        guard let joiner = words.firstIndex(where: { ["to", "in", "as", "into", "->"].contains($0) }), joiner > 0, joiner < words.count - 1 else { return nil }
        let from = words[..<joiner].joined(separator: " "), to = words[(joiner + 1)...].joined(separator: " ")
        guard let source = units[from], let target = units[to], source.0 == target.0 else { return nil }
        let converted: Double
        if source.0 == .temperature {
            let celsius: Double
            switch source.2 { case "°F": celsius = (value - 32) * 5 / 9; case "K": celsius = value - 273.15; default: celsius = value }
            switch target.2 { case "°F": converted = celsius * 9 / 5 + 32; case "K": converted = celsius + 273.15; default: converted = celsius }
        } else {
            converted = value * source.1 / target.1
        }
        guard converted.isFinite else { return nil }
        return Result(text: format(rounded(converted)) + (target.2.hasPrefix("°") || target.2 == "K" ? " " : " ") + target.2, reading: "\(format(value)) \(source.2) → \(target.2)")
    }

    /// Conversions are shown to six significant figures; the exact value is not wanted when the question was loose.
    private static func rounded(_ value: Double) -> Double {
        guard value != 0 else { return 0 }
        let scale = Foundation.pow(10, 5 - Foundation.floor(Foundation.log10(Swift.abs(value))))
        return (value * scale).rounded() / scale
    }
}
