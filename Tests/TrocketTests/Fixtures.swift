import XCTest

/// 测试夹具：全部为脱敏后的真实结构（服务商返回的 sing-box JSON 与 Clash YAML）。
enum Fixtures {

    static func data(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> Data {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: name, withExtension: nil) else {
            XCTFail("缺少夹具 \(name)", file: file, line: line)
            throw TrocketError.unparsableSubscription
        }
        return try Data(contentsOf: url)
    }

    static func text(_ name: String) throws -> String {
        guard let text = String(data: try data(name), encoding: .utf8) else {
            throw TrocketError.unparsableSubscription
        }
        return text
    }

    static let singboxSample = "singbox-sample.json"
    static let clashSample = "clash-sample.yaml"
}

private final class BundleToken {}
