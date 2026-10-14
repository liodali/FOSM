import 'dart:io';

Future<String> createCacheDirectory() async =>
    (await Directory.systemTemp.createTemp('fosm_disk_policy_')).path;

Future<void> removeCacheDirectory(String path) =>
    Directory(path).delete(recursive: true);
