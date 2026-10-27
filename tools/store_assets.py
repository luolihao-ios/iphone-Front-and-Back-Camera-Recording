"""通过 Apple 官方素材库接口管理本次商店宣传素材。"""

import argparse
import base64
import json
import os
from pathlib import Path
import time
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


def commit_payload(asset_id):
    return {'data': {'type': 'appAssetLibraryImages', 'id': asset_id,
                     'attributes': {'uploaded': True}}}


def placement_payload(image_id, locale_id, placement_type, group):
    return {'data': {'type': 'appAssetLibraryPlacements',
                     'attributes': {'placementType': placement_type, 'placementGroup': group},
                     'relationships': {
                         'image': {'data': {'type': 'appAssetLibraryImages', 'id': image_id}},
                         'appStoreVersionLocalization': {'data': {
                             'type': 'appStoreVersionLocalizations', 'id': locale_id}}}}}


def require_editable(version):
    state = version['attributes']['appStoreState']
    if state not in {'PREPARE_FOR_SUBMISSION', 'REJECTED', 'METADATA_REJECTED',
                     'DEVELOPER_REJECTED', 'INVALID_BINARY'}:
        raise ValueError(f'版本不可编辑，未改动产品信息页：{state}')


def resolve_groups(catalog, placement_type, dimensions):
    spec_ids = set()
    for spec in catalog['imageSpecs']:
        size = spec['dimensions']
        if (size['minWidth'] <= dimensions[0] <= size['maxWidth'] and
                size['minHeight'] <= dimensions[1] <= size['maxHeight']):
            spec_ids.add(spec['specId'])
    groups = []
    for kind in catalog['placementTypes']:
        if kind.get('placementType') != placement_type:
            continue
        for mapping in kind['specMappings']:
            if spec_ids.intersection(mapping['specs']):
                groups.append(mapping['placementGroup'])
    return sorted(set(groups))


def read_manifest(path):
    path = Path(path).resolve()
    items = json.loads(path.read_text(encoding='utf-8'))
    for item in items:
        target = (path.parent / item['file']).resolve()
        if not target.is_relative_to(path.parent):
            raise ValueError('素材路径超出交付目录')
        if not target.is_file():
            raise ValueError(f'素材文件缺失：{item["key"]}')
    return items


class AppleClient:
    def __init__(self):
        import jwt
        now = int(time.time())
        self.token = jwt.encode(
            {'iss': os.environ['ASC_ISSUER_ID'], 'iat': now - 10,
             'exp': now + 1100, 'aud': 'appstoreconnect-v1'},
            base64.b64decode(os.environ['ASC_KEY_BASE64']), algorithm='ES256',
            headers={'kid': os.environ['ASC_KEY_ID'], 'typ': 'JWT'})

    def api(self, method, path, body=None, params=None):
        if method not in {'GET', 'POST', 'PATCH'}:
            raise ValueError('本工具不删除素材或提交审核')
        if not path.startswith('/v1/'):
            raise ValueError('只接受 Apple 官方版本化接口路径')
        url = 'https://api.appstoreconnect.apple.com' + path
        if params:
            url += '?' + urlencode(params)
        data = None if body is None else json.dumps(body).encode('utf-8')
        request = Request(url, data=data, method=method,
                          headers={'Authorization': 'Bearer ' + self.token,
                                   'Content-Type': 'application/json'})
        try:
            with urlopen(request, timeout=90) as response:
                raw = response.read()
                return json.loads(raw) if raw else {}
        except HTTPError as error:
            # 不把请求头、签名 URL 或令牌输出到日志。
            try:
                codes = [row.get('code', '') for row in json.loads(error.read()).get('errors', [])]
            except (ValueError, UnicodeError):
                codes = []
            raise RuntimeError(f'Apple API HTTP {error.code}: {",".join(codes)}') from None


def inspect(client):
    apps = client.api('GET', '/v1/apps', params={'filter[bundleId]': 'com.luolihao.dualcapture'})['data']
    if len(apps) != 1:
        raise ValueError('无法唯一定位同框之外 App，未执行写入')
    app = apps[0]
    app_id = app['id']
    report = {'app': {'id': app_id, 'attributes': app['attributes']}}
    report['library'] = client.api('GET', f'/v1/apps/{app_id}/assetLibrary')['data']
    report['referenceData'] = client.api('GET', '/v1/appAssetLibraryRefData')['data']
    versions = client.api('GET', f'/v1/apps/{app_id}/appStoreVersions', params={'limit': 50})['data']
    report['versions'] = []
    for version in versions:
        row = {'id': version['id'], 'attributes': version['attributes']}
        if version['attributes'].get('versionString') == '1.0.13':
            row['localizations'] = client.api('GET', f'/v1/appStoreVersions/{version["id"]}/appStoreVersionLocalizations')['data']
        report['versions'].append(row)
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--report', required=True)
    args = parser.parse_args()
    destination = Path(args.report)
    destination.parent.mkdir(parents=True, exist_ok=True)
    try:
        report = inspect(AppleClient())
        destination.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
        print('素材库、参考规格和版本状态读取成功；本步骤未写入 Apple 后台。')
    except Exception as error:
        destination.write_text(json.dumps({'error': str(error)}, ensure_ascii=False), encoding='utf-8')
        raise SystemExit(str(error)) from None


if __name__ == '__main__':
    main()
