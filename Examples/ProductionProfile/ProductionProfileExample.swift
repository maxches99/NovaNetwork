import Foundation
import NovaNetworkClient

@main
struct ProductionProfileExample {
    static func main() async {
        let generator = NetworkClientProductionProfileGenerator()
        let profile = generator.generate(
            goal: .offlineFirst,
            overlays: [.offlineDurability, .strictReliability],
            offlineStoreConfigured: false
        )

        print("Goal: \(profile.goal.rawValue)")
        print("Base preset: \(profile.basePreset.kind.rawValue)")
        print("Overlays: \(profile.overlays.map { $0.rawValue }.joined(separator: ", "))")
        print("Production ready: \(profile.validation.isProductionReady)")
        if !profile.validation.issues.isEmpty {
            print("Validation issues:")
            for issue in profile.validation.issues {
                print("- [\(issue.severity.rawValue)] \(issue.code): \(issue.message)")
                print("  Recommendation: \(issue.recommendation)")
            }
        }

        print("\nBootstrap snippet:\n")
        print(profile.bootstrapSnippet(includeOfflineStore: true))
    }
}
