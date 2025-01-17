import 'dart:async';

import 'package:flutter/material.dart' as material;
import 'package:flutter/widgets.dart';
import '../cache/text_cache.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

import '../executor/executor.dart';
import '../executor/queue_executor.dart';
import '../tile_identity.dart';
import 'debounce.dart';
import 'disposable_state.dart';
import 'grid_tile_positioner.dart';
import 'tile_model.dart';

class GridVectorTile extends material.StatelessWidget {
  final VectorTileModel model;
  final TextCache textCache;

  const GridVectorTile(
      {required Key key, required this.model, required this.textCache})
      : super(key: key);

  @override
  material.Widget build(material.BuildContext context) {
    return GridVectorTileBody(
        key: Key('tileBody${model.tile.key()}'),
        model: model,
        textCache: textCache);
  }
}

class GridVectorTileBody extends StatefulWidget {
  final VectorTileModel model;
  final TextCache textCache;

  const GridVectorTileBody(
      {required Key key, required this.model, required this.textCache})
      : super(key: key);
  @override
  material.State<material.StatefulWidget> createState() {
    return _GridVectorTileBodyState(model, textCache);
  }
}

class _GridVectorTileBodyState extends DisposableState<GridVectorTileBody> {
  final VectorTileModel model;
  final TextCache textCache;
  late final _VectorTilePainter _painter;
  _VectorTilePainter? _symbolPainter;

  _GridVectorTileBodyState(this.model, this.textCache);

  @override
  void initState() {
    super.initState();
    final symbolTheme = model.symbolTheme;
    _painter = _VectorTilePainter(_TileLayerOptions(model, model.theme,
        textCache: textCache,
        paintBackground: model.paintBackground,
        showTileDebugInfo: model.showTileDebugInfo));
    if (symbolTheme != null) {
      _symbolPainter = _VectorTilePainter(_TileLayerOptions(model, symbolTheme,
          textCache: textCache,
          paintBackground: false,
          showTileDebugInfo: false));
    }
    model.addListener(() {
      if (!disposed) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    super.dispose();
    model.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tile = RepaintBoundary(
        key: Key('tileBodyBoundary${widget.model.tile.key()}'),
        child: CustomPaint(painter: _painter));
    final symbolPainter = _symbolPainter;
    if (symbolPainter != null) {
      return Stack(fit: StackFit.expand, children: [
        tile,
        _DelayedPainter(
            key: Key('delayedSymbols${widget.model.tile.key()}'),
            painter: symbolPainter)
      ]);
    }
    return tile;
  }
}

class _DelayedPainter extends material.StatefulWidget {
  final _VectorTilePainter painter;

  const _DelayedPainter({material.Key? key, required this.painter})
      : super(key: key);
  @override
  material.State<material.StatefulWidget> createState() {
    return _DelayedPainterState(painter);
  }
}

final _paintQueue = <_DelayedPainterState>[];
var _scheduled = false;

class _DelayedPainterState extends DisposableState<_DelayedPainter> {
  late final ScheduledDebounce debounce;
  final _VectorTilePainter painter;
  var _render = false;
  var _nextPaintNoDelay = false;

  bool get shouldPaint => _render && painter.options.model.showLabels;

  _DelayedPainterState(this.painter) {
    debounce = ScheduledDebounce(_notifyUpdate,
        delay: Duration(milliseconds: 500),
        jitter: Duration(milliseconds: 50),
        maxAge: Duration(seconds: 10));
    painter.options.model.addListener(() {
      debounce.update();
    });
    painter.options.model.symbolState
        .addListener(() => scheduleMicrotask(_labelsReady));
    painter.labelsReadyCallback = _labelsReady;
  }

  void _labelsReady() {
    _nextPaintNoDelay = true;
    _render = true;
    _schedulePaint();
  }

  void painted() {
    if (_render) {
      if (_nextPaintNoDelay) {
        _nextPaintNoDelay = false;
      } else {
        _render = false;
      }
      _scheduleOne();
    } else {
      debounce.update();
    }
  }

  @override
  material.Widget build(material.BuildContext context) {
    final tileKey = painter.options.model.tile.key();
    final opacity = painter.options.model.symbolState.symbolsReady &&
            painter.options.model.showLabels &&
            _render
        ? 1.0
        : 0.0;
    final child = RepaintBoundary(
        key: Key('tileBodyBoundarySymbols$tileKey'),
        child: CustomPaint(painter: _DelayedCustomPainter(this, painter)));
    return AnimatedOpacity(
        key: Key('tileBodySymbolsOpacity$tileKey'),
        opacity: opacity,
        duration: Duration(milliseconds: _render ? 500 : 0),
        child: child);
  }

  void _notifyUpdate() {
    if (!disposed) {
      if (!_paintQueue.contains(this)) {
        _paintQueue.add(this);
      }
      _scheduleOne();
    }
  }

  void _schedulePaint() {
    if (!disposed) {
      setState(() {
        _render = true;
      });
    }
  }

  void _scheduleOne() async {
    if (!_scheduled && _paintQueue.isNotEmpty) {
      _scheduled = true;
      await Future.delayed(Duration(milliseconds: 10));
      _scheduled = false;
      if (_paintQueue.isNotEmpty) {
        _paintQueue.removeLast()._schedulePaint();
        _scheduleOne();
      }
    }
  }
}

class _DelayedCustomPainter extends material.CustomPainter {
  final _DelayedPainterState _state;
  final material.CustomPainter _delegate;

  _DelayedCustomPainter(this._state, this._delegate);

  @override
  void paint(material.Canvas canvas, material.Size size) {
    if (_state.shouldPaint) {
      _delegate.paint(canvas, size);
    }
    _state.painted();
  }

  @override
  bool shouldRepaint(covariant material.CustomPainter oldDelegate) {
    return true;
  }
}

class _TileLayerOptions {
  final VectorTileModel model;
  final TextCache textCache;
  final Theme theme;
  final bool paintBackground;
  final bool showTileDebugInfo;

  _TileLayerOptions(this.model, this.theme,
      {required this.paintBackground,
      required this.textCache,
      required this.showTileDebugInfo});
}

enum _PaintMode { vector, background, none }

final _labelUpdateExecutor = QueueExecutor();

class _VectorTilePainter extends CustomPainter {
  final _TileLayerOptions options;
  TileIdentity? _lastPaintedId;
  var _lastPainted = _PaintMode.none;
  var _paintCount = 0;
  late final ScheduledDebounce debounce;
  final CreatedTextPainterProvider _painterProvider =
      CreatedTextPainterProvider();
  late final CachingTextPainterProvider _cachingPainterProvider;

  void Function()? labelsReadyCallback;

  _VectorTilePainter(this.options) : super(repaint: options.model) {
    _cachingPainterProvider =
        CachingTextPainterProvider(options.textCache, _painterProvider);
    debounce = ScheduledDebounce(_notifyIfNeeded,
        delay: Duration(milliseconds: 100),
        jitter: Duration(milliseconds: 100),
        maxAge: Duration(seconds: 10));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final model = options.model;
    if (model.disposed) {
      return;
    }
    model.updateRendering();
    if (model.tileset == null) {
      if (options.paintBackground) {
        _paintBackground(canvas, size);
      }
      return;
    }
    final translation = model.translation;
    if (translation == null) {
      return;
    }
    final tileSizer =
        GridTileSizer(translation, model.zoomScaleFunction(model.tile.z), size);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    tileSizer.apply(canvas);

    final tileClip = tileSizer.tileClip(size, tileSizer.effectiveScale);
    Renderer(theme: options.theme, painterProvider: _cachingPainterProvider)
        .render(canvas, model.tileset!,
            clip: tileClip,
            zoomScaleFactor: tileSizer.effectiveScale,
            zoom: model.lastRenderedZoomDetail);
    _lastPainted = _PaintMode.vector;
    _lastPaintedId = translation.translated;

    canvas.restore();
    _paintTileDebugInfo(canvas, size, tileSizer.effectiveScale, tileSizer,
        model.lastRenderedZoom, model.lastRenderedZoomDetail);
    model.rendered();
    _maybeUpdateLabels();
  }

  void _paintBackground(Canvas canvas, Size size) {
    final model = options.model;
    final tileSizer = GridTileSizer(
        model.defaultTranslation, model.zoomScaleFunction(model.tile.z), size);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    tileSizer.apply(canvas);
    final tileClip = tileSizer.tileClip(size, tileSizer.effectiveScale);
    Renderer(theme: options.theme).render(canvas, Tileset({}),
        clip: tileClip,
        zoomScaleFactor: tileSizer.effectiveScale,
        zoom: model.lastRenderedZoom);
    _lastPainted = _PaintMode.background;
    _lastPaintedId = null;
    canvas.restore();
    _paintTileDebugInfo(canvas, size, tileSizer.effectiveScale, tileSizer,
        model.lastRenderedZoom, model.lastRenderedZoomDetail);
  }

  void _paintTileDebugInfo(Canvas canvas, Size size, double scale,
      GridTileSizer tileSizer, double zoom, double zoomDetail) {
    if (options.showTileDebugInfo) {
      ++_paintCount;
      final paint = Paint()
        ..strokeWidth = 2.0
        ..style = material.PaintingStyle.stroke
        ..color = Color.fromARGB(0xff, 0, 0xff, 0);
      canvas.drawLine(Offset.zero, material.Offset(0, size.height), paint);
      canvas.drawLine(Offset.zero, material.Offset(size.width, 0), paint);
      final textStyle = TextStyle(
          foreground: Paint()..color = Color.fromARGB(0xff, 0, 0, 0),
          fontSize: 15);
      final roundedScale = (scale * 1000).roundToDouble() / 1000;
      final text = TextPainter(
          text: TextSpan(
              style: textStyle,
              text:
                  '${options.model.tile} zoom=$zoom zoomDetail=$zoomDetail\nscale=$roundedScale\npaintCount=$_paintCount'),
          textAlign: TextAlign.start,
          textDirection: TextDirection.ltr)
        ..layout();
      text.paint(canvas, material.Offset(10, 10));
    }
  }

  void _notifyIfNeeded() {
    Future.microtask(() {
      if (_lastPainted != _PaintMode.vector) {
        options.model.requestRepaint();
      }
    });
  }

  void _maybeUpdateLabels() {
    if (_lastPainted == _PaintMode.vector) {
      bool hasUnpaintedSymbols =
          _painterProvider.symbolsWithoutPainter().isNotEmpty;
      if (hasUnpaintedSymbols) {
        _labelUpdateExecutor
            .submit(_UpdateTileLabelsJob(this).toExecutorJob())
            .swallowCancellation();
      } else {
        options.model.symbolState.symbolsReady = true;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _VectorTilePainter oldDelegate) =>
      options.model.hasChanged() ||
      (oldDelegate._lastPainted == _PaintMode.vector &&
          oldDelegate._lastPaintedId !=
              options.model.translation?.translated) ||
      (oldDelegate._lastPainted == _PaintMode.background);
}

class _UpdateTileLabelsJob {
  final _VectorTilePainter _painter;

  _UpdateTileLabelsJob(this._painter);

  Job toExecutorJob() {
    return Job('labels ${_painter.options.model.tile}', _updateLabels, this,
        deduplicationKey: null,
        cancelled: () => _painter.options.model.disposed);
  }

  void updateLabels() {
    if (!_painter.options.model.disposed) {
      final remainingSymbols =
          _painter._painterProvider.symbolsWithoutPainter();
      if (remainingSymbols.isEmpty) {
        _painter.labelsReadyCallback?.call();
      } else {
        final symbol = remainingSymbols.first;
        final painter = _painter._painterProvider.create(symbol);
        _painter.options.textCache.put(symbol, painter);
        Future.delayed(Duration(milliseconds: 2)).then((value) =>
            _labelUpdateExecutor.submit(toExecutorJob()).swallowCancellation());
      }
    }
  }
}

bool _updateLabels(job) {
  (job as _UpdateTileLabelsJob).updateLabels();
  return true;
}

extension RectDebugExtension on Rect {
  String debugString() => '[$left,$top,$width,$height]';
}
