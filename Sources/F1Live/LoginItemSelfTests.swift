import ServiceManagement

// These checks also run without Xcode's test runner. The fake never changes login items.
@MainActor
enum LoginItemSelfTests {
    static func run() throws {
        let service = FakeLoginItemService()
        let controller = LoginItemController(service: service, isAppBundle: true)
        try check(!controller.isEnabled && service.registerCalls == 0, "login item is not enabled on first launch")
        service.status = .enabled
        let reopened = LoginItemController(service: service, isAppBundle: true)
        try check(reopened.isEnabled && service.registerCalls == 0, "existing login preference is preserved")

        service.status = .notRegistered
        controller.setEnabled(true)
        controller.setEnabled(true)
        try check(controller.isEnabled && service.registerCalls == 1, "register login item only once")
        controller.setEnabled(false)
        controller.setEnabled(false)
        try check(!controller.isEnabled && service.unregisterCalls == 1, "unregister login item only once")

        service.status = .enabled
        controller.refreshStatus()
        try check(controller.isEnabled, "reflect external login-item enablement")
        service.status = .requiresApproval
        controller.refreshStatus()
        try check(!controller.isEnabled && controller.requiresApproval, "reflect revoked login-item approval")

        service.registrationStatus = .requiresApproval
        controller.setEnabled(true)
        try check(controller.requiresApproval && !controller.isEnabled, "pending approval is not shown as enabled")
        controller.openSystemSettings()
        try check(service.openSettingsCalls == 1, "open login-item approval settings")

        service.status = .notRegistered
        service.registrationStatus = .enabled
        service.failRegistration = true
        controller.setEnabled(true)
        try check(!controller.isEnabled && controller.errorMessage != nil, "failed registration retains actual state and explains error")
        service.failRegistration = false
        controller.setEnabled(true)
        try check(controller.isEnabled && controller.errorMessage == nil, "registration can be retried")

        service.failUnregistration = true
        controller.setEnabled(false)
        try check(controller.isEnabled && controller.errorMessage != nil, "failed unregistration keeps toggle enabled")
        service.failUnregistration = false
        controller.setEnabled(false)
        try check(!controller.isEnabled && controller.errorMessage == nil, "unregistration can be retried")

        service.status = .requiresApproval
        service.failRegistration = true
        controller.setEnabled(true)
        try check(controller.requiresApproval && controller.errorMessage == nil, "approval guidance replaces launch-denied error")
        controller.setEnabled(false)
        try check(controller.status == .notRegistered, "pending registration can be removed")
        service.status = .notFound
        controller.refreshStatus()
        try check(!controller.isEnabled && controller.isAvailable, "first registration is available when service is not yet found")
        service.failRegistration = false
        controller.setEnabled(true)
        try check(controller.isEnabled, "main app can register from not-found state")

        let unavailableService = FakeLoginItemService()
        unavailableService.status = .enabled
        let unavailable = LoginItemController(service: unavailableService, isAppBundle: false)
        unavailable.setEnabled(true)
        unavailable.setEnabled(false)
        unavailable.openSystemSettings()
        try check(!unavailable.isAvailable && !unavailable.isEnabled, "unbundled executable disables login setting")
        try check(unavailableService.registerCalls == 0 && unavailableService.unregisterCalls == 0 && unavailableService.openSettingsCalls == 0, "unbundled executable never changes login items")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        if !condition() { throw SelfTestError.failed(label) }
    }
}

@MainActor
private final class FakeLoginItemService: LoginItemServicing {
    var status: SMAppService.Status = .notRegistered
    var registrationStatus: SMAppService.Status = .enabled
    var failRegistration = false
    var failUnregistration = false
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0
    private(set) var openSettingsCalls = 0

    func register() throws {
        registerCalls += 1
        if failRegistration { throw SelfTestError.failed("Simulated registration failure") }
        status = registrationStatus
    }

    func unregister() throws {
        unregisterCalls += 1
        if failUnregistration { throw SelfTestError.failed("Simulated unregistration failure") }
        status = .notRegistered
    }

    func openSystemSettings() { openSettingsCalls += 1 }
}
