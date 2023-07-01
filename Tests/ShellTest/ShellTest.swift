import Foundation
import XCTest

@testable import Shell

class ShellTest: XCTestCase {
  func testDoEcho() async {
    let executor = Shell.Executor()
    let result = await executor.do("echo helloWorld")
    XCTAssertEqual(.output("helloWorld\n"), result)
  }

  func testSudoEcho() async {
    let executor = Shell.Executor()
    let result = await executor.sudo("echo helloWorld")
    XCTAssertEqual(.output("helloWorld\n"), result)
  }
}
