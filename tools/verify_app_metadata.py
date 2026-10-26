"""检查真正成包的 Info.plist，防止共享、权限及通用设备配置在构建中丢失。"""
import pathlib
import plistlib
import re
import sys


def validate(metadata):
    errors = []
    for key in ("UIFileSharingEnabled", "LSSupportsOpeningDocumentsInPlace"):
        if metadata.get(key) is not True:
            errors.append(f"{key} 必须是布尔值 true，实际为 {metadata.get(key)!r}")
    for key in ("CFBundleDisplayName", "NSCameraUsageDescription", "NSMicrophoneUsageDescription",
                "NSPhotoLibraryUsageDescription", "NSPhotoLibraryAddUsageDescription"):
        value = metadata.get(key)
        if not isinstance(value, str) or not value.strip():
            errors.append(f"{key} 缺失或为空")
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        if not re.fullmatch(r"\d+(?:\.\d+)*", str(metadata.get(key, ""))):
            errors.append(f"{key} 未正确展开为版本号")
    families = metadata.get("UIDeviceFamily")
    if not isinstance(families, list) or not all(item in families for item in (1, 2)):
        errors.append("UIDeviceFamily 必须同时包含 iPhone 和 iPad")
    for key in ("UISupportedInterfaceOrientations", "UISupportedInterfaceOrientations~ipad"):
        values = metadata.get(key)
        required = ("UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight")
        if not isinstance(values, list) or not all(item in values for item in required):
            errors.append(f"{key} 必须支持竖屏及两个横屏方向")
    if not isinstance(metadata.get("UILaunchScreen"), dict):
        errors.append("UILaunchScreen 缺失，不能依赖旧尺寸启动兼容模式")
    return errors


def main():
    if len(sys.argv) != 2:
        print("用法：verify_app_metadata.py 成包的Info.plist路径", file=sys.stderr)
        return 2
    try:
        metadata = plistlib.loads(pathlib.Path(sys.argv[1]).read_bytes())
        errors = validate(metadata)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        errors = [f"无法读取 Info.plist：{error}"]
    if errors:
        print("安装包配置检查失败：\n" + "\n".join(errors), file=sys.stderr)
        return 1
    print("安装包配置检查通过：日志共享、权限文案、版本号和 iPad/横屏配置齐全。")
    return 0


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    raise SystemExit(main())
