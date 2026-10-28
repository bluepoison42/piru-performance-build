import Foundation

// App-only: `ByVolumeDosing` also compiles into the watch target, which has no
// `RouteOfAdministration`.
extension ByVolumeDosing {
    /// Whether the volume input applies to a dose on `route`. An injectable
    /// ester is drawn from a vial in mL only on an injection route; oral and
    /// transdermal estradiol stay a plain mg log. Alcohol applies on every route.
    func offersVolumeInput(on route: RouteOfAdministration) -> Bool {
        guard isMassPerVolume else { return true }
        return route == .intramuscular || route == .subcutaneous
    }
}
