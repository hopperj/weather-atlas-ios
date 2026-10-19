import XCTest

extension XCUIApplication {
  /// Saved and Settings share the More tab so all four main destinations stay visible.
  @MainActor func openSection(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
    let direct = tabBars.buttons[title]
    if direct.exists && direct.isHittable {
      direct.tap()
      return
    }
    let more = tabBars.buttons["More"]
    XCTAssertTrue(more.waitForExistence(timeout: 5), file: file, line: line)
    more.tap()
    let item = buttons["more\(title)"]
    for _ in 0..<4 where !item.exists {
      let back = navigationBars.buttons.firstMatch
      guard back.exists else { break }
      back.tap()
    }
    XCTAssertTrue(item.waitForExistence(timeout: 5), file: file, line: line)
    item.tap()
  }
}
