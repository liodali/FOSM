// Vector zoom-softness diagnostic (retained-scale bypass, vector-only).
//
// Isolates the softness observed while zooming a vector map under the
// plan-13 Phase B retained-scale grid: between recaptures the compositor
// stretches the captured raster (rasterized at the captured pose), while
// a live repaint resamples each tile bitmap once at the live pose. This
// suite runs the SAME trajectory and pose through both arms and reports
// visual sharpness plus grid-paint frame cost:
//
//   retained arm  — shipped behavior (`fosm.vectorRetainedScale=true`):
//                   vector grid keeps the retained-scale compositor path.
//   bypass arm    — `fosm.vectorRetainedScale=false`: vector payloads
//                   repaint the grid at the live pose (plan-12 translate-
//                   only capture); raster payloads are unaffected (the
//                   raster regression test proves that directly).
//
// Gestures compared, both with the prepared zoom window at its shipped
// default (enabled) and fractional zoom on:
//   pinch — a real two-pointer spread driving `_applyScaleUpdate` →
//           `_applyContinuousZoom`, held mid-gesture at the measurement
//           pose (pointers stay down through the capture);
//   wheel — a real `PointerScrollEvent` through `_onPointerSignal` →
//           `_setContinuousZoom` (animateZoom off for a deterministic
//           landing on the same pose; the eased wheel shares the camera
//           path and the same retained-scale trade-off per frame).
//
// Trajectory 13.8 → 14.4 stays inside grid z14 (no source-zoom switch, no
// membership change, no strict-viewport arrivals after settle), so the
// retained capture taken at the start pose (zoomScale 0.76 cells) persists
// to the measurement pose — its compositor ratio is 2^0.6 ≈ 1.52, while
// the bypass arm resamples each tile bitmap once at the live zoomScale
// 1.52. The settled cameraZoom-14.0 pose (zoomScale exactly 1.0, no
// resampling) is each run's sharp reference.
//
// Sharpness metric: variance of the 4-neighbour Laplacian over the centre
// crop of a repaint-boundary capture (higher = sharper edges). Both arms
// also dump PNGs of the measurement pose to `build/vector_zoom_diag/` for
// visual inspection.
//
// Findings (this suite, 2026-11): bypassing retained scaling does NOT
// improve sharpness — both arms resample the same 256 px tile bitmaps once
// at the live scale, so the zoomed-pose Laplacian is identical (≈2000,
// ×0.270 of the zoomScale-1.0 reference) while the bypass repaints the
// grid every driven frame (≈600 µs CPU each). The softness is dominated by
// tile-image resolution: rendering tiles at 512 px (see the res512 arm and
// `fosm.vectorTileResolution`) nearly doubles zoomed-pose sharpness
// (×0.523 of reference) at 4× imagery memory and zero extra paints. The
// retained-scale compositor resample itself can only be observed on a
// real device raster cache — settle that with the example benchmark
// harness (`fosm.vectorRetainedScale=false` paired captures).
//
// Frame-cost metrics (paint side; raster/compositor cost is not observable
// in the test rasterizer — device A/B runs use the example benchmark
// harness): `RenderCanvasOSM.debugPaintCount` delta over the drive, paints
// per drawn frame, `paint.grid` span percentiles (span log enabled for
// both arms identically), `debugGridRecaptures` deltas and the rendered
// imagery bytes from the memory attribution.
//
// The suite prints its findings; it asserts only switch behavior (which
// arm repaints during the drive) and pose fairness, never which arm is
// sharper — that outcome is the measurement.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import 'package:fosm/fosm.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fosm/src/view/render.dart' show RenderCanvasOSM;
import 'package:fosm/src/vector/render/vector_tile_runtime.dart'
    show VectorTileRuntime;
import '../vector/mvt_builder.dart';

/// Undoes flutter_test's `_MockHttpOverrides` (which makes every
/// HttpClient return 400 without touching the network) so the map's dio
/// transport can reach the loopback fixture server. Zone-independent:
/// assignment order against the binding init does not matter.
class _RealHttpOverrides extends HttpOverrides {}

// ── Fixture: style + deterministic high-frequency vector tiles ───────────

const _viewportSide = 400.0;
const _startZoom = 13.8;
const _measureZoom = 14.4;
const _zoomTolerance = 0.005;
const _centre = Offset(_viewportSide / 2, _viewportSide / 2);

/// Thin high-contrast lines every 16 logical px at zoomScale 1: enough
/// edges for the Laplacian metric to discriminate resampling quality.
Uint8List _tileBytes() {
  const extent = 4096;
  const spacing = 256; // extent units → 16 screen px at zoomScale 1.
  final builder = MvtBuilder();

  final dark = <TestFeature>[];
  final light = <TestFeature>[];
  for (var k = 0; k * spacing + 64 <= extent; k++) {
    final darkCoord = k * spacing + 64;
    final lightCoord = k * spacing + 192;
    dark.add(TestFeature(
        type: TestGeomType.lineString,
        geometryCommands: lineCommands([(0, darkCoord), (extent, darkCoord)])));
    dark.add(TestFeature(
        type: TestGeomType.lineString,
        geometryCommands: lineCommands([(darkCoord, 0), (darkCoord, extent)])));
    light.add(TestFeature(
        type: TestGeomType.lineString,
        geometryCommands:
            lineCommands([(0, lightCoord), (extent, lightCoord)])));
    light.add(TestFeature(
        type: TestGeomType.lineString,
        geometryCommands:
            lineCommands([(lightCoord, 0), (lightCoord, extent)])));
  }
  builder.addLayer(name: 'lines-dark', extent: extent, features: dark);
  builder.addLayer(name: 'lines-light', extent: extent, features: light);
  return builder.build();
}

final Uint8List _sharedTileBytes = _tileBytes();

String _styleJson(String tilesBase) => jsonEncode({
      'version': 8,
      'sources': {
        'diag': {
          'type': 'vector',
          'tiles': ['$tilesBase/{z}/{x}/{y}.pbf'],
          'maxzoom': 14,
        },
      },
      'layers': [
        {
          'id': 'bg',
          'type': 'background',
          'paint': {'background-color': '#909090'},
        },
        {
          'id': 'dark',
          'type': 'line',
          'source': 'diag',
          'source-layer': 'lines-dark',
          'paint': {'line-color': '#181818', 'line-width': 1.6},
        },
        {
          'id': 'light',
          'type': 'line',
          'source': 'diag',
          'source-layer': 'lines-light',
          'paint': {'line-color': '#f2f2f2', 'line-width': 1.6},
        },
      ],
    });

HttpServer? _server;
late String _base;

Future<void> _startServer() async {
  _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  _base = 'http://127.0.0.1:${_server!.port}';
  _server!.listen((request) {
    if (request.uri.path == '/style.json') {
      request.response.headers.contentType = ContentType.json;
      request.response.add(utf8.encode(_styleJson(_base)));
      request.response.close();
      return;
    }
    request.response.headers.contentType =
        ContentType('application', 'octet-stream');
    request.response.add(_sharedTileBytes);
    request.response.close();
  });
}

// ── Measurement helpers ──────────────────────────────────────────────────

/// Counts drawn frames via a re-arming post-frame callback.
class _FrameCounter {
  int frames = 0;
  VoidCallback? _handle;
  bool _attached = false;

  void attach() {
    if (_attached) return;
    _attached = true;
    _handle = () {
      frames++;
      WidgetsBinding.instance.addPostFrameCallback((_) => _handle!());
    };
    WidgetsBinding.instance.addPostFrameCallback((_) => _handle!());
  }

  void reset() => frames = 0;
}

class _ArmResult {
  final String arm;
  final String gesture;
  final int tileResolution;
  final double poseZoom;
  final double sharpness;
  final double referenceSharpness;
  final int gridPaintsDuringDrive;
  final int framesDuringDrive;
  final int gridPaintsDuringHold;
  final int recapturesDuringDrive;
  final int recaptureScale;
  final int recaptureContent;
  final List<double> paintGridP50P95Max;
  final int renderedImageBytes;

  _ArmResult({
    required this.arm,
    required this.gesture,
    required this.tileResolution,
    required this.poseZoom,
    required this.sharpness,
    required this.referenceSharpness,
    required this.gridPaintsDuringDrive,
    required this.framesDuringDrive,
    required this.gridPaintsDuringHold,
    required this.recapturesDuringDrive,
    required this.recaptureScale,
    required this.recaptureContent,
    required this.paintGridP50P95Max,
    required this.renderedImageBytes,
  });

  double get sharpnessRatio => referenceSharpness == 0
      ? 0
      : sharpness / referenceSharpness;
}

final List<_ArmResult> _results = [];

/// Variance of the 4-neighbour Laplacian over the centre crop of [pixels]
/// (RGBA, row-major, [width]×[height]), crop side [crop].
double _laplacianVariance(Uint8List pixels, int width, int height,
    [int crop = 200]) {
  double lum(int index) {
    final j = index * 4;
    return 0.299 * pixels[j] + 0.587 * pixels[j + 1] + 0.114 * pixels[j + 2];
  }

  final x0 = (width - crop) ~/ 2;
  final y0 = (height - crop) ~/ 2;
  var sum = 0.0;
  var sumSq = 0.0;
  var count = 0;
  for (var y = y0 + 1; y < y0 + crop - 1; y++) {
    for (var x = x0 + 1; x < x0 + crop - 1; x++) {
      final centre = lum(x + y * width);
      final lap = 4 * centre -
          lum(x + (y - 1) * width) -
          lum(x + (y + 1) * width) -
          lum(x - 1 + y * width) -
          lum(x + 1 + y * width);
      sum += lap;
      sumSq += lap * lap;
      count++;
    }
  }
  if (count == 0) return 0;
  final mean = sum / count;
  return sumSq / count - mean * mean;
}

Future<(double sharpness, ui.Image image)> _captureAndMeasure(
    WidgetTester tester, GlobalKey boundaryKey) async {
  final boundary =
      boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  // toImage completes via real engine callbacks — must run inside a
  // real-async window (same as the golden-file capture path).
  final captured = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final bytes =
        await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    return (image, bytes);
  });
  final image = captured!.$1;
  final pixels = captured.$2!.buffer.asUint8List();
  return (_laplacianVariance(pixels, image.width, image.height), image);
}

Future<void> _dumpPng(WidgetTester tester, ui.Image image, String name) async {
  final png = await tester
      .runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
  // Everything around the engine call must be synchronous: async dart:io
  // futures never complete in the fake-async zone.
  final dir = Directory('${Directory.current.path}/build/vector_zoom_diag');
  dir.createSync(recursive: true);
  File('${dir.path}/$name.png')
      .writeAsBytesSync(png!.buffer.asUint8List(), flush: true);
}

/// Real-event-loop wait until every strict-viewport cell shows its own
/// current-zoom imagery (or the deadline passes). Alternates real async
/// windows (socket/isolate/raster progress) with fake-async pumps (frame
/// publication), per the map_loading_test pattern.
Future<bool> _waitForSharp(
  WidgetTester tester,
  MapController controller, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  FosmTileCoverage? coverage;
  while (DateTime.now().isBefore(deadline)) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    // pump with a duration: a duration-less pump only flushes the fake
    // microtask queue when a frame is already scheduled, so an async chain
    // that is itself waiting to complete (style load → runtime → grid)
    // would otherwise never resume.
    await tester.pump(const Duration(milliseconds: 16));
    coverage = controller.tileCoverage;
    if (coverage != null &&
        coverage.visibleCells > 0 &&
        coverage.sharpFraction >= 1) {
      return true;
    }
  }
  // ignore: avoid_print
  print('coverage at deadline: visible=${coverage?.visibleCells} '
      'sharp=${coverage?.sharpCells} covered=${coverage?.coveredCells}');
  return false;
}

/// Drives the pinch pair so the camera lands exactly on [targetZoom].
///
/// The recognizer reports the cumulative spread against the 80 px gesture
/// start, so the live camera is `13.8 + log2(spread / 80)`; the exact
/// per-pointer move follows from the current fractional zoom each step.
Future<void> _pinchTo(
  WidgetTester tester,
  TestGesture left,
  TestGesture right,
  MapController controller,
  double targetZoom,
) async {
  for (var i = 0; i < 40; i++) {
    final current = controller.fractionalZoom!;
    final delta = targetZoom - current;
    if (delta.abs() <= _zoomTolerance) return;
    final spreadNow = 80 * math.pow(2, current - _startZoom);
    final spreadTarget = 80 * math.pow(2, targetZoom - _startZoom);
    final perPointer = (spreadTarget - spreadNow) / 2;
    // Left pointer moves left, right pointer moves right (spread out); a
    // negative perPointer (fine-tuning an overshoot) moves them together.
    await left.moveBy(Offset(-perPointer, 0));
    await right.moveBy(Offset(perPointer, 0));
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _startPinch(
    WidgetTester tester, MapController controller) async {
  final left = await tester.startGesture(_centre - const Offset(40, 0));
  final right = await tester.startGesture(_centre + const Offset(40, 0));
  await tester.pump();
  await _pinchTo(tester, left, right, controller, _measureZoom);
  await tester.pump(const Duration(milliseconds: 16));
}

/// Sends one wheel event whose delta lands the camera on the measurement
/// zoom (animateZoom off ⇒ immediate application, same camera path the
/// eased wheel drives per animation tick).
Future<void> _wheelTo(WidgetTester tester) async {
  final pointer = TestPointer(1, PointerDeviceKind.mouse)..hover(_centre);
  final dy = (_startZoom - _measureZoom) * 100; // dy<0 zooms in.
  await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
  await tester.pump();
}

// ── The diagnostic run ───────────────────────────────────────────────────

Future<_ArmResult> _runVectorArm(
  WidgetTester tester, {
  required String arm,
  required String gesture,
  required bool bypass,
  required _FrameCounter frames,
  int tileResolution = 256,
}) async {
  MapView.vectorRetainedScaleEnabled = !bypass;
  MapView.gridRetainedScaleEnabled = true;
  VectorTileRuntime.resolution = tileResolution;
  addTearDown(() {
    MapView.vectorRetainedScaleEnabled = true;
    MapView.gridRetainedScaleEnabled = true;
    VectorTileRuntime.resolution = VectorTileRuntime.resolutionByDefine;
  });

  final controller = MapController();
  final boundaryKey = GlobalKey();

  tester.view.physicalSize = Size(_viewportSide * 3, _viewportSide * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: RepaintBoundary(
        key: boundaryKey,
        child: MapView(
          latLng: const LatLng(latitude: 0, longitude: 0),
          zoom: 14,
          fractionalZoom: _startZoom,
          enableFractionalZoom: true,
          enableScrollZoom: true,
          animateZoom: false,
          controller: controller,
          vectorStyle:
              VectorMapStyle(id: 'diag', styleUrl: '$_base/style.json'),
          showZoomControls: false,
          showScaleBar: false,
        ),
      ),
    ),
  ));

  expect(await _waitForSharp(tester, controller), isTrue,
      reason: 'fixture tiles must fully publish before the gesture');

  // Sharp reference: cameraZoom 14.0 ⇒ zoomScale exactly 1.0 (no
  // resampling anywhere). The retained-scale capture is NOT rebuilt for
  // this roundtrip (cameraZoom is not part of its identity), so the
  // gesture start pose below still carries the 13.8 capture in the
  // retained arm — matching a real gesture arriving mid-grid.
  controller.setFractionalZoom(14.0, animate: false);
  await tester.pump();
  final (referenceSharpness, referenceImage) =
      await _captureAndMeasure(tester, boundaryKey);
  await _dumpPng(tester, referenceImage, '${arm}_$gesture-reference');
  referenceImage.dispose();
  controller.setFractionalZoom(_startZoom, animate: false);
  await tester.pump();

  // ── Drive to the measurement pose ──
  final recapturesBefore = MapView.debugGridRecaptures.total;
  final recaptureScaleBefore = MapView.debugGridRecaptures.scale;
  final recaptureContentBefore = MapView.debugGridRecaptures.content;
  final paintsBefore = RenderCanvasOSM.debugPaintCount;
  VectorSpanLog.clear();
  frames.reset();

  if (gesture == 'pinch') {
    await _startPinch(tester, controller);
  } else {
    await _wheelTo(tester);
  }

  final paintsAfterDrive = RenderCanvasOSM.debugPaintCount;
  final framesDriven = frames.frames;
  final recapturesAfterDrive = MapView.debugGridRecaptures.total;
  final spans = VectorSpanLog.take()
      .where((span) => span.event == 'paint.grid')
      .map((span) => span.durationUs.toDouble())
      .toList()
    ..sort();
  double percentile(double q) => spans.isEmpty
      ? 0
      : spans[((spans.length - 1) * q).floor().clamp(0, spans.length - 1)];

  // ── Hold the measurement pose, then capture ──
  // Pinch keeps its pointers down (mid-gesture); wheel has no held state.
  VectorSpanLog.clear();
  final paintsBeforeHold = RenderCanvasOSM.debugPaintCount;
  await tester.pump(const Duration(milliseconds: 16));
  await tester.pump(const Duration(milliseconds: 16));
  final paintsAfterHold = RenderCanvasOSM.debugPaintCount;

  final poseZoom = controller.fractionalZoom!;
  final (sharpness, image) = await _captureAndMeasure(tester, boundaryKey);
  await _dumpPng(tester, image, '${arm}_$gesture');

  expect(poseZoom, closeTo(_measureZoom, _zoomTolerance * 5),
      reason: 'both arms must measure the same fractional pose');
  image.dispose();

  final renderedImageBytes =
      controller.memoryAttribution?.renderedImages.bytes ?? 0;

  // Drain one-shot fake timers (retry backoff, cache expiry, prepared
  // debounces) before teardown so the binding's pending-timer invariant
  // passes.
  await tester.pump(const Duration(seconds: 30));

  // ignore: avoid_print
  print('DIAG-RESULT $arm/$gesture paints=${paintsAfterDrive - paintsBefore} '
      'frames=$framesDriven recaptures=${recapturesAfterDrive - recapturesBefore} '
      '(scale=${MapView.debugGridRecaptures.scale - recaptureScaleBefore}, '
      'content=${MapView.debugGridRecaptures.content - recaptureContentBefore}, '
      'zoom=${MapView.debugGridRecaptures.zoom}, '
      'membership=${MapView.debugGridRecaptures.membership}, '
      'flags=${MapView.debugGridRecaptures.flags}, '
      'runtime=${MapView.debugGridRecaptures.runtime}, '
      'total=${MapView.debugGridRecaptures.total}) '
      'sharp=$sharpness ref=$referenceSharpness');

  final result = _ArmResult(
    arm: arm,
    gesture: gesture,
    tileResolution: tileResolution,
    poseZoom: poseZoom,
    sharpness: sharpness,
    referenceSharpness: referenceSharpness,
    gridPaintsDuringDrive: paintsAfterDrive - paintsBefore,
    framesDuringDrive: framesDriven,
    gridPaintsDuringHold: paintsAfterHold - paintsBeforeHold,
    recapturesDuringDrive: recapturesAfterDrive - recapturesBefore,
    recaptureScale: MapView.debugGridRecaptures.scale - recaptureScaleBefore,
    recaptureContent:
        MapView.debugGridRecaptures.content - recaptureContentBefore,
    paintGridP50P95Max: [
      percentile(0.5),
      percentile(0.95),
      spans.isEmpty ? 0 : spans.last
    ],
    renderedImageBytes: renderedImageBytes,
  );
  _results.add(result);
  return result;
}

/// 512×512 raster PNG: left half opaque black, right half opaque white.
/// Built by the fixture test at the top of `main`.
Uint8List _halfHalfRasterPng512 = Uint8List.fromList([]);

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = _RealHttpOverrides();
    await _startServer();
    VectorSpanLog.enabled = true;
    // Real-zone engine work: setUpAll runs outside fake async, so the
    // PNG encode completes normally for every --name filtered run.
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
        const ui.Rect.fromLTWH(0, 0, 256, 512),
        ui.Paint()..color = const ui.Color(0xFF000000));
    canvas.drawRect(
        const ui.Rect.fromLTWH(256, 0, 256, 512),
        ui.Paint()..color = const ui.Color(0xFFFFFFFF));
    final fixture = recorder.endRecording().toImageSync(512, 512);
    final png = await fixture.toByteData(format: ui.ImageByteFormat.png);
    fixture.dispose();
    _halfHalfRasterPng512 = png!.buffer.asUint8List();
  });

  tearDownAll(() async {
    VectorSpanLog.enabled = false;
    await _server?.close(force: true);
    HttpOverrides.global = null;

    final buffer = StringBuffer()
      ..writeln()
      ..writeln('=== vector zoom-softness diagnostic ===')
      ..writeln('trajectory $_startZoom → $_measureZoom '
          '(grid z14 throughout; retained compositor ratio 2^0.6 ≈ 1.52 '
          'over zoomScale-0.76 cells; bypass resamples once at the live '
          'zoomScale)');
    for (final r in _results) {
      final resolutionNote = r.tileResolution == 256
          ? ''
          : ' @${r.tileResolution}px tiles';
      buffer
        ..writeln(
            '${r.arm.padRight(9)} ${r.gesture.padRight(6)}$resolutionNote pose ${r.poseZoom.toStringAsFixed(3)}')
        ..writeln('  sharpness ${r.sharpness.toStringAsFixed(0)} '
            '(×${r.sharpnessRatio.toStringAsFixed(3)} of the zoomScale-1.0 '
            'reference ${r.referenceSharpness.toStringAsFixed(0)})')
        ..writeln('  drive: ${r.gridPaintsDuringDrive} grid paints / '
            '${r.framesDuringDrive} frames, recaptures '
            '${r.recapturesDuringDrive} (scale ${r.recaptureScale}, content '
            '${r.recaptureContent}), paint.grid p50 '
            '${r.paintGridP50P95Max[0].toStringAsFixed(0)}µs / p95 '
            '${r.paintGridP50P95Max[1].toStringAsFixed(0)}µs / max '
            '${r.paintGridP50P95Max[2].toStringAsFixed(0)}µs')
        ..writeln('  hold paints: ${r.gridPaintsDuringHold}, '
            'rendered imagery ${(r.renderedImageBytes / 1024 / 1024).toStringAsFixed(1)} MB');
    }
    // print(), not debugPrint(): the report exceeds debugPrint's 1 KB
    // wrap budget (see the vector benchmark's note).
    // ignore: avoid_print
    print(buffer);
    // ignore: avoid_print
    print('PNG captures: build/vector_zoom_diag/{retained,bypass}_'
        '{pinch,wheel}[-reference].png');
  });

  testWidgets('pinch — shipped retained scale (vector)', (tester) async {
    final frames = _FrameCounter()..attach();
    final result = await _runVectorArm(tester,
        arm: 'retained', gesture: 'pinch', bypass: false, frames: frames);
    // Retained scaling: the captured raster absorbs the fractional scale —
    // the grid painter must stay flat during the drive.
    expect(result.gridPaintsDuringDrive, lessThanOrEqualTo(2),
        reason: 'retained arm must composite, not repaint, during pinch');
    expect(result.gridPaintsDuringHold, lessThanOrEqualTo(1),
        reason: 'nothing recaptures while the held pose is unchanged');
  });

  testWidgets('pinch — vector bypass of retained scaling', (tester) async {
    final frames = _FrameCounter()..attach();
    final result = await _runVectorArm(tester,
        arm: 'bypass', gesture: 'pinch', bypass: true, frames: frames);
    // Bypass: every applied scale-change frame repaints the grid at the
    // live pose.
    expect(result.gridPaintsDuringDrive, greaterThanOrEqualTo(3),
        reason: 'bypass arm repaints the grid per drive frame');
    expect(result.recapturesDuringDrive, greaterThanOrEqualTo(3),
        reason: 'the plan-12 capture recaptures on tileScale changes');
    expect(result.gridPaintsDuringHold, lessThanOrEqualTo(1),
        reason: 'nothing repaints while the held pose is unchanged');
  });

  testWidgets('wheel — shipped retained scale (vector)', (tester) async {
    final frames = _FrameCounter()..attach();
    final result = await _runVectorArm(tester,
        arm: 'retained', gesture: 'wheel', bypass: false, frames: frames);
    expect(result.gridPaintsDuringDrive, lessThanOrEqualTo(1),
        reason: 'retained arm must composite, not repaint, on wheel zoom');
  });

  testWidgets('wheel — vector bypass of retained scaling', (tester) async {
    final frames = _FrameCounter()..attach();
    final result = await _runVectorArm(tester,
        arm: 'bypass', gesture: 'wheel', bypass: true, frames: frames);
    expect(result.gridPaintsDuringDrive, greaterThanOrEqualTo(1),
        reason: 'bypass arm repaints the grid at the landed pose');
  });

  testWidgets('pinch — 512px tile render resolution (shipped grid path)',
      (tester) async {
    final frames = _FrameCounter()..attach();
    final result = await _runVectorArm(tester,
        arm: 'res512', gesture: 'pinch', bypass: false, frames: frames,
        tileResolution: 512);
    // Same switch behavior expectation as the shipped arm: retained scale
    // composites through the drive.
    expect(result.gridPaintsDuringDrive, lessThanOrEqualTo(2),
        reason: '512px arm keeps the retained-scale compositor path');
  });

  testWidgets('raster regression — bypass define leaves raster retained',
      (tester) async {
    MapView.vectorRetainedScaleEnabled = false; // bypass armed
    MapView.gridRetainedScaleEnabled = true;
    addTearDown(() {
      MapView.vectorRetainedScaleEnabled = true;
      MapView.gridRetainedScaleEnabled = true;
    });
    final controller = MapController();
    final rasterBoundaryKey = GlobalKey();

    tester.view.physicalSize = Size(_viewportSide * 3, _viewportSide * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RepaintBoundary(
          key: rasterBoundaryKey,
          child: MapView(
            latLng: const LatLng(latitude: 0, longitude: 0),
            zoom: 14,
            enableFractionalZoom: true,
            animateZoom: false,
            controller: controller,
            tileFetcher: (z, x, y) async => _halfHalfRasterPng512,
            showZoomControls: false,
            showScaleBar: false,
          ),
        ),
      ),
    ));
    expect(await _waitForSharp(tester, controller), isTrue,
        reason: 'raster fixture tiles must publish before the gesture');

    // Pixel scope check: a 512 px raster source (left half black, right
    // half white) keeps the historical natural-size draw — the capture's
    // left half covers the cell 1:1 and its white right half overflows
    // into the neighbouring cell's region. The resolution knob must never
    // normalize raster imagery (the repaint-count assertions below cannot
    // see this; the pixels can).
    {
      final boundary = rasterBoundaryKey.currentContext!
          .findRenderObject()! as RenderRepaintBoundary;
      final captured = await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final pixels = await image
            .toByteData(format: ui.ImageByteFormat.rawStraightRgba);
        return (image, pixels);
      });
      final image = captured!.$1;
      (int, int, int) at(int x, int y) {
        final p = captured.$2!.buffer.asUint8List();
        final i = (y * image.width + x) * 4;
        return (p[i], p[i + 1], p[i + 2]);
      }
      // The 400×400 viewport shows 256 px cells at zoomScale 1: cell 0 is
      // the even tile (black left half covering 0..256), cell 1 the odd
      // tile. With the historical natural-size draw the even tile's white
      // right half overflows 256..512 — visible until the odd tile's own
      // draw overwrites 256..768 with its inverted halves (black left).
      // So: x<256 black (even tile left half); 256..400 black (odd tile
      // left half). The distinguishing pixel of the OLD buggy normalize
      // was x=192: fitted drawing shows the even tile's white right half
      // at 128..256 — natural drawing shows black.
      expect(at(192, 128), (0, 0, 0),
          reason: 'the 512 px raster capture draws at natural size: the '
              'even tile\'s left half covers 0..256 (a resolution-fit draw '
              'would show its white right half at 128..256)');
      expect(at(64, 128), (0, 0, 0),
          reason: 'even tile left half is black in both paths — guard '
              'against an all-black capture');
      image.dispose();
    }

    final paintsBefore = RenderCanvasOSM.debugPaintCount;
    final pointer = TestPointer(1, PointerDeviceKind.mouse)..hover(_centre);
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -60)));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    final delta = RenderCanvasOSM.debugPaintCount - paintsBefore;
    expect(controller.fractionalZoom, closeTo(14.6, 0.01));
    expect(delta, lessThanOrEqualTo(1),
        reason: 'raster payloads keep the retained-scale compositor path '
            'even with the vector bypass armed');
    // Drain one-shot fake timers before teardown.
    await tester.pump(const Duration(seconds: 30));
  });
}
