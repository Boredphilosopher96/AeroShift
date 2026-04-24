@testable import AppBundle
import XCTest

final class AccessibilityRetryTest: XCTestCase {
    func testRetryTransientAxFailuresRetriesApiDisabledUntilSuccess() {
        var calls = 0

        let result: AxQueryResult<String?> = retryTransientAxFailures(attempts: 4, delay: 0) {
            calls += 1
            if calls < 3 {
                return AxQueryResult(status: .apiDisabled, value: nil)
            } else {
                return AxQueryResult(status: .success, value: "window")
            }
        }

        assertEquals(calls, 3)
        assertEquals(result.status, .success)
        assertEquals(result.value, "window")
    }

    func testRetryTransientAxFailuresRetriesCannotCompleteUntilSuccess() {
        var calls = 0

        let result: AxQueryResult<Int?> = retryTransientAxFailures(attempts: 3, delay: 0) {
            calls += 1
            if calls == 1 {
                return AxQueryResult(status: .cannotComplete, value: nil)
            } else {
                return AxQueryResult(status: .success, value: 42)
            }
        }

        assertEquals(calls, 2)
        assertEquals(result.status, .success)
        assertEquals(result.value, 42)
    }

    func testRetryTransientAxFailuresStopsOnNonTransientFailure() {
        var calls = 0

        let result: AxQueryResult<String?> = retryTransientAxFailures(attempts: 4, delay: 0) {
            calls += 1
            return AxQueryResult(status: .attributeUnsupported, value: nil)
        }

        assertEquals(calls, 1)
        assertEquals(result.status, .attributeUnsupported)
        assertEquals(result.value, nil)
    }

    func testRetryTransientAxFailuresReturnsLastTransientFailureWhenAttemptsExhausted() {
        var calls = 0

        let result: AxQueryResult<String?> = retryTransientAxFailures(attempts: 3, delay: 0) {
            calls += 1
            return AxQueryResult(status: .apiDisabled, value: nil)
        }

        assertEquals(calls, 3)
        assertEquals(result.status, .apiDisabled)
        assertEquals(result.value, nil)
    }
}
