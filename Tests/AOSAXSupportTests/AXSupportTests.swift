import Testing
import Foundation
import ApplicationServices
@testable import AOSAXSupport

@Suite("AOSAXSupport — _AXUIElementGetWindow shim")
struct AXSupportTests {

    /// Calling the SPI on an application element (which is not a window) is
    /// expected to return non-success. Asserting "doesn't crash + returns
    /// nil" is enough — we just need to prove the dynamic symbol resolves
    /// and the calling convention is sane. A real windowId test would
    /// require AX permission against another process and is out of scope
    /// for unit tests.
    @Test("Calling on a non-window element returns nil without crashing")
    func nonWindowElementReturnsNil() {
        let app = AXUIElementCreateApplication(getpid())
        let id = axWindowID(for: app)
        // Application element doesn't have a CGWindowID — expect nil.
        #expect(id == nil)
    }
}
