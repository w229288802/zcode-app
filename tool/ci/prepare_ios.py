"""为 CI 生成的 Flutter iOS 工程补全打包配置。"""

import plistlib
import re
from pathlib import Path


def main():
    ios = Path("ios")
    minimum_ios = "15.5"

    info_path = ios / "Runner/Info.plist"
    with info_path.open("rb") as source:
        info = plistlib.load(source)
    info.update(
        CFBundleDisplayName="ZCode",
        CFBundleName="ZCode",
        NSCameraUsageDescription="用于扫描 ZCode 桌面端连接二维码。",
        NSPhotoLibraryUsageDescription="用于选择图片并发送到对话。",
    )
    with info_path.open("wb") as destination:
        plistlib.dump(info, destination, sort_keys=False)

    project_path = ios / "Runner.xcodeproj/project.pbxproj"
    project = project_path.read_text(encoding="utf-8")
    project, replacements = re.subn(
        r"IPHONEOS_DEPLOYMENT_TARGET = [^;]+;",
        f"IPHONEOS_DEPLOYMENT_TARGET = {minimum_ios};",
        project,
    )
    if not replacements:
        raise RuntimeError("Flutter iOS 工程模板缺少部署版本配置，请检查模板变化。")
    project_path.write_text(project, encoding="utf-8")

    framework_path = ios / "Flutter/AppFrameworkInfo.plist"
    with framework_path.open("rb") as source:
        framework = plistlib.load(source)
    framework["MinimumOSVersion"] = minimum_ios
    with framework_path.open("wb") as destination:
        plistlib.dump(framework, destination, sort_keys=False)

    # 显式使用 CocoaPods，让没有 iOS 工程的仓库也能安装原生插件。
    podfile = """platform :ios, '__MINIMUM_IOS__'
ENV['COCOAPODS_DISABLE_STATS'] = 'true'

project 'Runner', {
  'Debug' => :debug,
  'Profile' => :release,
  'Release' => :release,
}

def flutter_root
  generated_xcode_build_settings_path = File.expand_path(File.join('..', 'Flutter', 'Generated.xcconfig'), __FILE__)
  File.foreach(generated_xcode_build_settings_path) do |line|
    matches = line.match(/FLUTTER_ROOT=(.*)/)
    return matches[1].strip if matches
  end
  raise "FLUTTER_ROOT not found in #{generated_xcode_build_settings_path}"
end

require File.expand_path(File.join('packages', 'flutter_tools', 'bin', 'podhelper'), flutter_root)
flutter_ios_podfile_setup

target 'Runner' do
  use_frameworks!
  flutter_install_all_ios_pods File.dirname(File.realpath(__FILE__))
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    flutter_additional_ios_build_settings(target)
  end
end
"""
    (ios / "Podfile").write_text(
        podfile.replace("__MINIMUM_IOS__", minimum_ios), encoding="utf-8"
    )


if __name__ == "__main__":
    main()
