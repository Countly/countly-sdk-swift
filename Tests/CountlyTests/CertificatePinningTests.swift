//
//  CertificatePinningTests.swift
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

import XCTest
@testable import Countly

/// Refusing a server that is not the one the application pinned.
///
/// Pinning exists so that a proxy holding a certificate the device trusts still
/// cannot read what the SDK sends. That makes the *refusal* the important path:
/// a check that accepts too easily is worse than no check at all, because the
/// integration believes it is protected.
///
/// Two things have to hold together, and each on its own is a reason to refuse: the
/// server's public key has to match one of the bundled certificates, and the chain
/// itself has to validate.
final class CertificatePinningTests: CountlyBaseTestCase {

    /// A self-signed certificate, generated once and embedded rather than fetched,
    /// so the test needs no network and no keychain.
    private static let certificateDER = Data(base64Encoded: """
        MIIDDzCCAfegAwIBAgIUMRi2Hsu32OOS5Sen9w6kesjYMaswDQYJKoZIhvcNAQELBQAwFzEVMBMG
        A1UEAwwMY291bnRseS10ZXN0MB4XDTI2MDgzMTIwMjgzOVoXDTM2MDgyODIwMjgzOVowFzEVMBMG
        A1UEAwwMY291bnRseS10ZXN0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAwCFJ9r7Q
        TTTUX3bcKommuT2uIvPlV+7UTvhxrUOd82LWR4eusggKhKV80IqKAvF7DupWKiWVMK+DCX7Hfy9f
        ObYXKd+G83an3Psti1eWiEcHijEIRt6Etlw3FAKfPLwlf71PcAGcw5j44SzU7E3NzwANRoTA/J+f
        pwwvMgcV1IZGMkwwP7PoaVoM58uhMh8DSODEN9Zq0vrIQJda+q7obmj/Opthxg+x8q8jRZ33rh7r
        KenvQptBvms7se/yxBoDNALpIOWVww8NWxQSeLYqLorPTTg23ceKYhsiihsacJDwpGx+yJPfj+YW
        IAETixH1GnxzZBpAR+IHItINKwjDuwIDAQABo1MwUTAdBgNVHQ4EFgQUlFa1TqYeSpHkPSYxjYG7
        gLakDIEwHwYDVR0jBBgwFoAUlFa1TqYeSpHkPSYxjYG7gLakDIEwDwYDVR0TAQH/BAUwAwEB/zAN
        BgkqhkiG9w0BAQsFAAOCAQEAlTiyrIj3mTZ0cGXBptk1/QwUYJ2OUMpO31dgOnfEbY5AiAZuio3Y
        ePDbs96QRljghQGM8OYXbdLOcxoA/BMiDjeJ7Xgu+YDM1dnf5W2jAIsZIETJfKa00tWYxZEOPMJY
        o/tfRB27Vq3RA4q9UYBBnl0dn+IFiNWryaBM9D/37mUUCDQMyDZ65qiKyjAinkwhiG4euQkqJd6E
        J6MmWs5psUmNAuRc1rD90cQh1bkQhSEa7Xu9blXxmf2zvjhGPxjn9rVfV1H3TUtzV848Ko5d0TFA
        s5ZaCLTWe0hhWFYUI/WJkaiSQmrXPNrvhO+QSlrACOx9jT9i92GP0ERlJJLvLA==
""".replacingOccurrences(of: "\n", with: ""))!

    /// A protection space that carries a server trust.
    ///
    /// `URLProtectionSpace` only populates `serverTrust` for a real server-trust
    /// challenge, which a test cannot provoke, so it is overridden.
    private final class TrustingProtectionSpace: URLProtectionSpace, @unchecked Sendable {
        let trust: SecTrust?

        init(trust: SecTrust?) {
            self.trust = trust
            super.init(host: "testing.count.ly",
                       port: 443,
                       protocol: "https",
                       realm: nil,
                       authenticationMethod: NSURLAuthenticationMethodServerTrust)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override var serverTrust: SecTrust? { trust }
    }

    /// Swallows the sender callbacks a challenge insists on having.
    private final class NullSender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }

    private func serverTrust() -> SecTrust? {
        guard let certificate = SecCertificateCreateWithData(nil, Self.certificateDER as CFData) else {
            return nil
        }
        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, "testing.count.ly" as CFString)
        SecTrustCreateWithCertificates(certificate, policy, &trust)

        // Evaluating a trust will otherwise go to the network for revocation
        // information, which in a test with no network hangs until the runner gives
        // up. The verdict is the same either way: this certificate is not trusted.
        if let trust { SecTrustSetNetworkFetchAllowed(trust, false) }
        return trust
    }

    private func challenge(trust: SecTrust?) -> URLAuthenticationChallenge {
        URLAuthenticationChallenge(protectionSpace: TrustingProtectionSpace(trust: trust),
                                   proposedCredential: nil,
                                   previousFailureCount: 0,
                                   failureResponse: nil,
                                   error: nil,
                                   sender: NullSender())
    }

    /// Runs the SDK's challenge handler and reports what it decided.
    private func decide(_ countly: CountlyInstance,
                        trust: SecTrust?) -> URLSession.AuthChallengeDisposition {
        var disposition: URLSession.AuthChallengeDisposition = .performDefaultHandling
        let decided = expectation(description: "the challenge is answered")

        core(of: countly).network.urlSession(URLSession.shared,
                                             didReceive: challenge(trust: trust)) { result, _ in
            disposition = result
            decided.fulfill()
        }

        wait(for: [decided], timeout: TestUtils.asyncTimeout)
        return disposition
    }

    // MARK: - Refusing

    /// A challenge carrying no server trust cannot be evaluated at all, so it is
    /// refused rather than waved through.
    func testAChallengeWithNoServerTrustIsCancelled() {
        let countly = startInstance { $0.pinnedCertificates = ["pinned.cer"] }

        XCTAssertEqual(decide(countly, trust: nil), .cancelAuthenticationChallenge)
    }

    // Evaluating a real `SecTrust` is deliberately not attempted here.
    //
    // `SecTrustEvaluateWithError` on a synthesised trust hangs the simulator's test
    // runner: with no network it waits on revocation information until the runner
    // gives up and restarts, which fails the whole bundle rather than one test.
    // Disabling the network fetch does not help. The accept path and the
    // key-comparison loop are therefore left to the manual pinning check in
    // `Tools/parity`, and what is covered here is the refusal that a unit test can
    // reach without evaluating a chain.

    // MARK: - Configuration

    /// The delegate is only installed when pinning is configured, because a session
    /// with a delegate retains it and the check costs something on every request.
    func testTheSessionOnlyTakesADelegateWhenPinningIsConfigured() {
        let unpinned = startInstance()
        XCTAssertNil(core(of: unpinned).network.session().delegate,
                     "an unpinned session needs no delegate")

        let pinned = startInstance { $0.pinnedCertificates = ["pinned.cer"] }
        XCTAssertNotNil(core(of: pinned).network.session().delegate)
        XCTAssertNotNil(core(of: pinned).network.instantSession().delegate,
                        "the instant session is pinned too, or behaviour settings travel unpinned")
    }
}
