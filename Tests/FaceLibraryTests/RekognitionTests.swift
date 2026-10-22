import XCTest
@testable import FaceLibrary

final class RekognitionTests: XCTestCase {
    /// "get-vanilla" from the AWS Signature V4 test suite.
    func testSigV4MatchesAWSTestSuite() {
        let creds = AWSCredentials(accessKeyId: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
        let date = ISO8601DateFormatter().date(from: "2015-08-30T12:36:00Z")!
        let h = SigV4.sign(method: "GET", url: URL(string: "https://example.amazonaws.com/")!, headers: [:], body: Data(),
                           service: "service", region: "us-east-1", credentials: creds, date: date)
        XCTAssertEqual(h["Authorization"], "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    }

    func testCentralFacePicksTheFaceWeAskedAbout() {
        let edge = Celebrity(name: "Edge", id: "1", confidence: 99, urls: [], box: CGRect(x: 0.0, y: 0.0, width: 0.2, height: 0.2))
        let centre = Celebrity(name: "Centre", id: "2", confidence: 95, urls: [], box: CGRect(x: 0.35, y: 0.3, width: 0.3, height: 0.35))
        XCTAssertEqual(CelebrityNamer.centralFace([edge, centre])?.name, "Centre")
        XCTAssertNil(CelebrityNamer.centralFace([edge]))
    }

    func testParseResponse() {
        let json: [String: Any] = ["CelebrityFaces": [["Name": "Mỹ Tâm", "Id": "abc", "MatchConfidence": 99.2,
                                                         "Urls": ["www.wikidata.org/wiki/Q1"],
                                                         "Face": ["BoundingBox": ["Left": 0.3, "Top": 0.25, "Width": 0.4, "Height": 0.5]]]]]
        let c = RekognitionClient.parse(json)
        XCTAssertEqual(c.first?.name, "Mỹ Tâm")
        XCTAssertEqual(c.first?.box.midX ?? 0, 0.5, accuracy: 1e-9)
    }
}
