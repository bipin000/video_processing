import 'dart:async';

import 'package:flutter/services.dart';

typedef void ProgressStreamInitCallback(Stream<double> progressStream);
typedef void ProgressCallback(double progress);

class VideoProcessSettings {
  final Duration start;
  final Duration end;
  final double speed;

  VideoProcessSettings({this.start, this.end, this.speed});

  get asMap => {'start': start.inMilliseconds, 'end': end.inMilliseconds, 'speed': speed};
}

class VideoProcessing {
  static const MethodChannel _channel = const MethodChannel('video_processing');

  static Map<String, StreamController<double>> _taskProgressControllers;

  static Map<String, StreamController<double>> get taskProgressControllers {
    if (_taskProgressControllers == null) {
      _taskProgressControllers = {};
      _channel.setMethodCallHandler((MethodCall call) async {
        if (call.method == 'updateProgress') {
          String taskId = call.arguments['taskId'];
          double progress = call.arguments['progress'] ?? 0.0;
          _taskProgressControllers[taskId].add(progress);
          if (progress < 0.0 || progress >= 1.0) _taskProgressControllers.remove(taskId).close();
        }
      });
    }
    return _taskProgressControllers;
  }

  static Stream<double> progressStream({taskId: String}) =>
      taskProgressControllers[taskId]?.stream;

  static Future<String> processVideo(
      {String inputPath,
      String outputPath,
      List<VideoProcessSettings> settings,
      ProgressStreamInitCallback onProgressStreamInitialized}) {
    final taskId = outputPath;
    if (taskProgressControllers[taskId] != null) {
      onProgressStreamInitialized(progressStream(taskId: taskId));
      return Future.value(taskId);
    }
    taskProgressControllers[taskId] = StreamController.broadcast();
    onProgressStreamInitialized(progressStream(taskId: taskId));
    final settingsMap = settings.map((s) => s.asMap).toList();
    return _channel.invokeMethod('processVideo', [inputPath, outputPath, settingsMap]);
  }

  @deprecated
  static Future<String> generateVideo(
      List<String> paths, String filename, int fps, double speed) async {
    return await _channel.invokeMethod('generateVideo', [paths, filename, fps, speed]);
  }
}
