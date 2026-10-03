import XCTest
@testable import AskKeyAppKit

final class ReviewLocalizationTests: AskKeyAppTestCase {
    func testIsolatedLaunchAlertPreservesChineseWordingAndHasEnglishCopy() {
        let translations = [
            "Use the isolated launch script": "请使用隔离启动脚本",
            "This test build requires an explicit isolated data directory. Open it using the launch script in the delivery package.":
                "此测试版本需要显式指定隔离数据目录。请通过交付包中的启动脚本打开。",
        ]
        for (key, chinese) in translations {
            XCTAssertEqual(AppLanguage.localized(key, language: "zh-Hans"), chinese)
            XCTAssertEqual(AppLanguage.localized(key, language: "en"), key)
        }
    }

    func testReviewedManagementActionsHaveChineseTranslations() {
        let previous = AppLanguage.current
        defer { AppLanguage.current = previous }
        let translations = [
            "Permanently delete recycled credential": "永久删除回收站中的凭证",
            "Replace credential with imported values": "用导入内容替换凭证",
            "Hidden credential request": "隐藏凭证请求",
            "Delete group": "删除分组",
            "Group name": "分组名称",
            "Create": "创建",
            "Imported environment variables": "导入的环境变量",
        ]
        AppLanguage.current = "zh-Hans"
        for (key, value) in translations { XCTAssertEqual(appLocalized(key), value, key) }
        AppLanguage.current = "en"
        for key in translations.keys { XCTAssertEqual(appLocalized(key), key) }
    }
}
