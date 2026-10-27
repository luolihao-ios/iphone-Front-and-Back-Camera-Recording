import json
from pathlib import Path
import tempfile
import unittest

from tools import store_assets


class StoreAssetTests(unittest.TestCase):
    def test_unimplemented_uploader_is_not_allowed_to_report_completion(self):
        self.assertTrue(callable(getattr(store_assets, 'commit_payload', None)),
                        '素材上传必须实现真实提交请求，不能将文件生成当作上传完成')

    def test_commit_does_not_send_legacy_checksum(self):
        result = store_assets.commit_payload('asset-1')
        self.assertEqual(result, {'data': {'type': 'appAssetLibraryImages', 'id': 'asset-1',
                                         'attributes': {'uploaded': True}}})

    def test_placement_has_one_image_and_one_version_localization(self):
        data = store_assets.placement_payload('img-1', 'loc-1', 'APP_SCREENSHOT', 'DYNAMIC_GROUP')['data']
        self.assertEqual(data['relationships'], {
            'image': {'data': {'type': 'appAssetLibraryImages', 'id': 'img-1'}},
            'appStoreVersionLocalization': {'data': {'type': 'appStoreVersionLocalizations', 'id': 'loc-1'}}})
        self.assertEqual(data['attributes'], {'placementType': 'APP_SCREENSHOT', 'placementGroup': 'DYNAMIC_GROUP'})

    def test_live_or_review_version_is_never_editable(self):
        for state in ['READY_FOR_SALE', 'READY_FOR_DISTRIBUTION', 'IN_REVIEW', 'WAITING_FOR_REVIEW', 'PENDING_DEVELOPER_RELEASE']:
            with self.subTest(state=state), self.assertRaises(ValueError):
                store_assets.require_editable({'attributes': {'appStoreState': state}})
        store_assets.require_editable({'attributes': {'appStoreState': 'PREPARE_FOR_SUBMISSION'}})

    def test_resolve_group_from_reference_data_not_device_name_guess(self):
        catalog = {'imageSpecs': [
            {'specId': 'phone', 'dimensions': {'minWidth': 1206, 'maxWidth': 1206, 'minHeight': 2622, 'maxHeight': 2622}},
            {'specId': 'pad', 'dimensions': {'minWidth': 2064, 'maxWidth': 2064, 'minHeight': 2752, 'maxHeight': 2752}}],
            'placementTypes': [{'placementType': 'APP_SCREENSHOT', 'specMappings': [
                {'placementGroup': 'NEW_PHONE_GROUP', 'specs': ['phone']},
                {'placementGroup': 'NEW_PAD_GROUP', 'specs': ['pad']}]}]}
        self.assertEqual(store_assets.resolve_groups(catalog, 'APP_SCREENSHOT', (2064, 2752)), ['NEW_PAD_GROUP'])
        self.assertEqual(store_assets.resolve_groups(catalog, 'APP_SCREENSHOT', (851, 1848)), [])

    def test_manifest_prevents_path_escape_and_missing_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'manifest.json').write_text(json.dumps([{'key': 'evil', 'file': '../key.p8', 'size': [1, 1]}]))
            with self.assertRaises(ValueError):
                store_assets.read_manifest(root / 'manifest.json')


if __name__ == '__main__':
    unittest.main()
