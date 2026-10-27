import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

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

    def test_live_catalog_identifiers_are_used(self):
        catalog = {'imageSpecs': [{'specId': 'duo', 'dimensions': {
            'minWidth': 2007, 'maxWidth': 2007, 'minHeight': 2853, 'maxHeight': 2853}}],
            'placementTypes': [{'placementTypeId': 'APP_SCREENSHOT', 'specMappings': [
                {'placementGroupId': 'IPHONE_DUO_PROFILE', 'specs': ['duo']}]}]}
        self.assertEqual(store_assets.resolve_groups(catalog, 'APP_SCREENSHOT', (2007, 2853)), ['IPHONE_DUO_PROFILE'])

    def test_upload_parts_cannot_omit_bytes_or_use_external_host(self):
        valid = [{'offset': 0, 'length': 3, 'url': 'https://store.blobstore.apple.com/a', 'method': 'PUT', 'requestHeaders': []},
                 {'offset': 3, 'length': 2, 'url': 'https://store.blobstore.apple.com/b', 'method': 'PUT', 'requestHeaders': []}]
        store_assets.validate_upload_operations(valid, 5)
        with self.assertRaises(ValueError):
            store_assets.validate_upload_operations(valid, 6)
        external = [{**valid[0], 'url': 'https://apple.com.example.org/receive'}]
        with self.assertRaises(ValueError):
            store_assets.validate_upload_operations(external, 3)

    def test_manifest_requires_exact_dimensions_and_rgb(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            # IHDR 数据足够完成格式预检；实际成品另有 Pillow 完整解码验证。
            import struct
            image = b'\x89PNG\r\n\x1a\n' + struct.pack('>I', 13) + b'IHDR' + struct.pack('>IIBBBBB', 10, 20, 8, 6, 0, 0, 0)
            (root / 'test.png').write_bytes(image)
            (root / 'manifest.json').write_text(json.dumps([{'key': 'rgba', 'file': 'test.png', 'size': [10, 20]}]))
            with self.assertRaises(ValueError):
                store_assets.read_manifest(root / 'manifest.json')

    def _placement_scenario(self, initial=None, omit_post_relationships=False, processing=False):
        class AppleBoundary:
            def __init__(self):
                self.placements = [{'id': 'legacy', 'attributes': {'placementType': 'APP_SCREENSHOT', 'placementGroup': 'PHONE'},
                    'relationships': {'image': {'data': {'id': 'old-image', 'type': 'appAssetLibraryImages'}}}}]
                if initial is not None:
                    self.placements = [{'id': name, 'attributes': {'placementType': 'APP_SCREENSHOT', 'placementGroup': 'PHONE', 'state': 'PARENT_PREPARE_FOR_SUBMISSION'},
                        'relationships': {'image': {'data': {'type': 'appAssetLibraryImages',
                        'id': name[2:] if name.startswith('p-') else 'old-image'}}}} for name in initial]
            def api(self, method, path, body=None, params=None):
                if path.endswith('/images?limit=200'): return {'data': []}
                if path.startswith('/v1/appAssetLibraryImages/'):
                    return {'data': {'attributes': {'state': 'UPLOAD_COMPLETE' if processing else 'PREPARE_FOR_SUBMISSION',
                                                    'specId': None if processing else 's'}}}
                if path == '/v1/appStoreVersions/version':
                    return {'data': {'id': 'version', 'attributes': {'appStoreState': 'PREPARE_FOR_SUBMISSION'}}}
                if path.endswith('/appStoreVersionLocalizations'):
                    return {'data': [{'id': 'locale', 'attributes': {'locale': 'zh-Hans'}}]}
                if method == 'GET' and path.endswith('/placements'):
                    return {'data': list(self.placements)}
                if method == 'DELETE':
                    self.placements = [p for p in self.placements if p['id'] != path.rsplit('/', 1)[-1]]
                    return {}
                if method == 'POST' and path == '/v1/appAssetLibraryPlacements':
                    row = {'id': 'p-' + body['data']['relationships']['image']['data']['id'],
                           **body['data']}
                    row['attributes']['state'] = 'PARENT_PREPARE_FOR_SUBMISSION'
                    self.placements.append(row)
                    return {'data': {k: v for k, v in row.items() if not (omit_post_relationships and k == 'relationships')}}
                if path == '/v1/appAssetLibraryPlacementOrderingRequests':
                    sequence = [p['id'] for p in body['data']['relationships']['orderedPlacements']['data']]
                    self.placements.sort(key=lambda p: sequence.index(p['id']) if p['id'] in sequence else 100)
                    return {'data': {'id': 'order'}}
                raise AssertionError((method, path))
        report = {'app': {'id': 'app', 'attributes': {'primaryLocale': 'zh-Hans'}}, 'library': {'id': 'lib'},
            'versions': [{'id': 'version', 'attributes': {'versionString': '1.0.13', 'platform': 'IOS'}}],
            'referenceData': [{'attributes': {'imageSpecs': [{'specId': 's', 'dimensions': {
                'minWidth': 2, 'maxWidth': 2, 'minHeight': 2, 'maxHeight': 2}}],
                'placementTypes': [{'placementTypeId': 'APP_SCREENSHOT', 'specMappings': [
                    {'placementGroupId': 'PHONE', 'specs': ['s']}]}]}}]}
        with tempfile.TemporaryDirectory() as directory:
            import struct
            root = Path(directory)
            header = b'\x89PNG\r\n\x1a\n' + struct.pack('>I', 13) + b'IHDR' + struct.pack('>IIBBBBB', 2, 2, 8, 2, 0, 0, 0)
            (root / 'a.png').write_bytes(header)
            (root / 'b.png').write_bytes(header)
            items = [{'key': k, 'file': k + '.png', 'size': [2, 2]} for k in ['a', 'b']]
            (root / 'manifest.json').write_text(json.dumps(items))
            boundary = AppleBoundary()
            with patch.object(store_assets, 'upload_image', side_effect=[
                {'key': 'a', 'id': 'a', 'state': 'PREPARE_FOR_SUBMISSION', 'specId': 's'},
                {'key': 'b', 'id': 'b', 'state': 'PREPARE_FOR_SUBMISSION', 'specId': 's'}]), \
                    patch.object(store_assets.time, 'sleep', side_effect=AssertionError('不应等待 Apple 图片处理才建立关联')):
                store_assets.upload(boundary, report, root / 'manifest.json', False, lambda: None)
            return boundary, report

    def test_two_new_screenshots_in_one_group_both_remain_on_product_page(self):
        boundary, report = self._placement_scenario()
        self.assertEqual([p['id'] for p in boundary.placements], ['p-a', 'p-b'])
        self.assertEqual([p['id'] for p in report['previousPlacements']], ['legacy'])
        self.assertTrue(report['complete'])

    def test_rerun_removes_residual_legacy_image_and_restores_exact_order(self):
        boundary, report = self._placement_scenario(['p-b', 'legacy', 'p-a'])
        self.assertEqual([p['id'] for p in boundary.placements], ['p-a', 'p-b'])
        self.assertTrue(report['complete'])

    def test_post_response_without_relationships_does_not_delete_new_placement(self):
        boundary, report = self._placement_scenario(omit_post_relationships=True)
        self.assertEqual([p['id'] for p in boundary.placements], ['p-a', 'p-b'])
        self.assertTrue(report['complete'])

    def test_processing_images_do_not_block_draft_and_product_page_placements(self):
        boundary, report = self._placement_scenario(processing=True)
        self.assertEqual(report['targetVersion']['version'], '1.0.13')
        self.assertEqual([p['id'] for p in boundary.placements], ['p-a', 'p-b'])
        self.assertEqual(report['processingPending'], ['a', 'b'])
        self.assertTrue(report['complete'])

    def test_repeated_report_backup_preserves_first_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'report.json'
            path.write_text('{"original": true}')
            first = store_assets.backup_report(path)
            path.write_text('{"partial": true}')
            second = store_assets.backup_report(path)
            self.assertNotEqual(first, second)
            self.assertEqual(first.read_text(), '{"original": true}')
            self.assertEqual(second.read_text(), '{"partial": true}')


if __name__ == '__main__':
    unittest.main()
