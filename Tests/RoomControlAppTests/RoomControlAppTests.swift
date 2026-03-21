import Testing
@testable import FeatureUI
@testable import RoutingDomain
@testable import ClipPlayerDomain
@testable import TimerDomain
@testable import PresentationDomain
@testable import PersistenceDomain

@Test func brandTokensExist() async throws {
    // Verify BrandTokens are accessible from test target.
    _ = BrandTokens.gold
    _ = BrandTokens.dark
    _ = BrandTokens.pgnGreen
    _ = BrandTokens.pvwRed
}

@Test func persistedLayoutDefaults() async throws {
    let layout = PersistedLayout()
    #expect(layout.leadingWidth == 340)
    #expect(layout.centerWidth == 340)
}
