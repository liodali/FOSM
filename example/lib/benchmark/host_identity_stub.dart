// Web fallback for the IO build: browsers report "web" as the host
// identity; a precise per-browser version belongs to the runtime
// (!$) and is out of scope for the report's META line.
String osName() => 'web';
String osVersion() => 'browser';
