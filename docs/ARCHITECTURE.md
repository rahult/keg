# Keg Architecture

## Integration Patterns

### Hub-and-Spoke
`ContainerBridge` acts as central hub — all container operations flow through it.

### Event-Driven
`ComposeOrchestrator` watches container events for state reconciliation.

### Auth Abstraction
```swift
protocol AuthHandler {
    func authenticate(request: inout HTTPRequest) async throws -> AuthContext
}
```

Supports: Bearer token, API key, Container identity.

## See Also
- Full research: `outputs/.plans/architecture-research.md`

## External References
- Nango (embedded iPaaS): `outputs/.plans/nango-research.md`
- Integration patterns: `outputs/.plans/architecture-research.md`
