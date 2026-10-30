// Resident-memory probe with a web fallback: the IO build reports the
// process RSS, the web build reports 0 (browser tabs expose no
// per-tab RSS to Dart). Selected at compile time.
export 'process_memory_stub.dart' if (dart.library.io) 'process_memory_io.dart';
