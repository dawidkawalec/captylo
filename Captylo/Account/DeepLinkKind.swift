import Foundation

/// The `captylo://` links the account handles: `captylo://pro/done` (the site's page after
/// Checkout) and `captylo://account/refresh` (after the subscription Portal). Both refresh the plan.
enum DeepLinkKind: Equatable, Sendable {
    case proDone
    case refresh
}
