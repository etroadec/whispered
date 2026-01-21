#!/usr/bin/env python3
"""
Generate Whispered app icon with black gradient and waveform
"""

import subprocess
import os
from pathlib import Path

# Icon sizes needed for macOS
SIZES = [16, 32, 64, 128, 256, 512, 1024]

def generate_svg():
    """Generate SVG icon with gradient background and waveform"""
    svg = '''<?xml version="1.0" encoding="UTF-8"?>
<svg width="1024" height="1024" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <!-- Radial gradient from dark purple to black -->
    <radialGradient id="bgGradient" cx="50%" cy="30%" r="70%">
      <stop offset="0%" style="stop-color:#2d1b4e"/>
      <stop offset="50%" style="stop-color:#1a1025"/>
      <stop offset="100%" style="stop-color:#0a0510"/>
    </radialGradient>

    <!-- Glow effect for waveform -->
    <filter id="glow" x="-50%" y="-50%" width="200%" height="200%">
      <feGaussianBlur stdDeviation="8" result="coloredBlur"/>
      <feMerge>
        <feMergeNode in="coloredBlur"/>
        <feMergeNode in="SourceGraphic"/>
      </feMerge>
    </filter>

    <!-- Gradient for waveform -->
    <linearGradient id="waveGradient" x1="0%" y1="0%" x2="100%" y2="0%">
      <stop offset="0%" style="stop-color:#8b5cf6"/>
      <stop offset="50%" style="stop-color:#a78bfa"/>
      <stop offset="100%" style="stop-color:#8b5cf6"/>
    </linearGradient>
  </defs>

  <!-- Background with rounded corners -->
  <rect x="0" y="0" width="1024" height="1024" rx="220" ry="220" fill="url(#bgGradient)"/>

  <!-- Subtle inner glow -->
  <rect x="40" y="40" width="944" height="944" rx="190" ry="190"
        fill="none" stroke="url(#waveGradient)" stroke-width="2" opacity="0.3"/>

  <!-- Waveform bars -->
  <g filter="url(#glow)" transform="translate(512, 512)">
    <!-- Center bar (tallest) -->
    <rect x="-30" y="-180" width="60" height="360" rx="30" fill="url(#waveGradient)"/>

    <!-- Second bars -->
    <rect x="-130" y="-140" width="50" height="280" rx="25" fill="url(#waveGradient)"/>
    <rect x="80" y="-140" width="50" height="280" rx="25" fill="url(#waveGradient)"/>

    <!-- Third bars -->
    <rect x="-220" y="-100" width="45" height="200" rx="22" fill="url(#waveGradient)"/>
    <rect x="175" y="-100" width="45" height="200" rx="22" fill="url(#waveGradient)"/>

    <!-- Outer bars (shortest) -->
    <rect x="-300" y="-60" width="40" height="120" rx="20" fill="url(#waveGradient)"/>
    <rect x="260" y="-60" width="40" height="120" rx="20" fill="url(#waveGradient)"/>
  </g>
</svg>'''
    return svg

def main():
    script_dir = Path(__file__).parent
    project_dir = script_dir.parent
    resources_dir = project_dir / "Resources"
    iconset_dir = resources_dir / "AppIcon.iconset"

    # Create directories
    resources_dir.mkdir(exist_ok=True)
    iconset_dir.mkdir(exist_ok=True)

    # Generate SVG
    svg_path = resources_dir / "icon.svg"
    svg_content = generate_svg()
    svg_path.write_text(svg_content)
    print(f"Generated SVG: {svg_path}")

    # Check if we have rsvg-convert or can use sips
    use_rsvg = subprocess.run(["which", "rsvg-convert"], capture_output=True).returncode == 0

    if use_rsvg:
        # Generate PNG files using rsvg-convert
        for size in SIZES:
            # Regular resolution
            png_name = f"icon_{size}x{size}.png"
            png_path = iconset_dir / png_name
            subprocess.run([
                "rsvg-convert", "-w", str(size), "-h", str(size),
                str(svg_path), "-o", str(png_path)
            ], check=True)

            # @2x resolution (except for 1024)
            if size <= 512:
                png_name_2x = f"icon_{size}x{size}@2x.png"
                png_path_2x = iconset_dir / png_name_2x
                subprocess.run([
                    "rsvg-convert", "-w", str(size * 2), "-h", str(size * 2),
                    str(svg_path), "-o", str(png_path_2x)
                ], check=True)

            print(f"Generated: {png_name}")
    else:
        # Fallback: Create a simple PNG using Python
        print("rsvg-convert not found. Install with: brew install librsvg")
        print("Generating PNG manually...")

        # Try using qlmanage (Quick Look) as fallback
        temp_png = resources_dir / "temp_icon.png"
        result = subprocess.run([
            "qlmanage", "-t", "-s", "1024", "-o", str(resources_dir), str(svg_path)
        ], capture_output=True)

        if result.returncode == 0:
            # qlmanage creates file with .png.png extension sometimes
            for f in resources_dir.glob("icon.svg*.png"):
                f.rename(temp_png)
                break

            # Use sips to create all sizes
            for size in SIZES:
                png_name = f"icon_{size}x{size}.png"
                png_path = iconset_dir / png_name
                subprocess.run([
                    "sips", "-z", str(size), str(size), str(temp_png),
                    "--out", str(png_path)
                ], capture_output=True)

                if size <= 512:
                    png_name_2x = f"icon_{size}x{size}@2x.png"
                    png_path_2x = iconset_dir / png_name_2x
                    subprocess.run([
                        "sips", "-z", str(size * 2), str(size * 2), str(temp_png),
                        "--out", str(png_path_2x)
                    ], capture_output=True)

                print(f"Generated: {png_name}")

            temp_png.unlink()
        else:
            print("Could not generate PNG. Please install librsvg: brew install librsvg")
            return

    # Create icns file
    icns_path = resources_dir / "AppIcon.icns"
    subprocess.run([
        "iconutil", "-c", "icns", str(iconset_dir), "-o", str(icns_path)
    ], check=True)

    print(f"\nIcon created: {icns_path}")

    # Clean up iconset directory
    # subprocess.run(["rm", "-rf", str(iconset_dir)])

if __name__ == "__main__":
    main()
