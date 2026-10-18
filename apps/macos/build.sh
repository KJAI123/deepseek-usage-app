#!/bin/bash
# 构建 DeepSeek 用量面板（主应用 + 桌面小组件扩展 + 看板，通用架构 arm64 + x86_64）
set -e
cd "$(dirname "$0")"
APP="DeepSeekUsagePanel.app"
APP_GROUP="group.com.local.deepseek-usage-panel"

rm -rf "$APP" build_tmp
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/PlugIns/DSWidget.appex/Contents/MacOS" "$APP/Contents/Resources/dashboard" build_tmp
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || true

echo "== 复制看板资源（shared/ui → Resources/dashboard）=="
cp ../../shared/ui/dashboard.html ../../shared/ui/echarts.min.js "$APP/Contents/Resources/dashboard/"

echo "== 编译主应用 arm64 =="
swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 \
  -framework AppKit -framework Security -framework ServiceManagement -framework WebKit \
  DeepSeekUsagePanel.swift -o build_tmp/app_arm

echo "== 编译主应用 x86_64 =="
swiftc -O -swift-version 5 -target x86_64-apple-macosx13.0 \
  -framework AppKit -framework Security -framework ServiceManagement -framework WebKit \
  DeepSeekUsagePanel.swift -o build_tmp/app_x86

lipo -create build_tmp/app_arm build_tmp/app_x86 -output "$APP/Contents/MacOS/DeepSeekUsagePanel"

echo "== 编译小组件扩展（macOS 14+）=="
swiftc -parse-as-library -O -swift-version 5 \
  -module-name DSWidget \
  -target arm64-apple-macosx14.0 \
  -framework WidgetKit -framework SwiftUI \
  widget/widget.swift -o build_tmp/widget_arm
swiftc -parse-as-library -O -swift-version 5 \
  -module-name DSWidget \
  -target x86_64-apple-macosx14.0 \
  -framework WidgetKit -framework SwiftUI \
  widget/widget.swift -o build_tmp/widget_x86

lipo -create build_tmp/widget_arm build_tmp/widget_x86 -output "$APP/Contents/PlugIns/DSWidget.appex/Contents/MacOS/DSWidget"
cp widget/Info.plist "$APP/Contents/PlugIns/DSWidget.appex/Contents/Info.plist"
printf '????' > "$APP/Contents/PlugIns/DSWidget.appex/Contents/PkgInfo"

echo "== 签名（ad-hoc + App Group 权限）=="
codesign --force --sign - --entitlements Widget.entitlements "$APP/Contents/PlugIns/DSWidget.appex"
codesign --force --sign - --entitlements App.entitlements "$APP"

rm -rf build_tmp
echo "== 完成：$APP（含小组件）=="
