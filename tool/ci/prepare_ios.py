"""为 CI 生成的 Flutter iOS 工程补全打包配置。"""

import plistlib
import re
from pathlib import Path


def main():
    ios = Path("ios")
    minimum_ios = "15.5"

    # 通知插件要求 AppDelegate 接收 iOS 通知回调。
    delegate_path = ios / "Runner/AppDelegate.swift"
    delegate = delegate_path.read_text(encoding="utf-8")
    if "UNUserNotificationCenter.current().delegate" not in delegate:
        anchor = "    return super.application("
        if anchor not in delegate:
            raise RuntimeError("Flutter AppDelegate 模板已变化，请检查通知代理配置。")
        delegate = delegate.replace(
            anchor,
            "    UNUserNotificationCenter.current().delegate = self\n" + anchor,
            1,
        )
        if "import UserNotifications" not in delegate:
            delegate = "import UserNotifications\n" + delegate
        delegate_path.write_text(delegate, encoding="utf-8")

    # iOS 切后台几秒就挂起 App, WebSocket 停收, 任务完成通知要等打开 App 才到。
    # 进后台时申请后台执行时间 (系统通常给约 30 秒), 让进行中的回复有机会
    # 收完并弹通知; 用通知中心监听, 兼容 AppDelegate 与 UIScene 两种生命周期。
    delegate = delegate_path.read_text(encoding="utf-8")
    if "ZcodeBackgroundKeeper" not in delegate:
        anchor = "    return super.application("
        if anchor not in delegate:
            raise RuntimeError("Flutter AppDelegate 模板已变化，请检查后台保活配置。")
        delegate = delegate.replace(
            anchor, "    ZcodeBackgroundKeeper.shared.start()\n" + anchor, 1
        )
        delegate += '''

final class ZcodeBackgroundKeeper {
  static let shared = ZcodeBackgroundKeeper()
  private var task: UIBackgroundTaskIdentifier = .invalid
  private var started = false

  func start() {
    if started { return }
    started = true
    let center = NotificationCenter.default
    center.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil, queue: .main
    ) { [weak self] _ in self?.begin() }
    center.addObserver(
      forName: UIApplication.willEnterForegroundNotification,
      object: nil, queue: .main
    ) { [weak self] _ in self?.end() }
  }

  private func begin() {
    end()
    task = UIApplication.shared.beginBackgroundTask(withName: "zcode-relay") {
      [weak self] in self?.end()
    }
  }

  private func end() {
    guard task != .invalid else { return }
    UIApplication.shared.endBackgroundTask(task)
    task = .invalid
  }
}
'''
        delegate_path.write_text(delegate, encoding="utf-8")

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
