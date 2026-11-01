"""检查实际语言资源，防止漏译、占位符损坏及权限提示缺失。"""
import json
import pathlib
import plistlib
import re
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
LANGUAGES = ("en", "zh-Hans", "zh-Hant")
PERMISSIONS = (
    "NSCameraUsageDescription", "NSMicrophoneUsageDescription",
    "NSPhotoLibraryUsageDescription", "NSPhotoLibraryAddUsageDescription",
)


def read_strings(language, table):
    path = ROOT / "DualCapture" / f"{language}.lproj" / f"{table}.strings"
    if not path.is_file():
        raise AssertionError(f"缺少语言资源：{path}")
    result = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("//"):
            continue
        match = re.fullmatch(r'\s*("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*")\s*;\s*', line)
        if not match:
            raise AssertionError(f"无效的 strings 行：{line}")
        key, value = (json.loads(part) for part in match.groups())
        if key in result:
            raise AssertionError(f"重复的语言键：{key}")
        if not value.strip():
            raise AssertionError(f"空白翻译：{key}")
        result[key] = value
    return result


class LocalizationResourceTests(unittest.TestCase):
    def test_settings_and_accessibility_have_real_translations(self):
        expected = {
            "en": ("Settings", "Switch primary camera"),
            "zh-Hans": ("设置", "切换主摄像头"),
            "zh-Hant": ("設定", "切換主攝影機"),
        }
        for language, (title, accessibility) in expected.items():
            with self.subTest(language=language):
                strings = read_strings(language, "Localizable")
                self.assertEqual(strings["settings.title"], title)
                self.assertEqual(strings["camera.switch.accessibility"], accessibility)

    def test_every_language_has_complete_keys_and_matching_format_arguments(self):
        english = read_strings("en", "Localizable")
        for language in LANGUAGES:
            translated = read_strings(language, "Localizable")
            self.assertEqual(set(translated), set(english), language)
            for key, value in english.items():
                self.assertEqual(re.findall(r"%(?:\d+\$)?[@df]", translated[key]),
                                 re.findall(r"%(?:\d+\$)?[@df]", value), (language, key))
        self.assertEqual(english["error.session.configuration"], "Unable to configure dual cameras: %@")

    def test_all_system_permission_prompts_are_localized(self):
        for language in LANGUAGES:
            with self.subTest(language=language):
                strings = read_strings(language, "InfoPlist")
                self.assertTrue(all(strings.get(key) for key in PERMISSIONS))
                self.assertTrue(strings["CFBundleDisplayName"])
                if language == "en":
                    for key in PERMISSIONS:
                        self.assertFalse(re.search(r"[\u4e00-\u9fff]", strings[key]))

    def test_base_bundle_advertises_supported_languages_and_english_permission_fallback(self):
        metadata = plistlib.loads((ROOT / "Configuration" / "App-Info.plist").read_bytes())
        self.assertEqual(set(metadata["CFBundleLocalizations"]), set(LANGUAGES))
        english = read_strings("en", "InfoPlist")
        for key in PERMISSIONS:
            self.assertEqual(metadata[key], english[key])

    def test_recording_setup_error_has_a_useful_translation(self):
        strings = read_strings("en", "Localizable")
        self.assertIn("error.recording.inputs", strings)
        self.assertEqual(strings["error.recording.inputs"],
                         "Unable to set up video and audio recording inputs.")


if __name__ == "__main__":
    unittest.main()
