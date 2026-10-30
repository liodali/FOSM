import 'dart:io';

/// OS family reported by the posix build (e.g. `ios`/`android`/`macos`).
String osName() => Platform.operatingSystem;

/// OS version string from the platform (undefined format by design).
String osVersion() => Platform.operatingSystemVersion;
