// Web fallback: stdout is a dart:io concept (needs conditional
// dart.library.io); the browser console via print carries chunked
// payload lines whole.
// ignore: avoid_print
void payloadOut(String line) => print(line);
