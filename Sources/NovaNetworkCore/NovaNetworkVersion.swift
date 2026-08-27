import Foundation

/// The package's released version.
///
/// This exists because something has to answer "which version wrote this file". The HAR exporter
/// stamps it into `creator.version`, and before this constant existed that field was a literal that
/// said `2.13` long after 2.13 had been superseded — a number nobody thought to change because
/// nothing pointed at it.
///
/// Bump it when cutting a release; `CONTRIBUTING.md` lists it in the release steps.
public enum NovaNetworkVersion {
    /// The current version, as a tag name without a leading `v`.
    public static let current = "3.4.0"
}
