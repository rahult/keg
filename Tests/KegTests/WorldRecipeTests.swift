import XCTest
@testable import Keg

final class WorldRecipeTests: XCTestCase {

    private let validKegYAML = """
    name: demo
    services:
      web:
        image: nginx:alpine
        ports:
          - "8080:80"
    """

    private func recipe(
        url: String = "https://github.com/example/demo.git",
        kegYAML: String? = nil,
        env: [String: String] = [:],
        databases: [String] = []
    ) -> WorldRecipe {
        WorldRecipe(
            repo: RepoRef(url: url, branch: "main", commit: "abc123"),
            kegYAML: kegYAML ?? validKegYAML,
            env: env,
            databases: databases
        )
    }

    // MARK: - Validation

    func testValidateAcceptsWellFormedRecipe() throws {
        XCTAssertNoThrow(try recipe().validate())
    }

    func testValidateRejectsEmptyRepoURL() {
        XCTAssertThrowsError(try recipe(url: "").validate()) { error in
            guard case WorldRecipeError.emptyRepo = error else {
                return XCTFail("expected .emptyRepo, got \(error)")
            }
        }
    }

    func testValidateRejectsUnparseableKegYAML() {
        XCTAssertThrowsError(try recipe(kegYAML: "::: not yaml :::").validate()) { error in
            guard case WorldRecipeError.invalidKegYAML = error else {
                return XCTFail("expected .invalidKegYAML, got \(error)")
            }
        }
    }

    func testValidateRejectsKegYAMLWithNoServices() {
        XCTAssertThrowsError(try recipe(kegYAML: "name: demo\n").validate()) { error in
            guard case WorldRecipeError.invalidKegYAML = error else {
                return XCTFail("expected .invalidKegYAML, got \(error)")
            }
        }
    }

    func testValidateRejectsSecretLookingEnvKeys() {
        // Recipes get pushed to the cloud — secrets are never part of the world.
        for key in ["API_TOKEN", "DB_PASSWORD", "AWS_SECRET_ACCESS_KEY", "STRIPE_KEY"] {
            XCTAssertThrowsError(try recipe(env: [key: "hunter2"]).validate()) { error in
                guard case WorldRecipeError.secretEnvKey(let offending) = error else {
                    return XCTFail("expected .secretEnvKey, got \(error)")
                }
                XCTAssertEqual(offending, key)
            }
        }
    }

    func testValidateAcceptsPlainEnvKeys() throws {
        XCTAssertNoThrow(try recipe(env: ["NODE_ENV": "production", "LOG_LEVEL": "debug"]).validate())
    }

    // MARK: - keg.yaml round-trip through the project parser

    func testKegYAMLParsesWithProjectLoaderAfterValidation() throws {
        let r = recipe()
        try r.validate()
        let config = try r.parsedKegYAML()
        XCTAssertEqual(config.name, "demo")
        XCTAssertEqual(config.services["web"]?.image, "nginx:alpine")
    }

    // MARK: - Codable

    func testCodableRoundTrip() throws {
        let r = recipe(env: ["NODE_ENV": "test"], databases: ["postgres:demodb"])
        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(WorldRecipe.self, from: data)
        XCTAssertEqual(decoded, r)
    }

    func testRepoRefCodableRoundTrip() throws {
        let ref = RepoRef(url: "git@github.com:example/demo.git", branch: "dev", commit: "deadbeef")
        let data = try JSONEncoder().encode(ref)
        XCTAssertEqual(try JSONDecoder().decode(RepoRef.self, from: data), ref)
    }
}
