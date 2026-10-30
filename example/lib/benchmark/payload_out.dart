// Payload-line writer with a web fallback: the IO build writes with
// stdout.writeln (print can split long lines on the VM CLI); web keeps
// print. Selected at compile time.
export 'payload_out_stub.dart' if (dart.library.io) 'payload_out_io.dart';
