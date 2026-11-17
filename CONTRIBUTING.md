# Contributing

Keep changes scoped to the documented scenario. Avoid widening accepted registry values or bypassing filter checks just to make an incompatible system pass.

Run the build and offline tests in Windows PowerShell 5.1. Native code uses x64 layouts; verify any layout changes before calling the corresponding API. Tests must not apply the workaround to a CI runner.

For compatibility reports, include Windows build, GPU models, driver versions, power source, Task Manager update mode, before/after System CPU, whether a graphics/sensor tool was open, and behavior after a restart. State when a value is an observation rather than a verified physical power state.

Do not post raw kernel dumps, credentials, installation IDs, complete private logs or unredacted security descriptors. Share a small redacted result when relevant.
