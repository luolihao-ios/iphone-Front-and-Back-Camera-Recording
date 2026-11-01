import XCTest
@testable import DualCapture

final class LocalizationTests: XCTestCase {
    // 使用应用本身的已编译资源，避免测试资源副本掩盖打包遗漏。
    private var appBundle: Bundle { Bundle(for: CameraManager.self) }

    private func localizedBundle(_ language: String) throws -> Bundle {
        let path = try XCTUnwrap(appBundle.path(forResource: language, ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path))
    }

    func testActualSettingsAndDynamicErrorOutputInEveryLanguage() throws {
        let samples = [
            ("en", "Settings", "Unable to configure dual cameras: test"),
            ("zh-Hans", "设置", "无法配置双摄会话：test"),
            ("zh-Hant", "設定", "無法設定雙攝影機工作階段：test")
        ]
        for (language, title, error) in samples {
            let bundle = try localizedBundle(language)
            XCTAssertEqual(L10n.string("settings.title", bundle: bundle), title)
            XCTAssertEqual(L10n.format("error.session.configuration", "test", bundle: bundle), error)
        }
    }

    func testRegionalSystemLanguagesResolveToSupportedLocalization() {
        let supported = appBundle.localizations
        for (preferred, expected) in [("en-GB", "en"), ("en-AU", "en"),
                                      ("zh-CN", "zh-Hans"), ("zh-SG", "zh-Hans"),
                                      ("zh-TW", "zh-Hant"), ("zh-HK", "zh-Hant"),
                                      ("zh-Hant-MO", "zh-Hant")] {
            XCTAssertEqual(Bundle.preferredLocalizations(from: supported, forPreferences: [preferred]).first,
                           expected, preferred)
        }
        XCTAssertEqual(appBundle.developmentLocalization, "en")
        XCTAssertEqual(Bundle.preferredLocalizations(from: supported, forPreferences: ["fr-FR", "en-US"]).first, "en")
    }

    func testAllTranslationsArePresentInCompiledApplicationResources() throws {
        let english = try localizedBundle("en")
        let url = try XCTUnwrap(english.url(forResource: "Localizable", withExtension: "strings"))
        let data = try Data(contentsOf: url)
        let values = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
        XCTAssertFalse(values.isEmpty)
        for language in ["en", "zh-Hans", "zh-Hant"] {
            let bundle = try localizedBundle(language)
            for key in values.keys {
                let translated = L10n.string(key, bundle: bundle)
                XCTAssertFalse(translated.isEmpty, "\(language): \(key)")
                XCTAssertNotEqual(translated, key, "\(language): \(key)")
            }
        }
    }

    func testCompiledAppContainsTranslatedSystemPermissionPrompts() throws {
        let expectedCameraPrompts = [
            "en": "Camera access is used to record with the front and rear cameras together.",
            "zh-Hans": "用于同时录制前后摄像头视频。",
            "zh-Hant": "用於同時錄製前後攝影機影片。"
        ]
        for (language, cameraPrompt) in expectedCameraPrompts {
            let bundle = try localizedBundle(language)
            XCTAssertEqual(bundle.localizedString(forKey: "NSCameraUsageDescription", value: nil, table: "InfoPlist"), cameraPrompt)
            for key in ["NSMicrophoneUsageDescription", "NSPhotoLibraryUsageDescription", "NSPhotoLibraryAddUsageDescription"] {
                let value = bundle.localizedString(forKey: key, value: nil, table: "InfoPlist")
                XCTAssertFalse(value.isEmpty)
                XCTAssertNotEqual(value, key)
            }
        }
    }
}
