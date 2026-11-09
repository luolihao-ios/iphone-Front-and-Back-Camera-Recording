"""只修改 1.0.15 草稿中英文 iPhone 中等显示屏的前三张截图。"""

import argparse
from collections import defaultdict
import io
import json
import os
from pathlib import Path
import struct
import tempfile
import time
import zipfile

from tools import store_assets as store


OLD_VERSION = '1.0.14'
NEW_VERSION = '1.0.15'
GROUP = 'IPHONE_DYNAMIC_ISLAND_MEDIUM_PROFILE'
KIND = 'APP_SCREENSHOT'
LOCALE = 'en-US'
NAMES = ('01-travel-vlog.png', '02-reaction.png', '03-interview.png')
SIZE = (1206, 2622)


def grouped(placements):
    groups = defaultdict(list)
    for language, rows in placements.items():
        for row in rows:
            a = row['attributes']
            key = language, a['placementType'], a['placementGroup']
            image = (row.get('relationships', {}).get('image', {}).get('data') or {}).get('id')
            if a['placementType'] == KIND and not image:
                raise ValueError('截图关联缺少素材 ID')
            groups[key].append((image, row['id']))
    return groups


TARGET = LOCALE, KIND, GROUP


def compare_untouched(baseline, current):
    before, after = grouped(baseline), grouped(current)
    def outside(groups):
        return {key: [image for image, _ in rows] for key, rows in groups.items() if key != TARGET}
    if outside(before) != outside(after):
        raise ValueError('其他语言或设备的素材或顺序与线上版本不同，停止替换')
    original = [image for image, _ in before[TARGET]]
    if len(original) != 6 or len(set(original)) != 6:
        raise ValueError('线上英文 iPhone 目标组不是六张唯一截图')
    return original, after[TARGET]


def replacement_order(baseline, current, new_images):
    original, rows = compare_untouched(baseline, current)
    allowed = set(original + new_images)
    ids = dict(rows)
    if len(new_images) != 3 or len(set(new_images)) != 3 or set(new_images).intersection(original):
        raise ValueError('三张新素材必须唯一且不能是已有截图')
    if len(ids) != len(rows) or not set(ids).issubset(allowed):
        raise ValueError('目标组有重复或未知素材，未移除任何关联')
    if not set(original[3:]).issubset(ids):
        raise ValueError('原第 4–6 张图片不完整，未移除任何关联')
    obsolete = [ids[image] for image in original[:3] if image in ids]
    ordered = [ids[image] for image in new_images + original[3:] if image in ids] + obsolete
    return ordered, obsolete


def verify_final(baseline, current, new_images):
    original, rows = compare_untouched(baseline, current)
    if [image for image, _ in rows] != new_images + original[3:]:
        raise ValueError('产品页目标组数量或顺序不符')


def load_bundle(bundle, folder):
    from cryptography.fernet import Fernet

    payload = Fernet(os.environ['DRAFT_IMAGE_TRANSFER_KEY']).decrypt(bundle.read_bytes())
    with zipfile.ZipFile(io.BytesIO(payload)) as archive:
        if sorted(archive.namelist()) != sorted(NAMES):
            raise ValueError('发布包必须恰好包含三张指定图片')
        for name in NAMES:
            data = archive.read(name)
            if (data[:16] != b'\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR'
                    or struct.unpack('>IIBB', data[16:26]) != (*SIZE, 8, 2)):
                raise ValueError(f'PNG 不符合 Apple 目标规格：{name}')
            (folder / name).write_bytes(data)


def read_draft(client, draft_id):
    version = client.api('GET', f'/v1/appStoreVersions/{draft_id}')['data']
    store.require_editable(version)
    if version['attributes']['versionString'] != NEW_VERSION:
        raise ValueError('草稿版本与本次操作不一致')
    rows = client.api('GET', f'/v1/appStoreVersions/{draft_id}/appStoreVersionLocalizations')['data']
    locs = {row['attributes']['locale']: row for row in rows}
    if len(rows) != 3 or set(locs) != set(store.TARGET_LOCALES):
        raise ValueError('新版本没有继承预期的三种语言，未修改截图')
    return version, locs, {language: store.all_placements(client, row['id'])
                           for language, row in locs.items()}


def set_order(client, locale_id, placement_ids):
    client.api('POST', '/v1/appAssetLibraryPlacementOrderingRequests', {'data': {
        'type': 'appAssetLibraryPlacementOrderingRequests', 'attributes': {'placementGroup': GROUP},
        'relationships': {
            'orderedPlacements': {'data': [
                {'type': 'appAssetLibraryPlacements', 'id': pid} for pid in placement_ids]},
            'appStoreVersionLocalization': {'data': {
                'type': 'appStoreVersionLocalizations', 'id': locale_id}},
        }}})


def select_version(report, version_string):
    matches = [row for row in report['versions']
               if row['attributes'].get('platform') == 'IOS'
               and row['attributes'].get('versionString') == version_string]
    if len(matches) > 1:
        raise ValueError(f'iOS {version_string} 版本不唯一')
    return matches[0] if matches else None


def release(client, folder, checkpoint, report):
    before = store.inspect(client, OLD_VERSION)
    source = select_version(before, OLD_VERSION)
    if source is None or source['attributes']['appStoreState'] != 'READY_FOR_SALE':
        raise ValueError('未找到已上架的 1.0.14 基线')
    baseline = source['placementsByLocale']
    if set(baseline) != set(store.TARGET_LOCALES) or sum(map(len, baseline.values())) != 72:
        raise ValueError('线上基线与预期的三种语言、72 个位置不一致')
    if store.resolve_groups(before['referenceData'][0]['attributes'], KIND, SIZE) != [GROUP]:
        raise ValueError('Apple 截图规格没有唯一匹配到目标设备组')
    draft = select_version(before, NEW_VERSION)
    if draft is None:
        draft = client.api('POST', '/v1/appStoreVersions', {'data': {
            'type': 'appStoreVersions', 'attributes': {'platform': 'IOS', 'versionString': NEW_VERSION},
            'relationships': {'app': {'data': {'type': 'apps', 'id': before['app']['id']}}},
        }})['data']
    draft_id = draft['id']
    report.update(appId=before['app']['id'], draftId=draft_id, version=NEW_VERSION,
                  locale=LOCALE, group=GROUP, submitted=False)
    checkpoint()
    version, locs, current = read_draft(client, draft_id)
    metadata = {name: row['attributes'] for name, row in locs.items()}
    compare_untouched(baseline, current)
    library = before['library']['id']
    existing = store.all_images(client, library)
    uploaded = []
    for name in NAMES:
        uploaded.append(store.upload_image(client, library, {
            'file': name, 'key': name, 'category': 'APP_SCREENSHOTS_AND_PREVIEWS',
            'referenceName': '1.0.15-en-US-iPhone-' + Path(name).stem,
        }, folder, existing))
    report['images'] = uploaded
    checkpoint()
    new_images = [row['id'] for row in uploaded]
    _, rows = compare_untouched(baseline, current)
    replacement_order(baseline, current, new_images)
    locale_id = locs[LOCALE]['id']
    for image_id in new_images:
        if image_id not in dict(rows):
            client.api('POST', '/v1/appAssetLibraryPlacements',
                       store.placement_payload(image_id, locale_id, KIND, GROUP))
    _, _, current = read_draft(client, draft_id)
    order, obsolete = replacement_order(baseline, current, new_images)
    actual = store.all_placements(client, locale_id, KIND, GROUP)
    by_image = {row['relationships']['image']['data']['id']: row for row in actual}
    if not set(new_images).issubset(by_image) or len(order) != len(actual):
        raise ValueError('新截图关联不完整，保留所有旧截图')
    for _ in range(20):
        states = [by_image[image]['attributes']['state'] for image in new_images]
        report['placementStates'] = states
        checkpoint()
        if all(state == 'ACTIVE' for state in states):
            break
        if any(state not in ('ACTIVE', 'ASSET_PROCESSING') for state in states):
            raise ValueError(f'新截图关联状态异常，保留所有旧截图：{states}')
        time.sleep(3)
        actual = store.all_placements(client, locale_id, KIND, GROUP)
        by_image = {row['relationships']['image']['data']['id']: row for row in actual}
    else:
        raise ValueError('Apple 仍在处理新截图，旧图没有移除；可重跑继续')
    # 先将完整目标顺序保存并回读，最后才摘除排在末尾的三条草稿关联。
    _, _, current = read_draft(client, draft_id)
    order, obsolete = replacement_order(baseline, current, new_images)
    set_order(client, locale_id, order)
    actual = store.all_placements(client, locale_id, KIND, GROUP)
    if [row['id'] for row in actual] != order:
        raise ValueError('新排序未回读成功，旧图没有移除')
    for placement_id in obsolete:
        client.api('DELETE', f'/v1/appAssetLibraryPlacements/{placement_id}')
    version, locs, final = read_draft(client, draft_id)
    verify_final(baseline, final, new_images)
    if any(locs[name]['attributes'] != metadata[name] for name in locs):
        raise ValueError('草稿文案回读有变化')
    published = select_version(store.inspect(client, OLD_VERSION), OLD_VERSION)
    if published['attributes'] != source['attributes'] or grouped(published['placementsByLocale']) != grouped(baseline):
        raise ValueError('线上基线回读有变化')
    report.update(complete=True, draftState=version['attributes']['appStoreState'],
                  screenshotCount=sum(map(len, final.values())), unchanged=69,
                  finalImageIds=[image for image, _ in grouped(final)[TARGET]])
    checkpoint()
    print('1.0.15 草稿：72 个截图位置回读完成，仅英文 iPhone 第 1–3 张已替换。')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    args.report.parent.mkdir(parents=True, exist_ok=True)
    report = {'complete': False}
    def checkpoint():
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    try:
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            load_bundle(args.bundle, folder)
            release(store.AppleClient(), folder, checkpoint, report)
    except Exception as error:
        report['error'] = str(error)
        checkpoint()
        raise SystemExit(str(error)) from None


if __name__ == '__main__':
    main()
