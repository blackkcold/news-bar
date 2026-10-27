import XCTest
@testable import NewsBar

final class PublicURLPolicyTests: XCTestCase {
    func testAllowsPublicHTTPS() {
        XCTAssertNotNil(SecurityPolicies.validatePublicHTTPURL("https://www.reuters.com/story").url)
        XCTAssertNotNil(SecurityPolicies.validatePublicHTTPURL("https://8.8.8.8/story").url)
        XCTAssertNotNil(SecurityPolicies.validatePublicHTTPURL("https://[2001:4860:4860::8888]/story").url)
    }

    func testRejectsNonHTTPSAndCredentialsAndPorts() {
        XCTAssertTrue(SecurityPolicies.validatePublicHTTPURL("http://www.reuters.com/story").isBlocked)
        XCTAssertTrue(SecurityPolicies.validatePublicHTTPURL("https://user:pass@www.reuters.com/story").isBlocked)
        XCTAssertTrue(SecurityPolicies.validatePublicHTTPURL("https://www.reuters.com:8443/story").isBlocked)
        XCTAssertTrue(SecurityPolicies.validatePublicHTTPURL("https://www.reuters.com:443/story").url != nil)
    }

    func testRejectsLocalHosts() {
        for host in [
            "https://localhost/story",
            "https://app.local/story",
            "https://intranet/story",
            "https://router.home.arpa/story",
        ] {
            XCTAssertTrue(SecurityPolicies.validatePublicHTTPURL(host).isBlocked, host)
        }
    }

    func testRejectsPrivateAndReservedIPv4() {
        for host in [
            "https://10.0.0.1/story",
            "https://127.0.0.1/story",
            "https://169.254.1.1/story",
            "https://172.16.0.1/story",
            "https://192.168.1.1/story",
            "https://100.64.0.1/story",
            "https://224.0.0.1/story",
            "https://255.255.255.255/story",
            "https://192.0.2.10/story",
        ] {
            XCTAssertTrue(SecurityPolicies.validatePublicHTTPURL(host).isBlocked, host)
        }
    }

    func testRejectsPrivateIPv6() {
        for host in [
            "https://[::1]/story",
            "https://[fc00::1]/story",
            "https://[fd12:3456::1]/story",
            "https://[fe80::1]/story",
            "https://[ff02::1]/story",
            "https://[2001:db8::1]/story",
        ] {
            XCTAssertTrue(SecurityPolicies.validatePublicHTTPURL(host).isBlocked, host)
        }
    }

    func testAddressClassification() {
        XCTAssertTrue(PublicAddressPolicy.isPublicAddress("93.184.216.34"))
        XCTAssertFalse(PublicAddressPolicy.isPublicAddress("192.168.0.10"))
        XCTAssertFalse(PublicAddressPolicy.isPublicAddress("10.1.2.3"))
        XCTAssertFalse(PublicAddressPolicy.isPublicAddress("::1"))
        XCTAssertFalse(PublicAddressPolicy.isPublicAddress("fe80::1%en0"))
        XCTAssertTrue(PublicAddressPolicy.isPublicAddress("2606:4700:4700::1111"))
        XCTAssertFalse(PublicAddressPolicy.isPublicAddress("not-an-ip"))
    }

    func testRejectsUncompressedIPv6LoopbackAndIPv4MappedForms() {
        for host in [
            "https://[0:0:0:0:0:0:0:1]/story",
            "https://[0:0:0:0:0:0:0:0]/story",
            "https://[0:0:0:0:0:ffff:7f00:1]/story",
            "https://[0:0:0:0:0:ffff:8.8.8.8]/story",
            "https://[::ffff:127.0.0.1]/story",
        ] {
            XCTAssertTrue(SecurityPolicies.validatePublicHTTPURL(host).isBlocked, host)
        }
    }

    func testRejectsTransitionAndSiteLocalIPv6() {
        for host in [
            "https://[64:ff9b::7f00:1]/story",
            "https://[64:ff9b::808:808]/story",
            "https://[fec0::1]/story",
            "https://[2001::1]/story",
            "https://[2002:7f00:1::1]/story",
            "https://[3fff::1]/story",
        ] {
            XCTAssertTrue(SecurityPolicies.validatePublicHTTPURL(host).isBlocked, host)
        }
    }

    func testRejectsAmbiguousNumericHosts() {
        for host in [
            "https://010.0.0.1/story",
            "https://0177.0.0.1/story",
            "https://0x7f.0.0.1/story",
        ] {
            XCTAssertTrue(SecurityPolicies.validatePublicHTTPURL(host).isBlocked, host)
        }
    }

    func testAllowsGlobalUnicastIPv6() {
        for host in [
            "https://[2001:4860:4860::8888]/story",
            "https://[2606:4700:4700::1111]/story",
            "https://[2a00:1450:4001:80f::200e]/story",
        ] {
            XCTAssertNotNil(SecurityPolicies.validatePublicHTTPURL(host).url, host)
        }
    }
}
