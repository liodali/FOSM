## 0.0.2

* Added `cameraBounds` to `MapView` — a hard bounding box the camera can never pan, pinch, or programmatic-move outside of.
* Added `MapController.fitBounds` to navigate the camera so a box (e.g. a route) fits the viewport, with optional padding and animation.
* Added `LatLngBounds` with `fromPoints`, `contains`, and `center`.

## 0.0.1

* Added polyline styling: solid, dashed, and dotted patterns.
* Added optional `borderColor` / `borderWidth` casing to `MapPolyline`.
* Added `strokeCap`, `strokeJoin`, and `strokeMiterLimit` to `MapPolyline`.
* Introduced `MapPolylinePattern` with `solid`, `dashed`, and `dotted` variants.
