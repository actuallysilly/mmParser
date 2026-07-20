# -*- mode: python ; coding: utf-8 -*-
"""
PyInstaller spec for MMA.

    pyinstaller mma.spec --noconfirm

onedir, NOT onefile. onefile extracts to a temp directory it deletes on exit,
which costs a slow unpack on every launch and makes the bundle layout opaque
when a permission has to be granted to a specific binary.

macOS builds MUST run on a macOS machine — PyInstaller cannot cross-compile.
"""

import sys

block_cipher = None

# Shipped read-only inside the bundle. masses.example.txt seeds the user's real
# masses.txt on first run (see paths.py); docs/ is the install guide, which the
# app points at when a permission is missing.
datas = [
    ("masses.example.txt", "."),
    ("docs", "docs"),
]

a = Analysis(
    ["app.py"],
    pathex=[],
    binaries=[],
    datas=datas,
    hiddenimports=["pynput"],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    # Trim the obvious weight. tkinter is REQUIRED - do not add it here.
    excludes=["pytest", "unittest", "pydoc_data", "test"],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)
pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="MMA",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,                 # UPX and macOS code signing do not mix
    console=False,             # no terminal window; status goes to the panel
    disable_windowed_traceback=False,
    argv_emulation=False,      # True breaks pynput's event tap on macOS
    target_arch=None,          # set to "universal2" only with a universal Python
    codesign_identity=None,    # build_macos.sh signs afterwards
    entitlements_file=None,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name="MMA",
)

if sys.platform == "darwin":
    app = BUNDLE(
        coll,
        name="MMA.app",
        icon=None,
        # STABLE identifier. macOS ties granted permissions to this plus the
        # code signature — change it and every user has to re-grant both
        # Input Monitoring and Accessibility.
        bundle_identifier="com.mma.followups",
        info_plist={
            "CFBundleName": "MMA",
            "CFBundleDisplayName": "MMA",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1.0.0",
            "NSHighResolutionCapable": True,
            # Shown in the permission prompts, so it should read as a reason a
            # non-technical user accepts rather than a system string.
            "NSAppleEventsUsageDescription":
                "MMA types your follow-up messages into the chat app for you.",
            # Not LSUIElement: the panel is a real window the user opens.
            "LSMinimumSystemVersion": "13.0",
        },
    )
