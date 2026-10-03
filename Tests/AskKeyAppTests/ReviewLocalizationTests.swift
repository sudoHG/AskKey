import XCTest
@testable import AskKeyApp

final class ReviewLocalizationTests: AskKeyAppTestCase {
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
