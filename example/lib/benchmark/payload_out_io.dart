import 'dart:io';

/// Payload-line emitter that never word-wraps: the console relay
/// truncates a wrapped line, so every payload line must be written as
/// one whole write (stdout.writeln; dart:core print can split long
/// lines mid-content on the VM CLI).
void payloadOut(String line) => stdout.writeln(line);
