import XCTest

@testable import SharedCore

final class SemVerTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(SemVer("1.2.3")?.major, 1)
        XCTAssertEqual(SemVer("1.2.3")?.minor, 2)
        XCTAssertEqual(SemVer("1.2.3")?.patch, 3)
    }

    func testReject() {
        XCTAssertNil(SemVer("1.2"))
        XCTAssertNil(SemVer("not.a.ver"))
        XCTAssertNil(SemVer(""))
        XCTAssertNil(SemVer("-1.0.0"))
    }

    func testDescription() {
        XCTAssertEqual(SemVer(major: 2, minor: 0, patch: 1).description, "2.0.1")
    }

    func testOrdering() {
        XCTAssertLessThan(SemVer("1.0.0")!, SemVer("1.0.1")!)
        XCTAssertLessThan(SemVer("1.0.1")!, SemVer("1.1.0")!)
        XCTAssertLessThan(SemVer("1.9.9")!, SemVer("2.0.0")!)
    }

    func testCodable() throws {
        let v = SemVer(major: 1, minor: 4, patch: 2)
        let data = try JSONEncoder().encode(v)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"1.4.2\"")
        XCTAssertEqual(try JSONDecoder().decode(SemVer.self, from: data), v)
    }
}

final class TemplateKnobsTests: XCTestCase {
    func testDefaults() {
        let k = TemplateKnobs.default
        XCTAssertEqual(k.tone, .conversational)
        XCTAssertEqual(k.audience, .internal_)
        XCTAssertEqual(k.cloudRouting, .useGlobal)
        XCTAssertEqual(k.length, .standard)
    }

    func testCodableUsesStringRawValues() throws {
        let knobs = TemplateKnobs(
            tone: .formal, audience: .crmBound,
            quoteHandling: .verbatimForObjections, actionItemFormat: .table,
            cloudRouting: .forceLocalOnly, length: .detailed
        )
        let data = try JSONEncoder().encode(knobs)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"tone\":\"formal\""))
        XCTAssertTrue(json.contains("\"cloudRouting\":\"forceLocalOnly\""))
        XCTAssertEqual(try JSONDecoder().decode(TemplateKnobs.self, from: data), knobs)
    }

    func testInternalAudienceWireFormat() throws {
        let knobs = TemplateKnobs.default
        let data = try JSONEncoder().encode(knobs)
        let json = String(data: data, encoding: .utf8)!
        XCTAssertTrue(json.contains("\"audience\":\"internal\""))
        XCTAssertFalse(json.contains("\"internal_\""))
    }
}

final class CalendarMatcherTests: XCTestCase {
    func testTitleRegex() throws {
        let m = CalendarMatcher.titleRegex("(?i)1:1")
        XCTAssertTrue(try m.matches(.init(title: "Weekly 1:1", attendees: [], isRecurring: true)))
        XCTAssertFalse(try m.matches(.init(title: "Standup", attendees: [], isRecurring: false)))
    }

    func testAttendeeDomain() throws {
        let m = CalendarMatcher.attendeeDomain("acme.com")
        XCTAssertTrue(try m.matches(.init(title: "x", attendees: ["sarah@acme.com"], isRecurring: false)))
        XCTAssertFalse(try m.matches(.init(title: "x", attendees: ["bob@other.com"], isRecurring: false)))
        XCTAssertTrue(try m.matches(.init(title: "x", attendees: ["SARAH@ACME.COM"], isRecurring: false)))
    }

    func testRecurringSeries() throws {
        let m = CalendarMatcher.recurringSeries
        XCTAssertTrue(try m.matches(.init(title: "x", attendees: [], isRecurring: true)))
        XCTAssertFalse(try m.matches(.init(title: "x", attendees: [], isRecurring: false)))
    }

    func testInvalidRegexThrows() {
        let m = CalendarMatcher.titleRegex("(invalid")
        do {
            _ = try m.matches(.init(title: "x", attendees: [], isRecurring: false))
            XCTFail("expected throw")
        } catch let err {
            guard case TraceError.configInvalid = err else {
                XCTFail("expected configInvalid, got \(err)")
                return
            }
        }
    }

    func testCodableRoundTrip() throws {
        let cases: [CalendarMatcher] = [.titleRegex("foo"), .attendeeDomain("bar.com"), .recurringSeries]
        for matcher in cases {
            let data = try JSONEncoder().encode(matcher)
            XCTAssertEqual(try JSONDecoder().decode(CalendarMatcher.self, from: data), matcher)
        }
    }
}

final class ProjectBindingTests: XCTestCase {
    func testCodable() throws {
        let b = ProjectBinding(projectId: UUID(), isDefault: true)
        let data = try JSONEncoder().encode(b)
        XCTAssertEqual(try JSONDecoder().decode(ProjectBinding.self, from: data), b)
    }
}

final class TemplateCodableTests: XCTestCase {
    func testRoundTripFromCanonicalJSON() throws {
        let json = """
            {
              "id": "11111111-2222-3333-4444-555555555555",
              "name": "Sales Call",
              "description": "outbound calls",
              "isBuiltIn": true,
              "version": "1.0.0",
              "forkedFrom": null,
              "systemPrompt": "you are a sales coach",
              "outputSections": ["Discovery", "Next Steps"],
              "modelRouteOverride": null,
              "knobs": {
                "tone": "conversational", "audience": "external",
                "quoteHandling": "verbatimForObjections",
                "actionItemFormat": "bulletedOwnerVerb",
                "cloudRouting": "useGlobal", "length": "standard"
              },
              "calendarMatchers": [{"kind": "titleRegex", "value": "(?i)demo"}],
              "projectBindings": [],
              "dynamicSections": false,
              "createdAt": 1748332800, "updatedAt": 1748332800
            }
            """.data(using: .utf8)!
        let t = try JSONDecoder().decode(Template.self, from: json)
        XCTAssertEqual(t.name, "Sales Call")
        XCTAssertEqual(t.calendarMatchers.count, 1)
        let re = try JSONDecoder().decode(Template.self, from: try JSONEncoder().encode(t))
        XCTAssertEqual(re, t)
    }

    func testClonedSetsForkedFromAndClearsBuiltIn() {
        let o = Template.makeBuiltIn(
            id: UUID(), name: "X", description: "",
            systemPrompt: "p", outputSections: []
        )
        let c = o.cloned()
        XCTAssertFalse(c.isBuiltIn)
        XCTAssertEqual(c.forkedFrom, o.id)
        XCTAssertNotEqual(c.id, o.id)
        XCTAssertEqual(c.name, "X (Custom)")
    }

    func testClonedAvoidsDoubleSuffix() {
        let o = Template.makeBuiltIn(
            id: UUID(), name: "X (Custom)", description: "",
            systemPrompt: "p", outputSections: []
        )
        XCTAssertEqual(o.cloned().name, "X (Custom)")
    }

    func testMakeBuiltInDefaults() {
        let t = Template.makeBuiltIn(
            id: UUID(), name: "X", description: "",
            systemPrompt: "p", outputSections: ["A"]
        )
        XCTAssertTrue(t.isBuiltIn)
        XCTAssertNil(t.forkedFrom)
        XCTAssertEqual(t.knobs, .default)
        XCTAssertEqual(t.version, SemVer("1.0.0")!)
    }
}
