//
//  CompanionPanelMissionMoneyPolicy.swift
//  leanring-buddy
//
//  Pure money formatting rules for the Ad Mission panel wizard.
//

import Foundation

struct CompanionPanelCurrencyOption: Identifiable {
    var id: String { code }
    let code: String
    let name: String
    let symbol: String

    var menuTitle: String {
        "\(code) - \(name)"
    }
}

struct CompanionPanelTicketInput {
    let amount: String
    let currencyCode: String
}

enum CompanionPanelMissionMoneyPolicy {
    static let defaultCurrencyCode = "USD"

    static let currencyOptions: [CompanionPanelCurrencyOption] = [
        CompanionPanelCurrencyOption(code: "USD", name: "US Dollar", symbol: "$"),
        CompanionPanelCurrencyOption(code: "EUR", name: "Euro", symbol: "€"),
        CompanionPanelCurrencyOption(code: "GBP", name: "British Pound", symbol: "£"),
        CompanionPanelCurrencyOption(code: "BRL", name: "Brazilian Real", symbol: "R$"),
        CompanionPanelCurrencyOption(code: "CAD", name: "Canadian Dollar", symbol: "C$"),
        CompanionPanelCurrencyOption(code: "AUD", name: "Australian Dollar", symbol: "A$"),
        CompanionPanelCurrencyOption(code: "MXN", name: "Mexican Peso", symbol: "$"),
        CompanionPanelCurrencyOption(code: "JPY", name: "Japanese Yen", symbol: "¥"),
        CompanionPanelCurrencyOption(code: "CHF", name: "Swiss Franc", symbol: "CHF"),
        CompanionPanelCurrencyOption(code: "INR", name: "Indian Rupee", symbol: "₹"),
        CompanionPanelCurrencyOption(code: "SGD", name: "Singapore Dollar", symbol: "S$"),
        CompanionPanelCurrencyOption(code: "AED", name: "UAE Dirham", symbol: "AED"),
    ]

    static func monetaryValueForMission(_ amount: String, currencyCode: String) -> String {
        let trimmedAmount = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAmount.isEmpty else { return "" }

        let trimmedCurrencyCode = currencyCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCurrencyCode.isEmpty else { return trimmedAmount }

        if trimmedAmount.uppercased().hasPrefix("\(trimmedCurrencyCode.uppercased()) ") {
            return trimmedAmount
        }

        return "\(trimmedCurrencyCode) \(normalizedTicketAmount(trimmedAmount, currencyCode: trimmedCurrencyCode))"
    }

    static func normalizedDailyGuardrailAmount(_ amount: String, currencyCode: String) -> String {
        let normalizedAmount = normalizedTicketAmount(amount, currencyCode: currencyCode)
        return sanitizedNumericMoneyInput(normalizedAmount)
    }

    static func normalizedTicketAmount(_ amount: String, currencyCode: String) -> String {
        let trimmedAmount = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        let uppercasedAmount = trimmedAmount.uppercased()

        if let matchedCurrency = currencyOptions.first(where: { uppercasedAmount.hasPrefix("\($0.code) ") }) {
            return String(trimmedAmount.dropFirst(matchedCurrency.code.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let currencySymbols = currencyOptions
            .filter { !$0.symbol.isEmpty }
            .sorted { $0.symbol.count > $1.symbol.count }

        if let selectedCurrency = currencyOptions.first(where: { $0.code == currencyCode }),
           !selectedCurrency.symbol.isEmpty,
           trimmedAmount.hasPrefix(selectedCurrency.symbol) {
            return String(trimmedAmount.dropFirst(selectedCurrency.symbol.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let matchedCurrency = currencySymbols.first(where: { trimmedAmount.hasPrefix($0.symbol) }) {
            return String(trimmedAmount.dropFirst(matchedCurrency.symbol.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return trimmedAmount
    }

    static func ticketInput(fromStoredValue storedTicket: String) -> CompanionPanelTicketInput {
        let trimmedTicket = storedTicket.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTicket.isEmpty else {
            return .init(amount: "", currencyCode: defaultCurrencyCode)
        }

        let uppercasedTicket = trimmedTicket.uppercased()
        if let matchedCurrency = currencyOptions.first(where: { uppercasedTicket.hasPrefix("\($0.code) ") }) {
            return .init(
                amount: String(trimmedTicket.dropFirst(matchedCurrency.code.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                currencyCode: matchedCurrency.code
            )
        }

        let currencySymbols = currencyOptions
            .filter { !$0.symbol.isEmpty }
            .sorted { $0.symbol.count > $1.symbol.count }

        if let matchedCurrency = currencySymbols.first(where: { trimmedTicket.hasPrefix($0.symbol) }) {
            return .init(
                amount: String(trimmedTicket.dropFirst(matchedCurrency.symbol.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                currencyCode: matchedCurrency.code
            )
        }

        return .init(amount: trimmedTicket, currencyCode: defaultCurrencyCode)
    }

    static func sanitizedNumericMoneyInput(_ amount: String) -> String {
        var sanitized = ""
        var hasDecimalSeparator = false

        for character in amount {
            if character.isNumber {
                sanitized.append(character)
            } else if (character == "." || character == ","), !hasDecimalSeparator {
                sanitized.append(character)
                hasDecimalSeparator = true
            }
        }

        return sanitized
    }
}
