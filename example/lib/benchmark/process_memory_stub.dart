// Conditional web fallback for the IO build: RSS is a posix process
// concept and browsers do not expose per-tab resident memory from Dart.
// The report treats a 0 value as "not recorded".
int processRssBytes() => 0;
