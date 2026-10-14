import SwiftUI
import Testing
@testable import HermesUI

@Suite struct ChatTextSizeTests {
    @Test func defaultSettingFollowsTheSystemSize() {
        for system in DynamicTypeSize.allCases {
            #expect(ChatTextSize.effective(ChatTextSize.standard, system: system) == system)
        }
    }

    @Test func settingStepsFromTheSystemSize() {
        #expect(ChatTextSize.effective(ChatTextSize.standard + 1, system: .large) == .xLarge)
        #expect(ChatTextSize.effective(ChatTextSize.standard - 1, system: .large) == .medium)
        #expect(ChatTextSize.effective(ChatTextSize.standard + 1, system: .accessibility1) == .accessibility2)
    }

    @Test func stepsStopAtTheEnds() {
        #expect(ChatTextSize.effective(0, system: .xSmall) == .xSmall)
        #expect(ChatTextSize.effective(ChatTextSize.sizes.count - 1, system: .accessibility5) == .accessibility5)
    }
}
