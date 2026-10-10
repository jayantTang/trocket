import XCTest

/// 规则集相关的测试脚手架：把规则集文件放进临时目录，模拟 App Group 容器。
///
/// 单元测试运行在测试 bundle 里，没有 App Group 容器、也没有内置资源，
/// 所以所有涉及规则集的路径都必须注入 `base`（见 `RuleSetStore.directory(base:)`）。
extension XCTestCase {

    /// 建一个临时目录，作为规则集容器的替身。
    func makeRuleSetDirectory(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("trocket-ruleset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// 往容器替身的 `rule-set/` 目录里写一个假规则集。
    /// 内容只需满足"是最小合法 SRS 文件"，判断逻辑只看文件是否存在。
    @discardableResult
    func writeRuleSet(named name: String, in base: URL) throws -> URL {
        let dir = base.appendingPathComponent(RuleSetStore.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        var payload = Data("SRS".utf8)
        payload.append(Data([0x01]))
        payload.append(Data(repeating: 0x00, count: 16))
        try payload.write(to: url)
        return url
    }
}

/// 把内置的两个规则集都放进容器替身，供"应当出现国内直连规则"的用例使用。
extension XCTestCase {
    func writeBundledRuleSets(in base: URL) throws {
        for name in RuleSetStore.bundledNames {
            try writeRuleSet(named: name, in: base)
        }
    }
}
