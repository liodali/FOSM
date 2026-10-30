// Host OS identity with a web fallback: the IO build reports
// Platform.operatingSystem(-Version), the web build reports "web".
// Selected at compile time.
export 'host_identity_stub.dart' if (dart.library.io) 'host_identity_io.dart';
