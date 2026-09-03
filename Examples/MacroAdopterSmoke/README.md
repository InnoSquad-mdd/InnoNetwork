# Macro Adopter Smoke

This independent Swift package exercises the macro-first path through the
same public products available to an application and its test target. It does
not use `@testable import`, package access, or implementation-only hooks.

The executable declares explicit endpoint structs with `@APIDefinition`, then
sends them through `DefaultNetworkClient` backed by the public
`InnoNetworkTestSupport` session. Its runtime assertions cover:

- path placeholder and GET query encoding;
- POST JSON body inference and response decoding;
- explicit anonymous and required authentication policies;
- protocol-composed endpoint metadata matching production catalog usage;
- bearer-token application before the required-auth transport attempt.

Run it from the repository root:

```bash
xcrun swift run --package-path Examples/MacroAdopterSmoke
```

CI, release validation, and local preflight execute this command in addition
to compiling every independent example package.
