import Foundation

/// A menu-bar choice persisted in UserDefaults.
protocol Setting: RawRepresentable, CaseIterable, Equatable where AllCases == [Self] {
    static var defaultsKey: String { get }
    static var defaultValue: Self { get }
    var title: String { get }
}

extension Setting {
    static var current: Self {
        get { (UserDefaults.standard.object(forKey: defaultsKey) as? RawValue).flatMap(Self.init(rawValue:)) ?? defaultValue }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}
