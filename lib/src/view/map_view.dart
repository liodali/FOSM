import 'package:flutter/material.dart';
import 'package:fosm/src/api/geo_point.dart';
import 'package:fosm/src/api/tile_manager.dart';

import '../api/tile.dart';
import '../common/osm_transformation_utilities.dart';
import '../common/utils.dart';
import 'render.dart';

class MapView extends StatefulWidget {
  final LatLng latLng;
  final int zoom;

  const MapView({Key? key, required this.latLng, required this.zoom})
      : super(key: key);

  @override
  State<StatefulWidget> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> {
  List<Tile> tiles = [];

  // int maxSize = 38 * 1024 * 1024;
  List<Tile> cacheTiles = [];
  late int horizontalTileCount;
  late int verticalTileCount;
  late int leftColumnTilesLngIndex;
  late int topRowTilesLatIndex;
  late double leftColumnTilesCanvasX;
  late double topRowTilesCanvasY;
  late double centerTileLng;
  late double centerTileLat;
  late double centerCanvasX;
  late double centerCanvasY;
  late double width;
  late double height;

  late LatLng latLng;
  late int zoom;
  bool isDrag = false;
  double? startPointXDrag, startPointYDrag, endPointXDrag, endPointYDrag;
  TileManager? tileManager;

  @override
  void initState() {
    super.initState();
    latLng = widget.latLng;
    zoom = widget.zoom;
    Future.delayed(Duration.zero, () async {
      tileManager = TileManager.init(
        width: width,
        height: height,
        centerLatLng: latLng,
        zoom: zoom,
      );
      tileManager!.calculate((f) => setState(f));
      setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    width = MediaQuery.of(context).size.width;
    height = MediaQuery.of(context).size.height;
    // centerCanvasX = width / 2;
    // centerCanvasY = height / 2;
    // centerTileLng = lon2TileX(latLng.longitude, zoom);
    // centerTileLat = lat2TileY(latLng.latitude, zoom);
    // drawMap(
    //   zoom,
    // );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanStart: (details) {
        setState(() {
          startPointXDrag = details.globalPosition.dx;
          startPointYDrag = details.globalPosition.dy;
        });
      },
      onPanCancel: () {
        setState(() {
          isDrag = false;
          endPointXDrag = null;
          endPointYDrag = null;
        });
      },
      onPanUpdate: (details) {
        setState(() {
          isDrag = true;
          endPointXDrag = details.globalPosition.dx;
          endPointYDrag = details.globalPosition.dy;
        });
      },
      onPanDown: (details) {
        setState(() {
          isDrag = true;
        });
      },
      onPanEnd: (details) {
        if (isDrag && startPointXDrag != null && startPointYDrag != null) {
          final lastPointerX = endPointXDrag!;
          //details.velocity.pixelsPerSecond.dx;
          final lastPointerY = endPointYDrag!;
          //details.velocity.pixelsPerSecond.dy;

          final pointerX = lastPointerX - startPointXDrag!;
          final pointerY = lastPointerY - startPointYDrag!;

          final pointerTileLongitudeNumber =
              tileManager!.centerTileLng + -pointerX / tileWidth;
          final pointerTileLatitudeNumber =
              tileManager!.centerTileLat + -pointerY / tileHeight;

          final lat = tileY2Lat(pointerTileLatitudeNumber, zoom);
          final lng = tileX2Lng(pointerTileLongitudeNumber, zoom);
          setState(() {
            isDrag = false;
            endPointXDrag = null;
            endPointYDrag = null;
            latLng = LatLng(latitude: lat, longitude: lng);
            tileManager!.setCenterTile(latLng: latLng);
            tileManager!.calculate((f) => setState(f));
            // centerTileLng = lon2TileX(latLng.longitude, zoom);
            // centerTileLat = lat2TileY(latLng.latitude, zoom);
            // drawMap(zoom);
          });
        }

        // setState((){
        //   isDrag = false;
        //   endPointXDrag = null;
        //   endPointYDrag = null;
        // });
      },
      child: tileManager != null && tileManager!.renderTiles.isNotEmpty
          ? CustomPaint(
              child: Container(),
              painter: RenderCanvasOSM(
                horizontalTileCount: tileManager!.horizontalTileCount,
                verticalTileCount: tileManager!.verticalTileCount,
                leftColumnTilesLngIndex: tileManager!.leftColumnTilesLngIndex,
                topRowTilesLatIndex: tileManager!.topRowTilesLatIndex,
                leftColumnTilesCanvasX: tileManager!.leftColumnTilesCanvasX,
                topRowTilesCanvasY: tileManager!.topRowTilesCanvasY,
                tiles: tileManager!.renderTiles,
                latLng: tileManager!.centerLatLng,
                zoom: zoom,
              ),
            )
          : Container(
              width: width,
              height: height,
              color: Colors.grey,
            ),
    );
  }
/*
  void drawMap(int zoom) {
    setState(() {

    });
    final centerPointTileX = (centerTileLng % 1) * tileWidth;
    final centerPointTileY = (centerTileLat % 1) * tileHeight;

    final centerCanvasTileX = centerCanvasX - centerPointTileX;
    final centerCanvasTileY = centerCanvasY - centerPointTileY;

    final leftColumnsBeforeCenterCount = (centerCanvasTileX / tileWidth).ceil();
    leftColumnTilesCanvasX =
        centerCanvasTileX - leftColumnsBeforeCenterCount * tileWidth;

    final topRowsBeforeCenterCount = (centerCanvasTileY / tileHeight).ceil();
    topRowTilesCanvasY =
        centerCanvasTileY - topRowsBeforeCenterCount * tileHeight;

    final centerTileLngIndex = centerTileLng.floor();
    leftColumnTilesLngIndex = centerTileLngIndex - leftColumnsBeforeCenterCount;

    final centerTileLatIndex = centerTileLat.floor();
    topRowTilesLatIndex = centerTileLatIndex - topRowsBeforeCenterCount;

    horizontalTileCount =
        ((width + -leftColumnTilesCanvasX) / tileWidth).ceil();
    verticalTileCount = ((height + -topRowTilesCanvasY) / tileHeight).ceil();

    for (var hIndex = 0; hIndex < horizontalTileCount; hIndex++) {
      final tileLngIndex = leftColumnTilesLngIndex + hIndex;
      for (var vIndex = 0; vIndex < verticalTileCount; vIndex++) {
        final tileLatIndex = topRowTilesLatIndex + vIndex;
        // Draw a checker board pattern as a substrate for the tile while it is loading
        setState(() {
          for (var x = 0; x < tileWidth / 8; x++) {
            for (var y = 0; y < tileHeight / 8; y++) {
              tiles.add(Tile(
                null,
                "$tileLngIndex-$tileLatIndex",
                tileLatIndex,
                tileLngIndex,
              ));
            }
          }
        });
        Future.microtask(() async {
          final index = tiles.indexWhere(
              (element) => element.index == "$tileLngIndex-$tileLatIndex");
          final indexOld = cacheTiles.indexWhere(
              (element) => element.index == "$tileLngIndex-$tileLatIndex");
          if (index == -1 && indexOld == -1) {
            final imageTile = await getTile(zoom, tileLngIndex, tileLatIndex);
            ui.Codec codec =
                await ui.instantiateImageCodec(imageTile.toUint8List());
            ui.FrameInfo fi = await codec.getNextFrame();
            setState(() {
              tiles.add(Tile(
                fi.image,
                "$tileLngIndex-$tileLatIndex",
                tileLatIndex,
                tileLngIndex,
              ));
            });
          } else if (tiles[index].sourceTile == null && indexOld == -1) {
            final imageTile = await getTile(zoom, tileLngIndex, tileLatIndex);
            ui.Codec codec =
                await ui.instantiateImageCodec(imageTile.toUint8List());
            ui.FrameInfo fi = await codec.getNextFrame();
            setState(() {
              tiles[index] = Tile(
                fi.image,
                "$tileLngIndex-$tileLatIndex",
                tileLatIndex,
                tileLngIndex,
              );
            });
          } else {
            setState(() {
              tiles[index] = cacheTiles[indexOld];
            });
          }
        });
      }
    }
  }

 */
}
