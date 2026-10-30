import 'dart:io';

/// Resident set size of the current process (posix builds only).
int processRssBytes() => ProcessInfo.currentRss;
