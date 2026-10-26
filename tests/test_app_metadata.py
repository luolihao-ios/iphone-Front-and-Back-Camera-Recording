import copy
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest


SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "tools" / "verify_app_metadata.py"


class AppMetadataTests(unittest.TestCase):
    def setUp(self):
        self.metadata = {
            "UIFileSharingEnabled": True,
            "LSSupportsOpeningDocumentsInPlace": True,
            "CFBundleShortVersionString": "1.0.13",
            "CFBundleVersion": "6",
            "CFBundleDisplayName": "同框之外",
            "UIDeviceFamily": [1, 2],
            "UILaunchScreen": {},
            "NSCameraUsageDescription": "使用摄像头",
            "NSMicrophoneUsageDescription": "使用麦克风",
            "NSPhotoLibraryUsageDescription": "读取照片",
            "NSPhotoLibraryAddUsageDescription": "保存照片",
            "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
            "UISupportedInterfaceOrientations~ipad": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
        }

    def run_validator(self, metadata):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "Info.plist"
            path.write_bytes(plistlib.dumps(metadata, fmt=plistlib.FMT_BINARY))
            return subprocess.run([sys.executable, str(SCRIPT), str(path)], capture_output=True, text=True, encoding="utf-8")

    def test_accepts_complete_compiled_bundle(self):
        result = self.run_validator(self.metadata)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_missing_file_sharing_key(self):
        del self.metadata["UIFileSharingEnabled"]
        result = self.run_validator(self.metadata)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("UIFileSharingEnabled", result.stderr)

    def test_rejects_true_string_instead_of_boolean(self):
        self.metadata["UIFileSharingEnabled"] = "true"
        result = self.run_validator(self.metadata)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("UIFileSharingEnabled", result.stderr)

    def test_rejects_unexpanded_version_variables(self):
        self.metadata["CFBundleVersion"] = "$(CURRENT_PROJECT_VERSION)"
        result = self.run_validator(self.metadata)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("CFBundleVersion", result.stderr)

    def test_rejects_missing_permission_or_tablet_orientation(self):
        for key in ["NSCameraUsageDescription", "NSMicrophoneUsageDescription", "NSPhotoLibraryUsageDescription", "NSPhotoLibraryAddUsageDescription", "UISupportedInterfaceOrientations~ipad"]:
            with self.subTest(key=key):
                metadata = copy.deepcopy(self.metadata)
                del metadata[key]
                result = self.run_validator(metadata)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(key, result.stderr)


if __name__ == "__main__":
    unittest.main()
