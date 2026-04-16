# Fix display issues on Dell XPS Panther Lake (Xe3) systems.
# Xe PSR causes freezes and display glitches on both OLED and IPS panels.
# LG OLED panels also need Panel Replay disabled.
if omarchy-hw-match "XPS" && omarchy-hw-intel-ptl; then
  echo "Detected Dell XPS on Panther Lake, applying display power-saving fixes..."

  if omarchy-hw-dell-xps-oled; then
    omarchy-cmdline-add "xe.enable_psr=0 xe.enable_panel_replay=0" dell-xps-ptl-display
  else
    omarchy-cmdline-add "xe.enable_psr=0" dell-xps-ptl-display
  fi
fi
