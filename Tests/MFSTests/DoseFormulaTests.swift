import XCTest
@testable import MFS

final class DoseFormulaTests: XCTestCase {
    func testShapes() {
        XCTAssertEqual(DoseTimeFunction.linearDecay.shape(minutes: 90, duration: 180), 0.5, accuracy: 1e-9)
        XCTAssertEqual(DoseTimeFunction.linearRise.shape(minutes: 270, duration: 180), 1, accuracy: 1e-9)
        XCTAssertEqual(DoseTimeFunction.logRise.shape(minutes: 0, duration: 180), 0, accuracy: 1e-9)
        XCTAssertEqual(DoseTimeFunction.logRise.shape(minutes: 180, duration: 180), 1, accuracy: 1e-9)
        XCTAssertEqual(DoseTimeFunction.logDecay.shape(minutes: 180, duration: 180), 0, accuracy: 1e-9)
        XCTAssertEqual(DoseTimeFunction.constant.shape(minutes: -1, duration: 180), 0)
    }

    func testImpactSumsTermsWithGlucoseScalarAndFiber() {
        var formula = DoseFormula()
        formula.carbohydrate = DoseTerm(coefficient: 3, function: .constant, durationMinutes: 180, scalar: .glucose)
        formula.protein = DoseTerm(coefficient: 2, function: .linearDecay, durationMinutes: 100, scalar: .none)
        formula.fiber = .half
        // carbs 40 - 10/2 = 35; 3*35*120 = 12600; protein 2*10*0.5 = 10
        let value = formula.impact(carbohydrate: 40, fiber: 10, protein: 10, fat: nil, minutes: 50, glucose: 120)
        XCTAssertEqual(value, 12610, accuracy: 1e-6)
    }

    func testGlucoseScalarWithoutGlucoseContributesZero() {
        let term = DoseTerm(coefficient: 1, function: .constant, durationMinutes: 60, scalar: .glucose)
        XCTAssertEqual(term.value(amount: 10, minutes: 5, glucose: nil), 0)
    }
}
