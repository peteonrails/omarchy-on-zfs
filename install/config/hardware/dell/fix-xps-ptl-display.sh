# Fix display issues on Dell XPS 2026+ with LG OLED panel and Intel Panther Lake (Xe3) GPU.
# Power-saving features (PSR and Panel Replay) cause freezes and display glitches.
if omarchy-hw-match "XPS" \
  && omarchy-hw-intel-ptl \
  && test "$(od -An -tx1 -j8 -N2 /sys/class/drm/card*-eDP-*/edid 2>/dev/null | tr -d ' \n')" = "30e4"; then

  echo "Detected Dell XPS with LG OLED panel on Panther Lake, applying display power-saving fix..."

  omarchy-cmdline-add "xe.enable_psr=0 xe.enable_panel_replay=0" dell-xps-ptl-display
fi
