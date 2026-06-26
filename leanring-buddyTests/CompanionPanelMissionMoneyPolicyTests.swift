//
//  CompanionPanelMissionMoneyPolicyTests.swift
//  leanring-buddyTests
//
//  Keeps Ad Mission wizard money formatting out of the SwiftUI view.
//

import Testing
@testable import Spider

struct CompanionPanelMissionMoneyPolicyTests {
    @Test func currencyOptionsKeepExistingMenuValues() {
        #expect(CompanionPanelMissionMoneyPolicy.currencyOptions.first?.menuTitle == "USD - US Dollar")
        #expect(CompanionPanelMissionMoneyPolicy.currencyOptions.contains {
            $0.code == "BRL" && $0.symbol == "R$"
        })
        #expect(CompanionPanelMissionMoneyPolicy.currencyOptions.contains {
            $0.code == "AED" && $0.menuTitle == "AED - UAE Dirham"
        })
    }

    @Test func monetaryValueKeepsExistingPrefixRules() {
        #expect(
            CompanionPanelMissionMoneyPolicy.monetaryValueForMission("97", currencyCode: "USD")
                == "USD 97"
        )
        #expect(
            CompanionPanelMissionMoneyPolicy.monetaryValueForMission("USD 97", currencyCode: "USD")
                == "USD 97"
        )
        #expect(
            CompanionPanelMissionMoneyPolicy.monetaryValueForMission("R$97", currencyCode: "BRL")
                == "BRL 97"
        )
    }

    @Test func dailyGuardrailKeepsOnlyNumericAmountAndOneSeparator() {
        #expect(
            CompanionPanelMissionMoneyPolicy.normalizedDailyGuardrailAmount(
                "USD 10.50/day",
                currencyCode: "USD"
            )
                == "10.50"
        )
        #expect(
            CompanionPanelMissionMoneyPolicy.normalizedDailyGuardrailAmount(
                "R$ 12,30 extra",
                currencyCode: "BRL"
            )
                == "12,30"
        )
    }

    @Test func numericFieldSanitizerKeepsDigitsAndFirstDecimalSeparator() {
        #expect(
            CompanionPanelMissionMoneyPolicy.sanitizedNumericMoneyInput("USD 1,234.50/day")
                == "1,23450"
        )
    }

    @Test func storedTicketParsingPreservesCurrencyWhenPresent() {
        let euroTicket = CompanionPanelMissionMoneyPolicy.ticketInput(fromStoredValue: "EUR 49")
        #expect(euroTicket.amount == "49")
        #expect(euroTicket.currencyCode == "EUR")

        let realTicket = CompanionPanelMissionMoneyPolicy.ticketInput(fromStoredValue: "R$97")
        #expect(realTicket.amount == "97")
        #expect(realTicket.currencyCode == "BRL")

        let defaultTicket = CompanionPanelMissionMoneyPolicy.ticketInput(fromStoredValue: "  120  ")
        #expect(defaultTicket.amount == "120")
        #expect(defaultTicket.currencyCode == "USD")
    }
}
