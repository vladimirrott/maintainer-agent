# Brand assets

`logo.svg` is the mark: two bars and a check. The project holds, then it proves.
It survives to 22px, which is the size that decides whether a mark is any good.

`social-preview.png` is 1280x640, which is what GitHub recommends (minimum
640x320, maximum 1MB), cropped to 2:1. Every pixel that matters sits at least
130px from an edge, well clear of the 50px GitHub warns about.

Setting it is a **web UI step and has no API**: Settings, General, Social
preview, Upload an image. Regenerate the PNG from the SVG rather than editing it:

```sh
brave-browser --headless --disable-gpu --hide-scrollbars \
  --screenshot=assets/social-preview.png --window-size=1280,640 \
  "file://$PWD/assets/social-preview.html"
```

The SVG names DejaVu Sans Mono, which is what the PNG in this directory was
rendered with. A machine without it will substitute another monospace font and
the line breaks will move.
